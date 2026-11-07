use base64::{Engine, engine::general_purpose::STANDARD};
use rustls::{ClientConfig, pki_types::ServerName};
use rustls_platform_verifier::BuilderVerifierExt;
use serde::Deserialize;
use std::{net::IpAddr, sync::Arc};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    time::{Duration, timeout},
};
use tokio_rustls::TlsConnector;

const HEADER_LIMIT: usize = 32 * 1024;
const HANDSHAKE: Duration = Duration::from_secs(20);

#[derive(Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub command: String,
    pub protocol: String,
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
}

#[derive(Debug)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl Config {
    pub fn validate(&self) -> Result<(), Failure> {
        if !matches!(self.command.as_str(), "serve" | "check")
            || !matches!(self.protocol.as_str(), "http" | "https" | "socks5")
        {
            return Err(Failure::new("settings", "Выберите HTTP, HTTPS или SOCKS5."));
        }
        let host = self.host.trim_matches(['[', ']']);
        let is_ip = host.parse::<IpAddr>().is_ok();
        let is_dns = !host.is_empty()
            && host.len() <= 253
            && host.split('.').all(|label| {
                !label.is_empty()
                    && label.len() <= 63
                    && !label.starts_with('-')
                    && !label.ends_with('-')
                    && label
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'-')
            });
        if !is_ip && !is_dns || self.port == 0 {
            return Err(Failure::new(
                "settings",
                "Введите адрес сервера без протокола и порт от 1 до 65535.",
            ));
        }
        if self.username.is_empty() && !self.password.is_empty() {
            return Err(Failure::new(
                "settings",
                "Укажите имя пользователя для этого пароля.",
            ));
        }
        if self.protocol == "socks5" && (self.username.len() > 255 || self.password.len() > 255) {
            return Err(Failure::new(
                "settings",
                "Для SOCKS5 имя пользователя и пароль должны занимать не больше 255 байт каждый.",
            ));
        }
        if self.protocol != "socks5" && self.username.contains(':') {
            return Err(Failure::new(
                "settings",
                "Имя пользователя HTTP-прокси не должно содержать двоеточие.",
            ));
        }
        Ok(())
    }
}

pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}
type Tunnel = Box<dyn Stream>;

pub struct Network {
    pub config: Config,
    tls: Arc<ClientConfig>,
}

impl Network {
    pub fn new(config: Config) -> Result<Self, Failure> {
        let tls = ClientConfig::builder()
            .with_platform_verifier()
            .map_err(|_| Failure::new("tls", "Не удалось загрузить системные сертификаты."))?
            .with_no_client_auth();
        Ok(Self {
            config,
            tls: Arc::new(tls),
        })
    }

    async fn upstream(&self) -> Result<Tunnel, Failure> {
        let host = self.config.host.trim_matches(['[', ']']);
        let tcp = TcpStream::connect((host, self.config.port))
            .await
            .map_err(|_| {
                Failure::new(
                    "connect",
                    "Не удалось подключиться к прокси. Проверьте адрес и порт.",
                )
            })?;
        let _ = tcp.set_nodelay(true);
        if self.config.protocol == "https" {
            let name = ServerName::try_from(host.to_owned())
                .map_err(|_| Failure::new("settings", "Проверьте адрес HTTPS-прокси."))?;
            let stream = TlsConnector::from(self.tls.clone()).connect(name, tcp).await
                .map_err(|_| Failure::new("proxy_tls", "Не удалось подтвердить сертификат HTTPS-прокси или установить TLS-соединение."))?;
            Ok(Box::new(stream))
        } else {
            Ok(Box::new(tcp))
        }
    }

    pub async fn tunnel(&self, host: &str, port: u16) -> Result<Tunnel, Failure> {
        let mut stream = self.upstream().await?;
        if self.config.protocol == "socks5" {
            self.socks(&mut stream, host, port).await?;
        } else {
            let authority = authority(host, port);
            let auth = self.auth_header();
            let request =
                format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n{auth}\r\n");
            stream
                .write_all(request.as_bytes())
                .await
                .map_err(connection)?;
            let response = read_header(&mut stream).await?;
            match status(&response)? {
                200 => {}
                407 => {
                    return Err(Failure::new(
                        "auth",
                        "Прокси отклонил авторизацию. Проверьте логин и пароль. Для HTTP поддерживается Basic-авторизация.",
                    ));
                }
                code => {
                    return Err(Failure::new(
                        "upstream",
                        format!("Прокси отклонил соединение: HTTP {code}."),
                    ));
                }
            }
        }
        Ok(stream)
    }

    fn auth_header(&self) -> String {
        if self.config.username.is_empty() {
            String::new()
        } else {
            let value =
                STANDARD.encode(format!("{}:{}", self.config.username, self.config.password));
            format!("Proxy-Authorization: Basic {value}\r\n")
        }
    }

    async fn socks(&self, stream: &mut Tunnel, host: &str, port: u16) -> Result<(), Failure> {
        let auth = !self.config.username.is_empty();
        // Don't silently downgrade an authenticated profile to anonymous SOCKS.
        stream
            .write_all(&[5, 1, if auth { 2 } else { 0 }])
            .await
            .map_err(connection)?;
        let mut reply = [0u8; 2];
        stream.read_exact(&mut reply).await.map_err(connection)?;
        if reply != [5, if auth { 2 } else { 0 }] {
            return Err(Failure::new(
                "auth",
                "SOCKS5-прокси не поддерживает выбранный способ авторизации.",
            ));
        }
        if auth {
            let user = self.config.username.as_bytes();
            let pass = self.config.password.as_bytes();
            let mut packet = vec![1, user.len() as u8];
            packet.extend_from_slice(user);
            packet.push(pass.len() as u8);
            packet.extend_from_slice(pass);
            stream.write_all(&packet).await.map_err(connection)?;
            stream.read_exact(&mut reply).await.map_err(connection)?;
            if reply != [1, 0] {
                return Err(Failure::new(
                    "auth",
                    "SOCKS5-прокси отклонил логин или пароль.",
                ));
            }
        }
        let mut packet = vec![5, 1, 0];
        match host.parse::<IpAddr>() {
            Ok(IpAddr::V4(ip)) => {
                packet.push(1);
                packet.extend(ip.octets());
            }
            Ok(IpAddr::V6(ip)) => {
                packet.push(4);
                packet.extend(ip.octets());
            }
            Err(_) if host.len() <= 255 => {
                packet.extend([3, host.len() as u8]);
                packet.extend(host.as_bytes());
            }
            _ => return Err(Failure::new("target", "Слишком длинный адрес назначения.")),
        }
        packet.extend(port.to_be_bytes());
        stream.write_all(&packet).await.map_err(connection)?;
        let mut response = [0u8; 4];
        stream.read_exact(&mut response).await.map_err(connection)?;
        if response[0] != 5 || response[1] != 0 || response[2] != 0 {
            return Err(Failure::new(
                "upstream",
                "SOCKS5-прокси не смог открыть соединение с сайтом.",
            ));
        }
        let len = match response[3] {
            1 => 4,
            4 => 16,
            3 => stream.read_u8().await.map_err(connection)? as usize,
            _ => {
                return Err(Failure::new(
                    "upstream",
                    "SOCKS5-прокси вернул неизвестный формат адреса.",
                ));
            }
        };
        let mut bound = vec![0u8; len + 2];
        stream.read_exact(&mut bound).await.map_err(connection)?;
        Ok(())
    }

    pub async fn check(&self) -> Result<u16, Failure> {
        let tunnel = self.tunnel("www.figma.com", 443).await?;
        let name = ServerName::try_from("www.figma.com").unwrap();
        let mut stream = TlsConnector::from(self.tls.clone()).connect(name, tunnel).await
            .map_err(|_| Failure::new("target_tls", "Через прокси не удалось установить защищённое соединение с figma.com. Проверьте сертификаты и доступ к сайту."))?;
        stream
            .write_all(b"HEAD / HTTP/1.1\r\nHost: www.figma.com\r\nConnection: close\r\n\r\n")
            .await
            .map_err(connection)?;
        let code = status(&read_header(&mut stream).await?)?;
        if !(200..400).contains(&code) {
            return Err(Failure::new(
                "figma_http",
                format!("Соединение установлено, но figma.com ответил HTTP {code}."),
            ));
        }
        Ok(code)
    }

    pub async fn handle(&self, mut client: TcpStream) -> Result<(), Failure> {
        let result = timeout(HANDSHAKE, self.prepare(&mut client)).await;
        let mut upstream = match result {
            Ok(Ok(stream)) => stream,
            _ => {
                let _ = client.write_all(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n").await;
                return Err(Failure::new(
                    "upstream",
                    "Не удалось открыть соединение через прокси.",
                ));
            }
        };
        // TLS and WebSocket data pass through unchanged. No TLS interception.
        tokio::io::copy_bidirectional(&mut client, &mut upstream)
            .await
            .map_err(connection)?;
        Ok(())
    }

    async fn prepare(&self, client: &mut TcpStream) -> Result<Tunnel, Failure> {
        let header = read_header(client).await?;
        let request = Request::parse(&header)?;
        if request.method == "CONNECT" {
            let (host, port) = parse_authority(&request.target)?;
            let upstream = self.tunnel(&host, port).await?;
            client
                .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                .await
                .map_err(connection)?;
            return Ok(upstream);
        }
        let url = url::Url::parse(&request.target)
            .map_err(|_| Failure::new("request", "Ожидался полный HTTP-адрес."))?;
        if url.scheme() != "http"
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err(Failure::new(
                "request",
                "Этот адрес не поддерживается локальным прокси.",
            ));
        }
        let host = url
            .host_str()
            .ok_or_else(|| Failure::new("request", "В запросе не указан сервер."))?
            .trim_matches(['[', ']']);
        let port = url.port_or_known_default().unwrap_or(80);
        let is_upgrade = request.headers.iter().any(|(key, value)| {
            key.eq_ignore_ascii_case("upgrade") && value.eq_ignore_ascii_case("websocket")
        });
        let mut stream;
        let target;
        if self.config.protocol == "socks5" {
            stream = self.tunnel(host, port).await?;
            target = format!(
                "{}{}",
                url.path(),
                url.query().map(|q| format!("?{q}")).unwrap_or_default()
            );
        } else {
            // Ordinary HTTP requests use absolute-form, including on proxies that disallow CONNECT :80.
            stream = self.upstream().await?;
            target = url.as_str().to_owned();
        }
        let mut outgoing = format!(
            "{} {target} HTTP/1.1\r\nHost: {}\r\n",
            request.method,
            authority(host, port)
        );
        for (key, value) in request.headers {
            if [
                "host",
                "proxy-authorization",
                "proxy-connection",
                "connection",
            ]
            .iter()
            .any(|k| key.eq_ignore_ascii_case(k))
            {
                continue;
            }
            outgoing.push_str(&format!("{key}: {value}\r\n"));
        }
        if self.config.protocol != "socks5" {
            outgoing.push_str(&self.auth_header());
        }
        outgoing.push_str(if is_upgrade {
            "Connection: Upgrade\r\n\r\n"
        } else {
            "Connection: close\r\n\r\n"
        });
        stream
            .write_all(outgoing.as_bytes())
            .await
            .map_err(connection)?;
        Ok(stream)
    }
}

fn connection(_: std::io::Error) -> Failure {
    Failure::new(
        "connection",
        "Прокси закрыл соединение или перестал отвечать.",
    )
}

fn authority(host: &str, port: u16) -> String {
    let host = host.trim_matches(['[', ']']);
    if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn parse_authority(text: &str) -> Result<(String, u16), Failure> {
    let url = url::Url::parse(&format!("http://{text}"))
        .map_err(|_| Failure::new("request", "Проверьте адрес назначения."))?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || text.contains('/')
        || text.contains('\\')
        || !text.contains(':')
    {
        return Err(Failure::new("request", "Ожидался адрес сервера с портом."));
    }
    let host = url
        .host_str()
        .ok_or_else(|| Failure::new("request", "В запросе не указан сервер."))?
        .trim_matches(['[', ']'])
        .to_owned();
    let port = text
        .rsplit_once(':')
        .and_then(|(_, value)| value.parse::<u16>().ok())
        .ok_or_else(|| Failure::new("request", "Ожидался адрес сервера с портом."))?;
    if port == 0 {
        return Err(Failure::new("request", "Порт должен быть от 1 до 65535."));
    }
    Ok((host, port))
}

pub async fn read_header<S: AsyncRead + Unpin + ?Sized>(
    stream: &mut S,
) -> Result<Vec<u8>, Failure> {
    let mut data = Vec::new();
    // Deliberately avoid read-ahead: the next bytes can already be a TLS ClientHello.
    while data.len() < HEADER_LIMIT {
        data.push(stream.read_u8().await.map_err(connection)?);
        if data.ends_with(b"\r\n\r\n") {
            return Ok(data);
        }
    }
    Err(Failure::new(
        "header",
        "Прокси вернул слишком большой заголовок.",
    ))
}

fn status(header: &[u8]) -> Result<u16, Failure> {
    std::str::from_utf8(header)
        .ok()
        .and_then(|h| h.lines().next())
        .and_then(|h| {
            let mut fields = h.split_whitespace();
            if !matches!(fields.next(), Some("HTTP/1.0" | "HTTP/1.1")) {
                return None;
            }
            fields.next()?.parse().ok()
        })
        .ok_or_else(|| Failure::new("response", "Прокси вернул ответ в неизвестном формате."))
}

struct Request {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
}

impl Request {
    fn parse(header: &[u8]) -> Result<Self, Failure> {
        let text = std::str::from_utf8(header)
            .map_err(|_| Failure::new("request", "Не удалось прочитать запрос."))?;
        let mut lines = text.split("\r\n");
        let fields: Vec<_> = lines.next().unwrap_or_default().split(' ').collect();
        if fields.len() != 3
            || !matches!(fields[2], "HTTP/1.1" | "HTTP/1.0")
            || fields[0].is_empty()
            || !fields[0].bytes().all(|b| b.is_ascii_uppercase())
        {
            return Err(Failure::new("request", "Неизвестный формат HTTP-запроса."));
        }
        let mut headers = Vec::new();
        for line in lines.take_while(|line| !line.is_empty()) {
            let (key, value) = line.split_once(':').ok_or_else(|| {
                Failure::new("request", "Не удалось прочитать заголовки запроса.")
            })?;
            if key.is_empty()
                || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                || value.bytes().any(|b| b < 32 && b != b'\t' || b == 127)
            {
                return Err(Failure::new(
                    "request",
                    "Не удалось прочитать заголовки запроса.",
                ));
            }
            headers.push((key.to_owned(), value.trim().to_owned()));
        }
        Ok(Self {
            method: fields[0].into(),
            target: fields[1].into(),
            headers,
        })
    }
}

#[cfg(test)]
mod tests;
