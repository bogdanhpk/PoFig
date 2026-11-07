use super::*;
use tokio::net::TcpListener;

async fn fixture(kind: &str) -> (TcpListener, Network) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let network = Network::new(Config {
        command: "serve".into(),
        protocol: kind.into(),
        host: "127.0.0.1".into(),
        port: listener.local_addr().unwrap().port(),
        username: String::new(),
        password: String::new(),
    })
    .unwrap();
    (listener, network)
}

#[test]
fn settings_reject_urls_zero_ports_and_auth_downgrade() {
    let mut config = Config {
        command: "serve".into(),
        protocol: "http".into(),
        host: "proxy.example.com".into(),
        port: 8080,
        username: "".into(),
        password: "".into(),
    };
    assert!(config.validate().is_ok());
    for host in [
        "",
        "https://proxy.example.com",
        "host/path",
        "host@evil.com",
        "host\r\nInjected: yes",
        "-host",
        "host..com",
    ] {
        config.host = host.into();
        assert!(config.validate().is_err(), "{host}");
    }
    config.host = "::1".into();
    assert!(config.validate().is_ok());
    config.port = 0;
    assert!(config.validate().is_err());
    config.port = 1080;
    config.password = "secret".into();
    assert!(config.validate().is_err());
    config.username = "user".into();
    config.protocol = "socks5".into();
    config.password = "я".repeat(128);
    assert!(config.validate().is_err());
}

#[test]
fn connect_authorities_require_explicit_port_and_support_ipv6() {
    assert_eq!(
        parse_authority("[2001:db8::1]:443").unwrap(),
        ("2001:db8::1".into(), 443)
    );
    assert_eq!(
        parse_authority("figma.com:80").unwrap(),
        ("figma.com".into(), 80)
    );
    for target in [
        "figma.com",
        "figma.com:",
        "figma.com:0",
        "figma.com:65536",
        "user@figma.com:443",
        "figma.com:443/path",
        "figma.com:443?query",
    ] {
        assert!(parse_authority(target).is_err(), "{target}");
    }
}

#[tokio::test]
async fn http_auth_and_bytes_after_connect_are_preserved() {
    let (listener, mut network) = fixture("http").await;
    network.config.username = "test-user".into();
    network.config.password = "test-password".into();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let header = String::from_utf8(read_header(&mut stream).await.unwrap()).unwrap();
        assert!(header.starts_with("CONNECT figma.com:443 HTTP/1.1\r\n"));
        assert!(header.contains(&format!(
            "Proxy-Authorization: Basic {}\r\n",
            STANDARD.encode("test-user:test-password")
        )));
        stream
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n\x16\x03\x03binary")
            .await
            .unwrap();
    });
    let mut tunnel = network.tunnel("figma.com", 443).await.unwrap();
    let mut result = Vec::new();
    tunnel.read_to_end(&mut result).await.unwrap();
    assert_eq!(result, b"\x16\x03\x03binary");
    server.await.unwrap();
}

#[tokio::test]
async fn proxy_auth_rejection_never_falls_back_to_target() {
    let (listener, network) = fixture("http").await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target_port = target.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        read_header(&mut stream).await.unwrap();
        stream
            .write_all(b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
            .await
            .unwrap();
    });
    let result = network.tunnel("127.0.0.1", target_port).await;
    assert_eq!(result.err().unwrap().code, "auth");
    assert!(
        timeout(Duration::from_millis(80), target.accept())
            .await
            .is_err()
    );
    server.await.unwrap();
}

async fn socks_target(stream: &mut TcpStream) -> (String, u16) {
    let mut header = [0; 5];
    stream.read_exact(&mut header).await.unwrap();
    assert_eq!(&header[..4], &[5, 1, 0, 3]);
    let mut host = vec![0; header[4] as usize];
    stream.read_exact(&mut host).await.unwrap();
    let port = stream.read_u16().await.unwrap();
    (String::from_utf8(host).unwrap(), port)
}

#[tokio::test]
async fn socks_resolves_target_at_proxy_and_supports_ipv6_bound_address() {
    let (listener, network) = fixture("socks5").await;
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut hello = [0; 3];
        stream.read_exact(&mut hello).await.unwrap();
        assert_eq!(hello, [5, 1, 0]);
        stream.write_all(&[5, 0]).await.unwrap();
        assert_eq!(
            socks_target(&mut stream).await,
            ("unresolvable.invalid".into(), 443)
        );
        let mut response = vec![5, 0, 0, 4];
        response.extend([0; 18]);
        response.extend(b"ok");
        stream.write_all(&response).await.unwrap();
    });
    let mut tunnel = network.tunnel("unresolvable.invalid", 443).await.unwrap();
    let mut value = [0; 2];
    tunnel.read_exact(&mut value).await.unwrap();
    assert_eq!(&value, b"ok");
    server.await.unwrap();
}

#[tokio::test]
async fn socks_username_password_and_domain_bound_address() {
    let (listener, mut network) = fixture("socks5").await;
    network.config.username = "u".into();
    network.config.password = "pw".into();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut hello = [0; 3];
        stream.read_exact(&mut hello).await.unwrap();
        assert_eq!(hello, [5, 1, 2]);
        stream.write_all(&[5, 2]).await.unwrap();
        let mut auth = [0; 6];
        stream.read_exact(&mut auth).await.unwrap();
        assert_eq!(&auth, &[1, 1, b'u', 2, b'p', b'w']);
        stream.write_all(&[1, 0]).await.unwrap();
        assert_eq!(socks_target(&mut stream).await, ("figma.com".into(), 443));
        stream
            .write_all(&[5, 0, 0, 3, 1, b'x', 0, 80])
            .await
            .unwrap();
        stream.write_all(b"authenticated").await.unwrap();
    });
    let mut tunnel = network.tunnel("figma.com", 443).await.unwrap();
    let mut value = Vec::new();
    tunnel.read_to_end(&mut value).await.unwrap();
    assert_eq!(value, b"authenticated");
    server.await.unwrap();
}

#[tokio::test]
async fn socks_refuses_anonymous_method_for_password_profile() {
    let (listener, mut network) = fixture("socks5").await;
    network.config.username = "user".into();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut hello = [0; 3];
        stream.read_exact(&mut hello).await.unwrap();
        stream.write_all(&[5, 0]).await.unwrap();
    });
    assert_eq!(
        network.tunnel("figma.com", 443).await.err().unwrap().code,
        "auth"
    );
    server.await.unwrap();
}

async fn client_for(network: Network) -> (TcpStream, tokio::task::JoinHandle<Result<(), Failure>>) {
    let local = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let client = TcpStream::connect(local.local_addr().unwrap())
        .await
        .unwrap();
    let (stream, _) = local.accept().await.unwrap();
    (
        client,
        tokio::spawn(async move { network.handle(stream).await }),
    )
}

#[tokio::test]
async fn plain_http_uses_absolute_form_and_replaces_proxy_credentials() {
    let (listener, mut network) = fixture("http").await;
    network.config.username = "real".into();
    network.config.password = "secret".into();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let header = String::from_utf8(read_header(&mut stream).await.unwrap()).unwrap();
        assert!(header.starts_with("GET http://example.com/resource?q=1 HTTP/1.1\r\n"));
        assert!(header.contains("Host: example.com:80\r\n"));
        assert!(!header.contains("forged"));
        assert_eq!(header.matches("Proxy-Authorization:").count(), 1);
        assert!(header.contains("Connection: close\r\n"));
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
            .await
            .unwrap();
    });
    let (mut client, task) = client_for(network).await;
    client.write_all(b"GET http://example.com/resource?q=1 HTTP/1.1\r\nHost: forged\r\nProxy-Authorization: forged\r\n\r\n").await.unwrap();
    client.shutdown().await.unwrap();
    let mut response = Vec::new();
    client.read_to_end(&mut response).await.unwrap();
    assert!(response.ends_with(b"ok"));
    task.await.unwrap().unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn connect_supports_bidirectional_binary_and_half_close() {
    let (listener, network) = fixture("http").await;
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        read_header(&mut stream).await.unwrap();
        stream.write_all(b"HTTP/1.1 200 OK\r\n\r\n").await.unwrap();
        let mut request = Vec::new();
        stream.read_to_end(&mut request).await.unwrap();
        assert_eq!(request, b"\0\xffhello");
        stream.write_all(b"\xff\0reply").await.unwrap();
    });
    let (mut client, task) = client_for(network).await;
    client
        .write_all(b"CONNECT figma.com:443 HTTP/1.1\r\nHost: figma.com:443\r\n\r\n")
        .await
        .unwrap();
    assert_eq!(
        status(&read_header(&mut client).await.unwrap()).unwrap(),
        200
    );
    client.write_all(b"\0\xffhello").await.unwrap();
    client.shutdown().await.unwrap();
    let mut response = Vec::new();
    client.read_to_end(&mut response).await.unwrap();
    assert_eq!(response, b"\xff\0reply");
    task.await.unwrap().unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn bad_client_requests_fail_closed() {
    let (_, network) = fixture("http").await;
    let (mut client, task) = client_for(network).await;
    client
        .write_all(b"CONNECT user:pass@figma.com:443 HTTP/1.1\r\n\r\n")
        .await
        .unwrap();
    assert_eq!(
        status(&read_header(&mut client).await.unwrap()).unwrap(),
        502
    );
    assert!(task.await.unwrap().is_err());
}

struct TestTlsMaterial {
    root: rustls::pki_types::CertificateDer<'static>,
    server: Arc<rustls::ServerConfig>,
}

fn tls_material() -> &'static TestTlsMaterial {
    use rcgen::{
        BasicConstraints, CertificateParams, CertifiedIssuer, DnType, ExtendedKeyUsagePurpose,
        IsCa, KeyPair, KeyUsagePurpose,
    };
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    static MATERIAL: std::sync::OnceLock<TestTlsMaterial> = std::sync::OnceLock::new();
    MATERIAL.get_or_init(|| {
        // Test-only keys are generated in memory; no private keys are shipped in Git.
        let mut ca_params = CertificateParams::new(Vec::<String>::new()).unwrap();
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
        ca_params
            .distinguished_name
            .push(DnType::CommonName, "PoFig ephemeral test CA");
        let ca = CertifiedIssuer::self_signed(ca_params, KeyPair::generate().unwrap()).unwrap();
        let key = KeyPair::generate().unwrap();
        let mut params =
            CertificateParams::new(vec!["localhost".into(), "127.0.0.1".into()]).unwrap();
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        let cert = params.signed_by(&key, &ca).unwrap();
        let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
        let server = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![CertificateDer::from(cert.der().to_vec())], private_key)
            .unwrap();
        TestTlsMaterial {
            root: ca.der().clone(),
            server: Arc::new(server),
        }
    })
}

fn tls_server() -> tokio_rustls::TlsAcceptor {
    tokio_rustls::TlsAcceptor::from(tls_material().server.clone())
}

#[tokio::test]
async fn https_proxy_uses_validated_tls_before_connect() {
    let (listener, mut network) = fixture("https").await;
    let mut roots = rustls::RootCertStore::empty();
    roots.add(tls_material().root.clone()).unwrap();
    network.tls = Arc::new(
        ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    );
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut tls = tls_server().accept(stream).await.unwrap();
        let header = String::from_utf8(read_header(&mut tls).await.unwrap()).unwrap();
        assert!(header.starts_with("CONNECT figma.com:443"));
        tls.write_all(b"HTTP/1.1 200 OK\r\n\r\ntls").await.unwrap();
        tls.shutdown().await.unwrap();
    });
    let mut tunnel = network.tunnel("figma.com", 443).await.unwrap();
    let mut value = Vec::new();
    tunnel.read_to_end(&mut value).await.unwrap();
    assert_eq!(value, b"tls");
    server.await.unwrap();
}

#[tokio::test]
async fn https_proxy_rejects_untrusted_certificates() {
    let (listener, network) = fixture("https").await;
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        assert!(tls_server().accept(stream).await.is_err());
    });
    assert_eq!(
        network.tunnel("figma.com", 443).await.err().unwrap().code,
        "proxy_tls"
    );
    server.await.unwrap();
}
