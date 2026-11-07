mod protocol;

use protocol::{Config, Failure, Network};
use serde_json::json;
use std::{sync::Arc, time::Instant};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    net::TcpListener,
    sync::Semaphore,
    time::{Duration, timeout},
};

fn emit(event: serde_json::Value) {
    // Stdout is an IPC channel. Never serialize Config or an upstream response here.
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{event}");
    let _ = out.flush();
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        emit(json!({"event":"error", "code":error.code, "message":error.message}));
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Failure> {
    let mut input = BufReader::new(tokio::io::stdin());
    let mut line = String::new();
    // Read a bounded record. Passwords are supplied through the parent's pipe.
    (&mut input)
        .take(16_385)
        .read_line(&mut line)
        .await
        .map_err(|_| Failure::new("input", "Не удалось прочитать настройки прокси."))?;
    if line.len() > 16_384 || !line.ends_with('\n') {
        return Err(Failure::new(
            "input",
            "Слишком большой или незавершённый набор настроек.",
        ));
    }
    let config: Config = serde_json::from_str(&line)
        .map_err(|_| Failure::new("input", "Не удалось прочитать настройки прокси."))?;
    line.clear();
    config.validate()?;
    let network = Arc::new(Network::new(config)?);

    if network.config.command == "check" {
        let start = Instant::now();
        let status = timeout(Duration::from_secs(30), network.check())
            .await
            .map_err(|_| Failure::new("timeout", "Прокси не ответил за 30 секунд."))??;
        emit(
            json!({"event":"checked", "latency_ms":start.elapsed().as_millis(), "http_status":status}),
        );
        return Ok(());
    }

    let listener = TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|_| Failure::new("listen", "Не удалось открыть локальный порт для Figma."))?;
    let port = listener
        .local_addr()
        .map_err(|_| Failure::new("listen", "Не удалось определить локальный порт."))?
        .port();
    if network.config.port == port
        && matches!(
            network.config.host.as_str(),
            "127.0.0.1" | "localhost" | "::1" | "[::1]"
        )
    {
        return Err(Failure::new(
            "loop",
            "Адрес прокси совпал с адресом локального соединения. Повторите запуск.",
        ));
    }
    emit(json!({"event":"ready", "host":"127.0.0.1", "port":port}));
    let permits = Arc::new(Semaphore::new(256));
    let mut byte = [0u8; 1];
    loop {
        tokio::select! {
            // Parent death or closing the pipe shuts down the entire runtime and all tunnels.
            _ = input.read(&mut byte) => return Ok(()),
            accepted = listener.accept() => {
                let (client, _) = accepted.map_err(|_| Failure::new("listen", "Локальное соединение прервано."))?;
                let Ok(permit) = permits.clone().try_acquire_owned() else { continue; };
                let network = network.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    // Individual failures don't take down other Figma tabs.
                    let _ = network.handle(client).await;
                });
            }
        }
    }
}
