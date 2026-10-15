mod utils;

use std::vec;
use clap::Parser;
use tracing::{debug, error, info, warn};
use game_sockets::*;
use game_sockets::protocols::*;
use crate::utils::TestProtocol;

struct GlobalState {
    clients: Vec<GameConnection>,
}

impl GlobalState {
    pub fn new() -> Self {
        Self {
            clients: vec![],
        }
    }

    pub fn add_client(&mut self, connection: GameConnection) {
        self.clients.push(connection);
    }

    pub fn remove_client(&mut self, connection: GameConnection) {
        self.clients.retain(|c| c != &connection);
    }
}

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct CliArgs {
    #[arg(value_enum)]
    protocol: TestProtocol,
    #[arg(
        long,
        short,
        default_value = "0.0.0.0",
        help = "IP address of the server to connect to (default: 0.0.0.0)"
    )]
    ip: String,
    #[arg(
        long,
        short,
        default_value = "8080",
        help = "Port of the server to connect to (default: 8080)"
    )]
    port: u16
}

fn main() -> Result<(), GameSocketError> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let args = CliArgs::parse();

    match args.protocol {
        TestProtocol::Udp => {
            let backend = UdpBackend::new();
            let server = GamePeer::new(backend);
            run_benchmark(server, &args)
        },
        TestProtocol::Tcp => {
            let backend = TcpBackend::new();
            let client = GamePeer::new(backend);
            run_benchmark(client, &args)
        },
        TestProtocol::Quic => {
            let backend = QuicBackend::new();
            let client = GamePeer::new(backend);
            run_benchmark(client, &args)
        },
        TestProtocol::GNS => {
            let backend = GnsBackend::new();
            let client = GamePeer::new(backend);
            run_benchmark(client, &args)
        },
    }
}

fn run_benchmark(mut server: GamePeer, args: &CliArgs) -> Result<(), GameSocketError> {
    server.listen(&args.ip, args.port)?;
    info!("Server started on {}:{}", args.ip, args.port);
    let mut state = GlobalState::new();

    //Read all the server events
    loop {
        let event = server.poll();
        let Ok(event) = event
        else {
            // Socket Error
            error!("Error polling server");
            return Ok(());
        };
        let Some(event) = event else {
            //No more events
            continue;
        };

        match event {
            GameNetworkEvent::Connected(connection) => {
                info!("Client connected: {:?}", connection);
                state.add_client(connection);
            },
            GameNetworkEvent::Disconnected(connection) => {
                info!("Client disconnected: {:?}", connection);
                state.remove_client(connection);
            },
            GameNetworkEvent::Message {connection, stream, data } => {
                use utils::BenchmarkPacket;
                let Some(packet) = BenchmarkPacket::from_bytes(data) else {
                    warn!("Received invalid packet from client: {:?}", connection);
                    continue;
                };
                debug!("Received packet {} from client: {:?}", packet.id, connection);
                server.send(&connection, &stream, packet.to_bytes())?;
            },
            _ => {}
        }
    }
}