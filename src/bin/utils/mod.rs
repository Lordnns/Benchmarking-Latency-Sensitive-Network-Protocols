mod benchmark_packet;
mod metrics;

use clap::ValueEnum;
pub use benchmark_packet::BenchmarkPacket;
pub use metrics::MetricsRecorder;
pub use metrics::BenchmarkRecord;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, ValueEnum)]
pub enum TestProtocol {
    Udp,
    Tcp,
    Quic,
    GNS
}