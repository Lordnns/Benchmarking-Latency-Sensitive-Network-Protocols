# Benchmarking Latency-Sensitive Network Protocols

Code, scripts and raw data for the paper *Benchmarking Latency-Sensitive Network Protocols*. The paper compares a naïve benchmarking setup with a fully isolated one, and measures how much each changes the latency numbers you get for UDP, TCP, QUIC and Valve's GameNetworkingSockets (GNS).

The repository has three parts:

- **`game_sockets`**: a small Rust library that puts the four transports behind one game-style API. It also builds the benchmark binaries (`server`, `client`, `stats`, `plot`).
- **`scripts/`**: the Bash and Python tooling that sets up the network, runs the test matrix, and turns raw CSVs into statistics and figures.
- **`benchmark_results/`**: every run used in the paper, as raw per-packet CSVs plus per-run JSON statistics.

---

## Repository layout

```
.
├── Cargo.toml                 # crate "game_sockets" (edition 2024)
├── src/
│   ├── lib.rs                 # GamePeer, commands/events, stream IDs
│   ├── protocols/             # one backend per transport
│   │   ├── udp_protocol.rs
│   │   ├── tcp_protocol.rs
│   │   ├── quic_protocol.rs
│   │   └── gns_protocol.rs
│   └── bin/
│       ├── server.rs          # echo server
│       ├── client.rs          # traffic generator + RTT recorder
│       ├── stats.rs           # CSV -> JSON statistics
│       ├── plot.rs            # aggregated JSON -> SVG charts
│       └── utils/             # packet format, CSV recorder, protocol enum
├── scripts/                   # run / setup / processing scripts (see below)
└── benchmark_results/         # all data used in the paper (see below)
```

---

## The `game_sockets` library

### Model

A `GamePeer` is the handle the application uses. When you create one with a backend (`GamePeer::new(UdpBackend::new())`), it starts a **dedicated backend thread** that owns all network I/O. The application and the backend talk over two unbounded Tokio channels:

```
 application thread                         backend thread
 ──────────────────                         ──────────────
 listen / connect / create_stream  ── BackendCommand ──▶  socket I/O
 send / close_stream / shutdown
 poll()  ◀── GameNetworkEvent ───────────────────────────  Connected, Disconnected,
                                                          Message, StreamCreated,
                                                          StreamClosed, Error
```

`poll()` doesn't block. It returns `Ok(None)` when no event is waiting. The client and server busy-poll it in their main loop.

| `GamePeer` method | Effect |
|---|---|
| `listen(ip, port)` | bind as a server |
| `connect(ip, port)` | connect to a server; the backend emits `Connected` |
| `create_stream(conn, reliability)` | open a logical stream; the backend emits `StreamCreated` with its `GameStream` |
| `send(conn, stream, bytes)` | send one message on a stream |
| `close_stream(conn, stream)` | close a stream; emits `StreamClosed` |
| `poll()` | fetch the next event, if any |
| `shutdown()` | stop the backend thread and join it |

Each connection is identified by a random UUID (`GameConnection`), whatever the transport.

### Streams and stream IDs

A `GameStream` is a `u16` that encodes both an index and a reliability class:

```
stream_id = (index << 2) | flags
flags: 0b11 = Reliable, 0b10 = Ordered, 0b00 = Unreliable
```

The client opens two streams per connection, so the IDs that appear in the data are:

| Stream | Index | `stream_id` in CSV |
|---|---|---|
| Unreliable, 60 Hz | 1 | **4** |
| Reliable, 20 Hz | 2 | **11** |

Every backend prefixes each message with this `u16`, so the receiver can demultiplex streams.

### Backends

| Backend | Transport | How it handles **unreliable** messages | How it handles **reliable** messages | Notes |
|---|---|---|---|---|
| `UdpBackend` | Tokio `UdpSocket` | raw datagram | raw datagram (**no** retransmission) | 18-byte header: 16-byte connection UUID + stream ID. The server accepts a connection on the first packet from a new UUID. |
| `TcpBackend` | Tokio `TcpStream`, `TCP_NODELAY` | framed message on the single TCP connection | same connection | Length-delimited framing (`u32` length) + stream ID. Both streams share one ordered byte stream, so the "unreliable" stream is actually reliable and suffers head-of-line blocking. |
| `QuicBackend` | Quinn 0.10 + rustls 0.21 | QUIC **datagram** (`send_datagram`) | one bidirectional QUIC stream per game stream, `u32` length prefix | BBR congestion control, initial RTT 15 ms, 1 s keep-alive, 1 MiB datagram receive buffer. Uses a self-signed certificate and **skips certificate verification**, so it's for benchmarking only. |
| `GnsBackend` | Valve GameNetworkingSockets (`game-networking-sockets` crate) | `k_nSteamNetworkingSend_Unreliable`, lane 1 | `k_nSteamNetworkingSend_Reliable`, lane 0 | Nagle time set to 0, two lanes with equal priority and weight. The backend thread busy-polls GNS and calls `yield_now()` when idle. |

Because of these differences, the per-stream results mean different things for different protocols:

- **UDP:** the "Reliable" stream is not reliable; it loses packets like the unreliable one (4.05 % at 2 % netem loss).
- **TCP:** both streams are reliable (0 % loss), and the unreliable stream's latency includes TCP retransmission stalls.
- **QUIC and GNS:** the two streams really are unreliable and reliable.

---

## Benchmark binaries

Build everything in release mode. LTO is `fat`, `codegen-units = 1`, and `panic = "abort"`.

```bash
RUSTFLAGS="-C target-cpu=native" cargo build --release
# -> target/release/{server,client,stats,plot}
```

The GNS backend depends on the `game-networking-sockets` crate, which builds Valve's C++ library. You need a working C/C++ toolchain; check that crate's documentation for its native dependencies.

### `server`: echo server

```bash
server <udp|tcp|quic|gns> [--ip 0.0.0.0] [--port 8080]
```

The server accepts any number of clients. It checks the CRC of every message and sends it back unchanged on the same stream.

### `client`: traffic generator

```bash
client <udp|tcp|quic|gns> [--ip 127.0.0.1] [--port 8080] [--results results.csv]
       [--packet-size 1000] [--duration 30] [--warmup 0]
```

The traffic models a real-time game:

- **Unreliable stream:** one message every 16.666 ms (**60 Hz**).
- **Reliable stream:** one message every 50 ms (**20 Hz**).
- **Payload:** `--packet-size` bytes (1000 in all paper runs), sliced from a fixed 1 MiB random buffer.

Each message uses this format (`src/bin/utils/benchmark_packet.rs`):

```
[0..8)   packet id   u64   (per-stream sequence number)
[8..16)  timestamp   u64   (send time, µs since the Unix epoch)
[16..20) CRC32       u32   (over id + timestamp + payload)
[20..N)  payload
```

When an echo comes back, the client computes **RTT = now − timestamp** in microseconds and records it.

**Timing rules:**
- `--duration` is the total run time, counted from the moment the connection is established.
- Packets are recorded only once more than `--warmup` whole seconds have passed. With `--duration 70 --warmup 10`, about 59 s of data is kept per run.

A background thread writes the records to CSV, so file I/O never blocks the send loop.

### `stats`: statistics

```bash
stats <file.csv>                         # one run  -> JSON on stdout (used by process_results.sh)
stats <dir> --all                        # sweep    -> <dir>/aggregated/<scenario>_<proto>.json
stats <dir> [--scenario S] [--protocol P]  # filtered aggregate -> JSON on stdout
```

**Per run**, computed per stream and globally:

| Field | Definition |
|---|---|
| `sent` | `max(packet_id) − min(packet_id) + 1` over the received packets of a stream |
| `received` | number of CSV rows |
| `lost`, `loss_rate_percent` | `sent − received`, and the same as a percentage of `sent` (round-trip loss) |
| `min/avg/max_us` | RTT min / mean / max |
| `jitter_us` | **standard deviation of RTT** (population σ), not inter-arrival jitter |
| `p50/p90/p95/p99_us` | nearest-rank percentile: `sorted[floor(p·(n−1))]` |
| `duration_sec`, `packet_rate_pps`, `goodput_mbps` | from first to last receive timestamp |

**Across runs** (`--all` / filtered mode), each metric gets `median`, `mean`, `stddev` (sample, n−1), `ci95_low/high`, `min`, `max`, and the raw per-run `values`. The 95 % CI is mean ± t·σ/√n:
- t comes from a lookup table: 2.262 for n = 10 and 2.042 for n = 21–30;
- for n > 30 it uses z = 1.96.

### `plot`: charts

```bash
plot <results_dir>      # needs <results_dir>/aggregated/ from `stats <dir> --all`
```

`plot` writes four SVGs to the current directory, each showing global P99 with 95 % CI error bars:

| File | Contents |
|---|---|
| `latency_trend.svg` | P99 vs delay |
| `packet_loss_trend_tcp.svg` | P99 vs loss, all protocols |
| `packet_loss_trend_no_tcp.svg` | P99 vs loss, without TCP |
| `scenario.svg` | grouped bars for the fiber / good / poor composite scenarios |

The `aggregated/` folders are not committed; regenerate them with `stats --all`.

---

## Scripts

All scripts expect to be run from the repository root on Linux, as root (they use `ip netns`, `tc`, `taskset` and `chrt`). Some files have Windows (CRLF) line endings. Run `sed -i 's/\r$//' scripts/*.sh` once after cloning on Linux.

### Network and host setup

| Script | Purpose |
|---|---|
| `setup_netns.sh` | Creates `ns_server` (10.0.0.1, `veth-srv`) and `ns_client` (10.0.0.2, `veth-cli`) connected by a veth pair. Sets MTU 1500, turns off tx/rx/TSO/GSO/GRO offloads, and pings to check. |
| `set_netem.sh <delay> <jitter> <loss> <rate>` | Applies a symmetric netem qdisc (normal-distributed delay, loss, rate) on both veth ends. |
| `prepare_bench.sh` | Runtime host tuning: swap off, stops background services, moves all IRQs to core 0, drops caches, raises socket buffer limits, disables ASLR. (Its banner says 3800X; the test machine is a 3700X.) |
| `cleanup.sh` | Reverses `prepare_bench.sh` and deletes the namespaces. |

Boot-time isolation (`isolcpus`, `nohz_full`, `rcu_nocbs`, `processor.max_cstate=0`, SMT and CPB off) is configured outside these scripts. The paper runs used **ubenchmon** for host setup and teardown.

### Runners

| Script | What it runs | Output folder |
|---|---|---|
| `run_all_test.sh --optimized` | Full matrix: 4 protocols × 10 scenarios × N runs (default 10, 60 s + 10 s warmup) on **veth namespaces**. Server pinned to cores 2,4 and client to 3,5, both with `chrt -f 50` (SCHED_FIFO). Netem is applied on both veth ends. | `benchmark_results/all_test_optimized_<timestamp>/` |
| `run_all_test.sh --unoptimized` | The same matrix on **loopback** (`127.0.0.1`): netem on `dev lo`, no namespaces, no pinning, no RT scheduling. | `benchmark_results/all_test_unoptimized_<timestamp>/` |
| `run_full_suite.sh` | The original version of the optimized matrix (veth + pinning + SCHED_FIFO). It's kept for comparison; it uses `../` relative paths and CRLF endings. | `../benchmark_results/<timestamp>/` |
| `run_optimized.sh [--monitored]` | Validation run: **QUIC only, 2 % loss**, 30 runs, veth + pinning + SCHED_FIFO. It rebuilds the namespaces on each invocation and starts `sleep infinity` anchors inside them so the ubenchmon monitor can read veth statistics. It prompts if cores 2–5 aren't isolated or a hypervisor is detected. | `validation_optimized[_monitored]_<timestamp>/` |
| `run_unoptimized.sh --transport lo\|veth` | Validation counterpart: QUIC only, 2 % loss, 30 runs, no pinning and no RT scheduling. Runs on loopback (default) or veth namespaces. | `validation_unoptimized_<lo\|veth>_<timestamp>/` |

How both `run_all_test.sh` modes run each scenario:
1. Apply netem and wait 2 s.
2. Ping 20 times → `ping_validation.txt`.
3. Write `config.txt` (description, mode, netem arguments, live `tc qdisc show`).
4. For each protocol and run, start the server, run the client, then stop the server. Ports start at 8000 for each scenario and increase per run.

At startup it also writes `system_info.txt` (CPU, SMT, boost, governor, virtualization, frequencies, kernel, boot command line, rustc, test parameters, transport) and a 100-ping baseline file.

**Scenario matrix** (netem values are per direction):

| Folder | netem |
|---|---|
| `01_baseline` | none |
| `02_latency_10ms` | `delay 10ms 1ms distribution normal` |
| `03_latency_30ms` | `delay 30ms 5ms` |
| `04_latency_50ms` | `delay 50ms 10ms` |
| `05_loss_1p` | `loss 1%` |
| `06_loss_2p` | `loss 2%` |
| `07_loss_5p` | `loss 5%` |
| `08_full_fiber` | `delay 5ms 1ms` |
| `09_full_good` | `delay 30ms 5ms loss 0.1%` |
| `10_full_bad` | `delay 80ms 20ms loss 2%` (poor mobile) |

Each echoed packet crosses one netem qdisc in each direction, so the expected round-trip loss is 1 − (1 − p)². At p = 2 % that's 3.96 %; the data measures 3.8–4.1 %.

### Post-processing

| Script | Purpose |
|---|---|
| `process_results.sh` | Runs `target/release/stats` on every CSV under `benchmark_results/` and writes `<run>.json` next to it. |
| `plot_jitter.py` | Per-run jitter scatter (unreliable stream) from the `quic_run*.json` files of one or more folders. Each `--run [Label=]DIR` becomes one series; the y-axis scale switches between linear and log automatically. Needs `matplotlib`. |

```bash
python3 -m venv .venv && . .venv/bin/activate && pip install matplotlib
./scripts/process_results.sh
python3 scripts/plot_jitter.py \
    --run "Optimized=benchmark_results/validation_optimized_bare" \
    --run "Unoptimized (lo)=benchmark_results/validation_unoptimized_lo_bare" \
    --out benchmark_results/figures/jitter.svg
```

### End-to-end workflow

```bash
RUSTFLAGS="-C target-cpu=native" cargo build --release
# 1. configure the host (ubenchmon, or GRUB isolation + prepare_bench.sh), reboot
sudo ./scripts/run_all_test.sh --optimized          # ~8 h with defaults
# 2. tear isolation down (SMT/CPB on, schedutil, no isolcpus), reboot
sudo ./scripts/run_all_test.sh --unoptimized        # ~8 h
# 3. statistics and figures
./scripts/process_results.sh
./target/release/stats benchmark_results/<folder> --all && ./target/release/plot benchmark_results/<folder>
```

---

## Data (`benchmark_results/`)

The timestamp suffixes the scripts add have been removed from the folder names.

### Test platform

- **CPU:** AMD Ryzen 7 3700X (Zen 2, 8 cores / 16 threads)
- **Memory:** 64 GB DDR4
- **OS:** Debian 13, kernel 6.12.107+deb13-amd64
- **Toolchain:** rustc 1.98.1
- **Isolated configuration:**
  - SMT off, CPB off (3.6 GHz), `performance` governor;
  - boot parameters `amd_pstate=disable isolcpus=2,3,4,5 nohz_full=2,3,4,5 rcu_nocbs=2,3,4,5 processor.max_cstate=0 nosoftlockup`.
- **Naïve configuration:**
  - SMT on, CPB on, `schedutil` governor;
  - boot parameters `amd_pstate=disable` only.

### Full matrix (4 protocols × 10 scenarios × 10 runs = 400 runs each)

| Folder | Transport | Scheduling | Host isolation | Produced by |
|---|---|---|---|---|
| `all_test_optimized` | veth namespaces, netem on both ends | taskset (2,4 / 3,5) + SCHED_FIFO 50 | yes | `run_all_test.sh --optimized` |
| `all_test_unoptimized_lo` | loopback, netem on `dev lo` | none | no | `run_all_test.sh --unoptimized` |
| `all_test_unoptimized_veth` | veth namespaces, netem on both ends | none | no | an earlier revision of `run_all_test.sh --unoptimized` that used veth. Kept as an ablation ("namespaces without isolation"). The current script can't reproduce it; `run_unoptimized.sh --transport veth` is the closest equivalent. |

### Validation runs (QUIC, 2 % loss, 30 runs each)

| Folder | Configuration | Produced by |
|---|---|---|
| `validation_optimized_bare` | isolated host, veth + pinning + SCHED_FIFO | `run_optimized.sh` |
| `validation_optimized_Idle`, `validation_optimized_Hammer` | as above, under the *Idle* and *Hammer* host-load conditions | `run_optimized.sh` |
| `validation_optimized_monitored_{bare,Idle,Hammer}` | as above, with the ubenchmon monitor running | `run_optimized.sh --monitored` |
| `validation_optimized_vm` | inside a KVM guest (QEMU vCPU) | `run_optimized.sh` |
| `validation_unoptimized_lo_{bare,Idle,Hammered}` | naïve host, loopback | `run_unoptimized.sh --transport lo` |
| `validation_unoptimized_lo_vm` | naïve, inside a KVM guest | `run_unoptimized.sh --transport lo` |
| `validation_unoptimized_veth_{bare,Idle,Hammered}` | naïve host, veth namespaces | `run_unoptimized.sh --transport veth` |

> **Load conditions:** *bare*, *Idle* and *Hammer(ed)* are the host-load conditions described in the paper's validation section. Each folder's `system_info.txt` records the exact host state.

`figures/` holds the jitter scatter plots made with `plot_jitter.py` from these folders:

| File | Comparison |
|---|---|
| `jitter_all_no_mon.svg` | all folders without monitoring |
| `jitter_all_no_vm.svg` | all folders except the VM runs |
| `jitter_no_vm_no_mon.svg` | no VM runs and no monitoring |
| `jitter_idle_vs_hammer.svg` | Idle vs Hammer |
| `jitter_vm.svg` | VM runs |
| `jitter_vm_vs_counterparts.svg` | VM runs vs their bare-metal counterparts |

### Files in each folder

```
<folder>/
├── system_info.txt              # hardware, SMT/boost/governor, kernel cmdline, rustc, parameters
├── baseline_{veth,lo}_latency.txt   # (all_test) 100-ping baseline without netem
├── ping_validation.txt          # (validation) ping with netem applied
└── <scenario>/                  # (all_test only)
    ├── config.txt               # scenario, mode, netem args, live qdisc
    ├── ping_validation.txt      # 20 pings with this scenario's netem
    ├── <proto>_runNN.csv        # raw per-packet data
    └── <proto>_runNN.json       # stats for that run
```

**CSV** has one row per echoed packet that arrived after the warmup:

```
recv_timestamp,packet_id,stream_id,rtt_us,payload_size
```

- `recv_timestamp`: µs since the Unix epoch;
- `stream_id`: 4 = unreliable, 11 = reliable;
- `rtt_us`: round-trip time in µs;
- `payload_size`: bytes after the 20-byte header.

**JSON** is the output of `stats <file.csv>`:

```json
{
  "global":  { "sent", "received", "lost", "loss_rate_percent",
               "throughput": { "duration_sec", "packet_rate_pps", "goodput_mbps" },
               "latency":    { "min_us", "avg_us", "max_us", "jitter_us",
                               "p50_us", "p90_us", "p95_us", "p99_us" } },
  "streams": [ { "stream_id": 4,  "stream_index": 1, "stream_type": "Unreliable", "stats": { … } },
               { "stream_id": 11, "stream_index": 2, "stream_type": "Reliable",   "stats": { … } } ]
}
```

### Headline numbers

QUIC, 2 % loss, unreliable stream, mean ± σ across runs:

| Metric | Naïve (loopback) | Isolated (veth) | Ratio |
|---|---|---|---|
| P50 | 203.4 ± 22.2 µs | 58.6 ± 0.5 µs | 3.5× |
| P99 | 724.5 ± 44.8 µs | 68.5 ± 2.0 µs | 10.6× |
| Jitter (σ of RTT, validation, n = 30) | 112.0 ± 18.7 µs | 3.7 ± 0.3 µs | 30× |
| Round-trip loss | 3.76 % | 3.83 % | same |

Percentiles come from `all_test_*` (n = 10); jitter comes from `validation_*_bare` (n = 30).

### Known caveats in the data

- **GNS under the isolated configuration** has a constant offset of about +2 ms in every scenario. For example, the baseline P50 is ≈2055 µs isolated vs ≈100 µs naïve. UDP, TCP and QUIC show no such offset. The cause hasn't been confirmed; one hypothesis is that GNS's internal threads compete for the two SCHED_FIFO cores.
- **TCP under poor mobile on loopback** (`all_test_unoptimized_lo/10_full_bad`) has a much lower P99 (≈0.6 s) than on veth (3.9–5.4 s, with or without isolation). This comes from the transport, not from isolation. A likely reason is that loopback keeps a 64 KiB MTU with offloads on, while the veth pair runs at MTU 1500 with offloads off.
- **Isolation only matters without emulated delay.** Once netem adds milliseconds of delay jitter, scheduler noise in the µs range is negligible: the isolated and naïve configurations agree within about 1–2 %.

---

## License

MIT; see [`LICENSE`](LICENSE).
