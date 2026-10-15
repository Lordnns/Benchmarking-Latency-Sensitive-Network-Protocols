use std::time::{SystemTime, UNIX_EPOCH};
use std::sync::OnceLock;
use bytes::{Buf, BufMut, Bytes, BytesMut};
use crc32fast::Hasher;
use rand::RngCore;

// Layout:
// [0..8]   Packet ID (u64)
// [8..16]  Timestamp (u64 - micros)
// [16..20] CRC32 (u32)
// [20..N]  Payload
const HEADER_SIZE: usize = 20;

pub struct BenchmarkPacket {
    pub id: u64,
    pub timestamp: u64,
    pub payload: Bytes,
}

static RANDOM_ENTROPY: OnceLock<Bytes> = OnceLock::new();

impl BenchmarkPacket {
    pub fn new(id: u64, size: usize) -> Self {
        // Generate random payload
        let entropy_pool = RANDOM_ENTROPY.get_or_init(|| {
            let mut data = vec![0u8; 1024 * 1024];
            rand::rng().fill_bytes(&mut data);
            Bytes::from(data)
        });

        let payload = entropy_pool.slice(0..size);

        // Current time in micros
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_micros() as u64;

        Self { id, timestamp, payload }
    }

    /// Serializes the packet into Bytes.
    /// Format: ID | Timestamp | CRC32 | Payload
    pub fn to_bytes(&self) -> Bytes {
        let total_len = HEADER_SIZE + self.payload.len();
        let mut buf = BytesMut::with_capacity(total_len);

        buf.put_u64(self.id);
        buf.put_u64(self.timestamp);

        // 1. Compute CRC of ID + Timestamp + Payload
        let mut hasher = Hasher::new();
        hasher.update(&self.id.to_be_bytes());
        hasher.update(&self.timestamp.to_be_bytes());
        hasher.update(&self.payload);
        let checksum = hasher.finalize();

        buf.put_u32(checksum);
        buf.put_slice(&self.payload);

        buf.freeze()
    }

    /// Parses bytes back into a BenchmarkPacket and verifies the CRC.
    /// Returns None if the CRC fails or data is too short.
    pub fn from_bytes(mut data: Bytes) -> Option<Self> {
        if data.len() < HEADER_SIZE {
            return None;
        }

        let id = data.get_u64();
        let timestamp = data.get_u64();
        let checksum = data.get_u32();

        // The remaining bytes are the payload
        let payload = data;

        // Validate CRC
        let mut hasher = Hasher::new();
        hasher.update(&id.to_be_bytes());
        hasher.update(&timestamp.to_be_bytes());
        hasher.update(&payload);

        if hasher.finalize() != checksum {
            eprintln!("CRC Mismatch! Packet {} corrupted.", id);
            return None;
        }

        Some(Self { id, timestamp, payload })
    }
}