use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;
use std::sync::mpsc;
use std::thread;
use serde::{Deserialize, Serialize};

// The raw data point
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct BenchmarkRecord {
    pub packet_id: u64,
    pub stream_id: u16,
    pub rtt_us: u64,
    pub payload_size: usize,
    pub recv_timestamp: u64,
}

pub struct MetricsRecorder {
    tx: Option<mpsc::Sender<BenchmarkRecord>>,
    thread_handle: Option<thread::JoinHandle<()>>,
}

impl MetricsRecorder {
    pub fn new<P: AsRef<Path>>(path: P) -> Self {
        let path = path.as_ref().to_path_buf();
        let (tx, rx) = mpsc::channel::<BenchmarkRecord>();

        let handle = thread::spawn(move || {
            let file = File::create(&path).expect("Unable to create metrics file");
            let mut writer = BufWriter::new(file);

            // Header
            writeln!(writer, "recv_timestamp,packet_id,stream_id,rtt_us,payload_size").unwrap();

            // The loop exits automatically when 'tx' is dropped in the main thread
            while let Ok(record) = rx.recv() {
                writeln!(
                    writer,
                    "{},{},{},{},{}",
                    record.recv_timestamp,
                    record.packet_id,
                    record.stream_id,
                    record.rtt_us,
                    record.payload_size
                ).unwrap();
            }

            // Flush remaining buffer on exit
            writer.flush().unwrap();
        });

        Self {
            tx: Some(tx),
            thread_handle: Some(handle),
        }
    }

    pub fn record(&self, record: BenchmarkRecord) {
        if let Some(tx) = &self.tx {
            // Send is non-blocking (mostly)
            let _ = tx.send(record);
        }
    }
}

// Clean shutdown when the client drops the recorder
impl Drop for MetricsRecorder {
    fn drop(&mut self) {
        // Drop the sender to signal the thread to stop
        drop(self.tx.take());
        if let Some(handle) = self.thread_handle.take() {
            let _ = handle.join();
        }
    }
}