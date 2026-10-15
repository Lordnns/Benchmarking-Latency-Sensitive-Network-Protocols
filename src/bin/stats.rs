mod utils;

use std::env;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use serde::Serialize;
use crate::utils::BenchmarkRecord;

const RELIABILITY_MASK: u16 = 0b11;
const ORDERING_MASK: u16 = 0b10;

// =============================================================================
// Output Structures
// =============================================================================

/// Top-level report for a single (scenario, protocol) pair across N runs
#[derive(Serialize)]
struct AggregatedReport {
    scenario: String,
    protocol: String,
    num_runs: usize,
    global: AggregatedStats,
    streams: Vec<AggregatedStreamReport>,
}

#[derive(Serialize)]
struct AggregatedStreamReport {
    stream_id: u16,
    stream_index: u16,
    stream_type: String,
    stats: AggregatedStats,
}

/// Statistics aggregated across multiple runs
#[derive(Serialize)]
struct AggregatedStats {
    sent: SummaryStatistic,
    received: SummaryStatistic,
    lost: SummaryStatistic,
    loss_rate_percent: SummaryStatistic,
    throughput: AggregatedThroughput,
    latency: AggregatedLatency,
}

#[derive(Serialize)]
struct AggregatedThroughput {
    duration_sec: SummaryStatistic,
    packet_rate_pps: SummaryStatistic,
    goodput_mbps: SummaryStatistic,
}

#[derive(Serialize)]
struct AggregatedLatency {
    min_us: SummaryStatistic,
    avg_us: SummaryStatistic,
    max_us: SummaryStatistic,
    jitter_us: SummaryStatistic,
    p50_us: SummaryStatistic,
    p90_us: SummaryStatistic,
    p95_us: SummaryStatistic,
    p99_us: SummaryStatistic,
}

/// A single metric summarized across runs: median, mean, stddev, CI, min, max
#[derive(Serialize)]
struct SummaryStatistic {
    median: f64,
    mean: f64,
    stddev: f64,
    ci95_low: f64,
    ci95_high: f64,
    min: f64,
    max: f64,
    values: Vec<f64>, // raw per-run values for plotting error bars
}

// =============================================================================
// Per-run intermediate stats (same structure as your original)
// =============================================================================

struct SingleRunStats {
    sent: u64,
    received: u64,
    lost: u64,
    loss_rate_percent: f64,
    duration_sec: f64,
    packet_rate_pps: f64,
    goodput_mbps: f64,
    min_us: u64,
    avg_us: f64,
    max_us: u64,
    jitter_us: f64,
    p50_us: u64,
    p90_us: u64,
    p95_us: u64,
    p99_us: u64,
}

// =============================================================================
// Main
// =============================================================================

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage:");
        eprintln!("  Single file:  stats <file.csv>");
        eprintln!("  Multi-run:    stats <results_dir> [--scenario <name>] [--protocol <name>]");
        eprintln!("  Full sweep:   stats <results_dir> --all");
        return Ok(());
    }

    let path = Path::new(&args[1]);

    if path.is_file() {
        // Single file mode — backward compatible with original behavior
        let records = load_csv(path)?;
        let report = analyze_single_file(&records)?;
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else if path.is_dir() {
        if args.contains(&"--all".to_string()) {
            // Process entire sweep directory
            process_sweep_dir(path)?;
        } else {
            // Process specific scenario/protocol
            let scenario = args.iter().position(|a| a == "--scenario")
                .map(|i| args[i + 1].as_str());
            let protocol = args.iter().position(|a| a == "--protocol")
                .map(|i| args[i + 1].as_str());
            process_filtered(path, scenario, protocol)?;
        }
    } else {
        eprintln!("Error: '{}' is not a file or directory.", args[1]);
    }

    Ok(())
}

// =============================================================================
// Sweep Directory Processing
// =============================================================================

fn process_sweep_dir(base_dir: &Path) -> Result<(), Box<dyn Error>> {
    let output_dir = base_dir.join("aggregated");
    fs::create_dir_all(&output_dir)?;

    // Discover scenarios (subdirectories like 01_baseline, 02_latency_10ms, etc.)
    let mut scenarios: Vec<PathBuf> = fs::read_dir(base_dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir() && p.file_name().unwrap().to_str().unwrap() != "aggregated")
        .collect();
    scenarios.sort();

    for scenario_path in &scenarios {
        let scenario_name = scenario_path.file_name().unwrap().to_str().unwrap();

        // Discover protocols by looking at CSV filenames
        let protocols = discover_protocols(scenario_path);

        for protocol in &protocols {
            let run_files = find_run_files(scenario_path, protocol);

            if run_files.is_empty() {
                eprintln!("Warning: No run files for {}/{}", scenario_name, protocol);
                continue;
            }

            eprintln!("Processing {}/{} ({} runs)...", scenario_name, protocol, run_files.len());

            let report = aggregate_runs(scenario_name, protocol, &run_files)?;

            // Save aggregated JSON
            let out_file = output_dir.join(format!("{}_{}.json", scenario_name, protocol));
            let json = serde_json::to_string_pretty(&report)?;
            fs::write(&out_file, &json)?;
        }
    }

    eprintln!("Aggregated results saved to {}/", output_dir.display());
    Ok(())
}

fn process_filtered(base_dir: &Path, scenario: Option<&str>, protocol: Option<&str>) -> Result<(), Box<dyn Error>> {
    let mut scenarios: Vec<PathBuf> = fs::read_dir(base_dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    scenarios.sort();

    if let Some(s) = scenario {
        scenarios.retain(|p| p.file_name().unwrap().to_str().unwrap().contains(s));
    }

    let mut all_reports = Vec::new();

    for scenario_path in &scenarios {
        let scenario_name = scenario_path.file_name().unwrap().to_str().unwrap();
        let mut protocols = discover_protocols(scenario_path);

        if let Some(p) = protocol {
            protocols.retain(|proto| proto.eq_ignore_ascii_case(p));
        }

        for proto in &protocols {
            let run_files = find_run_files(scenario_path, proto);
            if run_files.is_empty() { continue; }

            let report = aggregate_runs(scenario_name, proto, &run_files)?;
            all_reports.push(report);
        }
    }

    println!("{}", serde_json::to_string_pretty(&all_reports)?);
    Ok(())
}

// =============================================================================
// File Discovery
// =============================================================================

/// Find unique protocol names from CSV files in a scenario directory.
/// Handles both formats: "quic.csv" (single run) and "quic_run01.csv" (multi-run)
fn discover_protocols(scenario_dir: &Path) -> Vec<String> {
    let mut protocols: Vec<String> = fs::read_dir(scenario_dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map_or(false, |ext| ext == "csv"))
        .filter_map(|p| {
            let stem = p.file_stem()?.to_str()?;
            // "quic_run01" -> "quic", "quic" -> "quic"
            let proto = if stem.contains("_run") {
                stem.split("_run").next()?
            } else {
                stem
            };
            Some(proto.to_string())
        })
        .collect();

    protocols.sort();
    protocols.dedup();
    protocols
}

/// Find all CSV files for a given protocol in a scenario directory.
/// Returns them sorted by name (run01, run02, ...).
fn find_run_files(scenario_dir: &Path, protocol: &str) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(scenario_dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.extension().map_or(false, |ext| ext == "csv")
                && p.file_stem()
                .and_then(|s| s.to_str())
                .map_or(false, |s| {
                    // Match "quic_run01.csv" or just "quic.csv"
                    s == protocol || s.starts_with(&format!("{}_run", protocol))
                })
        })
        .collect();

    files.sort();
    files
}

// =============================================================================
// Aggregation Logic
// =============================================================================

fn aggregate_runs(scenario: &str, protocol: &str, run_files: &[PathBuf]) -> Result<AggregatedReport, Box<dyn Error>> {
    // Compute per-run stats for each file
    let mut all_run_stats: Vec<HashMap<u16, SingleRunStats>> = Vec::new();
    let mut all_global_stats: Vec<SingleRunStats> = Vec::new();
    let mut stream_meta: HashMap<u16, (u16, String)> = HashMap::new(); // stream_id -> (index, type)

    for file in run_files {
        let records = load_csv(file)?;
        if records.is_empty() { continue; }

        // Group by stream
        let mut streams: HashMap<u16, Vec<&BenchmarkRecord>> = HashMap::new();
        for r in &records {
            streams.entry(r.stream_id).or_default().push(r);
        }

        let mut run_stream_stats: HashMap<u16, SingleRunStats> = HashMap::new();
        let mut global_sent = 0u64;
        let mut global_received = 0u64;
        let mut global_lost = 0u64;

        let mut stream_ids: Vec<u16> = streams.keys().cloned().collect();
        stream_ids.sort();

        for &stream_id in &stream_ids {
            let stream_records = streams.get(&stream_id).unwrap();

            let min_id = stream_records.iter().map(|r| r.packet_id).min().unwrap_or(0);
            let max_id = stream_records.iter().map(|r| r.packet_id).max().unwrap_or(0);
            let received = stream_records.len() as u64;
            let sent = if received > 0 { max_id - min_id + 1 } else { 0 };
            let lost = sent.saturating_sub(received);

            global_sent += sent;
            global_received += received;
            global_lost += lost;

            // Store stream metadata (only needs to happen once)
            if !stream_meta.contains_key(&stream_id) {
                let index = stream_id >> 2;
                let is_ordered = (stream_id & ORDERING_MASK) != 0;
                let is_reliable_flag = (stream_id & RELIABILITY_MASK) == RELIABILITY_MASK;
                let type_label = if is_reliable_flag { "Reliable" } else if is_ordered { "Ordered" } else { "Unreliable" };
                stream_meta.insert(stream_id, (index, type_label.to_string()));
            }

            let stats = compute_single_run(sent, received, lost, stream_records);
            run_stream_stats.insert(stream_id, stats);
        }

        // Global stats for this run
        let all_refs: Vec<&BenchmarkRecord> = records.iter().collect();
        let global = compute_single_run(global_sent, global_received, global_lost, &all_refs);
        all_global_stats.push(global);
        all_run_stats.push(run_stream_stats);
    }

    // Aggregate global stats across runs
    let global_agg = aggregate_single_run_vec(&all_global_stats);

    // Aggregate per-stream stats across runs
    let mut stream_reports = Vec::new();
    let mut all_stream_ids: Vec<u16> = stream_meta.keys().cloned().collect();
    all_stream_ids.sort();

    for stream_id in all_stream_ids {
        let (index, type_label) = stream_meta.get(&stream_id).unwrap();

        let per_stream_runs: Vec<&SingleRunStats> = all_run_stats.iter()
            .filter_map(|run| run.get(&stream_id))
            .collect();

        if per_stream_runs.is_empty() { continue; }

        let stats = aggregate_single_run_refs(&per_stream_runs);

        stream_reports.push(AggregatedStreamReport {
            stream_id,
            stream_index: *index,
            stream_type: type_label.clone(),
            stats,
        });
    }

    Ok(AggregatedReport {
        scenario: scenario.to_string(),
        protocol: protocol.to_string(),
        num_runs: run_files.len(),
        global: global_agg,
        streams: stream_reports,
    })
}

// =============================================================================
// Single-Run Computation (same logic as your original)
// =============================================================================

fn compute_single_run(sent: u64, received: u64, lost: u64, records: &[&BenchmarkRecord]) -> SingleRunStats {
    let loss_rate = if sent > 0 { (lost as f64 / sent as f64) * 100.0 } else { 0.0 };

    if records.is_empty() {
        return SingleRunStats {
            sent, received, lost, loss_rate_percent: loss_rate,
            duration_sec: 0.0, packet_rate_pps: 0.0, goodput_mbps: 0.0,
            min_us: 0, avg_us: 0.0, max_us: 0, jitter_us: 0.0,
            p50_us: 0, p90_us: 0, p95_us: 0, p99_us: 0,
        };
    }

    // Throughput
    let min_time = records.iter().map(|r| r.recv_timestamp).min().unwrap();
    let max_time = records.iter().map(|r| r.recv_timestamp).max().unwrap();
    let duration_us = max_time - min_time;
    let duration_sec = duration_us as f64 / 1_000_000.0;

    let total_bytes: usize = records.iter().map(|r| r.payload_size).sum();
    let goodput_mbps = if duration_us > 0 {
        (total_bytes as f64 * 8.0) / (duration_us as f64)
    } else { 0.0 };

    let pps = if duration_sec > 0.0 { received as f64 / duration_sec } else { 0.0 };

    // Latency
    let mut rtts: Vec<u64> = records.iter().map(|r| r.rtt_us).collect();
    rtts.sort_unstable();

    let min_rtt = *rtts.first().unwrap_or(&0);
    let max_rtt = *rtts.last().unwrap_or(&0);
    let sum_rtt: u64 = rtts.iter().sum();
    let avg_rtt = sum_rtt as f64 / received as f64;

    let variance = rtts.iter().map(|val| {
        let diff = avg_rtt - (*val as f64);
        diff * diff
    }).sum::<f64>() / received as f64;
    let jitter = variance.sqrt();

    SingleRunStats {
        sent, received, lost, loss_rate_percent: loss_rate,
        duration_sec, packet_rate_pps: pps, goodput_mbps,
        min_us: min_rtt, avg_us: avg_rtt, max_us: max_rtt, jitter_us: jitter,
        p50_us: percentile(&rtts, 0.50),
        p90_us: percentile(&rtts, 0.90),
        p95_us: percentile(&rtts, 0.95),
        p99_us: percentile(&rtts, 0.99),
    }
}

// =============================================================================
// Cross-Run Aggregation
// =============================================================================

fn aggregate_single_run_vec(runs: &[SingleRunStats]) -> AggregatedStats {
    let refs: Vec<&SingleRunStats> = runs.iter().collect();
    aggregate_single_run_refs(&refs)
}

fn aggregate_single_run_refs(runs: &[&SingleRunStats]) -> AggregatedStats {
    AggregatedStats {
        sent: summarize(&runs.iter().map(|r| r.sent as f64).collect::<Vec<_>>()),
        received: summarize(&runs.iter().map(|r| r.received as f64).collect::<Vec<_>>()),
        lost: summarize(&runs.iter().map(|r| r.lost as f64).collect::<Vec<_>>()),
        loss_rate_percent: summarize(&runs.iter().map(|r| r.loss_rate_percent).collect::<Vec<_>>()),
        throughput: AggregatedThroughput {
            duration_sec: summarize(&runs.iter().map(|r| r.duration_sec).collect::<Vec<_>>()),
            packet_rate_pps: summarize(&runs.iter().map(|r| r.packet_rate_pps).collect::<Vec<_>>()),
            goodput_mbps: summarize(&runs.iter().map(|r| r.goodput_mbps).collect::<Vec<_>>()),
        },
        latency: AggregatedLatency {
            min_us: summarize(&runs.iter().map(|r| r.min_us as f64).collect::<Vec<_>>()),
            avg_us: summarize(&runs.iter().map(|r| r.avg_us).collect::<Vec<_>>()),
            max_us: summarize(&runs.iter().map(|r| r.max_us as f64).collect::<Vec<_>>()),
            jitter_us: summarize(&runs.iter().map(|r| r.jitter_us).collect::<Vec<_>>()),
            p50_us: summarize(&runs.iter().map(|r| r.p50_us as f64).collect::<Vec<_>>()),
            p90_us: summarize(&runs.iter().map(|r| r.p90_us as f64).collect::<Vec<_>>()),
            p95_us: summarize(&runs.iter().map(|r| r.p95_us as f64).collect::<Vec<_>>()),
            p99_us: summarize(&runs.iter().map(|r| r.p99_us as f64).collect::<Vec<_>>()),
        },
    }
}

/// Compute summary statistics for a set of values (one per run).
/// Uses t-distribution for CI when n < 30, z=1.96 otherwise.
fn summarize(values: &[f64]) -> SummaryStatistic {
    if values.is_empty() {
        return SummaryStatistic {
            median: 0.0, mean: 0.0, stddev: 0.0,
            ci95_low: 0.0, ci95_high: 0.0,
            min: 0.0, max: 0.0, values: vec![],
        };
    }

    let n = values.len() as f64;
    let mean = values.iter().sum::<f64>() / n;

    let variance = if values.len() > 1 {
        values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0)
    } else {
        0.0
    };
    let stddev = variance.sqrt();

    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let median = if sorted.len() % 2 == 0 {
        (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2.0
    } else {
        sorted[sorted.len() / 2]
    };

    // 95% CI: use t-distribution critical values for small n
    let t_crit = t_critical_95(values.len());
    let margin = t_crit * stddev / n.sqrt();

    SummaryStatistic {
        median,
        mean,
        stddev,
        ci95_low: mean - margin,
        ci95_high: mean + margin,
        min: *sorted.first().unwrap(),
        max: *sorted.last().unwrap(),
        values: values.to_vec(),
    }
}

/// Two-tailed t-distribution critical values for 95% CI.
/// For df = n-1. Covers common run counts.
fn t_critical_95(n: usize) -> f64 {
    match n {
        0 | 1 => 0.0,        // undefined / no CI possible
        2 => 12.706,
        3 => 4.303,
        4 => 3.182,
        5 => 2.776,
        6 => 2.571,
        7 => 2.447,
        8 => 2.365,
        9 => 2.306,
        10 => 2.262,
        11 => 2.228,
        12 => 2.201,
        13 => 2.179,
        14 => 2.160,
        15 => 2.145,
        16..=20 => 2.086,
        21..=30 => 2.042,
        _ => 1.960,           // z-approximation for n > 30
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn load_csv(path: &Path) -> Result<Vec<BenchmarkRecord>, Box<dyn Error>> {
    let mut reader = csv::Reader::from_path(path)?;
    let mut records = Vec::new();
    for result in reader.deserialize() {
        records.push(result?);
    }
    Ok(records)
}

fn percentile(sorted_data: &[u64], pct: f64) -> u64 {
    if sorted_data.is_empty() { return 0; }
    let index = (pct * (sorted_data.len() - 1) as f64) as usize;
    sorted_data[index]
}

// Legacy single-file output (backward compatible)
#[derive(Serialize)]
struct SingleFileReport {
    global: LegacyStats,
    streams: Vec<LegacyStreamReport>,
}

#[derive(Serialize)]
struct LegacyStreamReport {
    stream_id: u16,
    stream_index: u16,
    stream_type: String,
    stats: LegacyStats,
}

#[derive(Serialize)]
struct LegacyStats {
    sent: u64,
    received: u64,
    lost: u64,
    loss_rate_percent: f64,
    throughput: LegacyThroughput,
    latency: LegacyLatency,
}

#[derive(Serialize)]
struct LegacyThroughput {
    duration_sec: f64,
    packet_rate_pps: f64,
    goodput_mbps: f64,
}

#[derive(Serialize)]
struct LegacyLatency {
    min_us: u64,
    avg_us: f64,
    max_us: u64,
    jitter_us: f64,
    p50_us: u64,
    p90_us: u64,
    p95_us: u64,
    p99_us: u64,
}

fn analyze_single_file(records: &[BenchmarkRecord]) -> Result<SingleFileReport, Box<dyn Error>> {
    if records.is_empty() {
        return Err("No records found.".into());
    }

    let mut streams: HashMap<u16, Vec<&BenchmarkRecord>> = HashMap::new();
    for r in records {
        streams.entry(r.stream_id).or_default().push(r);
    }

    let mut stream_reports = Vec::new();
    let mut stream_ids: Vec<u16> = streams.keys().cloned().collect();
    stream_ids.sort();

    let mut global_sent = 0u64;
    let mut global_received = 0u64;
    let mut global_lost = 0u64;

    for stream_id in stream_ids {
        let stream_records = streams.get(&stream_id).unwrap();

        let min_id = stream_records.iter().map(|r| r.packet_id).min().unwrap_or(0);
        let max_id = stream_records.iter().map(|r| r.packet_id).max().unwrap_or(0);
        let received = stream_records.len() as u64;
        let sent = if received > 0 { max_id - min_id + 1 } else { 0 };
        let lost = sent.saturating_sub(received);

        global_sent += sent;
        global_received += received;
        global_lost += lost;

        let index = stream_id >> 2;
        let is_ordered = (stream_id & ORDERING_MASK) != 0;
        let is_reliable_flag = (stream_id & RELIABILITY_MASK) == RELIABILITY_MASK;
        let type_label = if is_reliable_flag { "Reliable" } else if is_ordered { "Ordered" } else { "Unreliable" };

        let stats = compute_single_run(sent, received, lost, stream_records);

        stream_reports.push(LegacyStreamReport {
            stream_id,
            stream_index: index,
            stream_type: type_label.to_string(),
            stats: single_run_to_legacy(&stats),
        });
    }

    let all_refs: Vec<&BenchmarkRecord> = records.iter().collect();
    let global = compute_single_run(global_sent, global_received, global_lost, &all_refs);

    Ok(SingleFileReport {
        global: single_run_to_legacy(&global),
        streams: stream_reports,
    })
}

fn single_run_to_legacy(s: &SingleRunStats) -> LegacyStats {
    LegacyStats {
        sent: s.sent, received: s.received, lost: s.lost,
        loss_rate_percent: s.loss_rate_percent,
        throughput: LegacyThroughput {
            duration_sec: s.duration_sec,
            packet_rate_pps: s.packet_rate_pps,
            goodput_mbps: s.goodput_mbps,
        },
        latency: LegacyLatency {
            min_us: s.min_us, avg_us: s.avg_us, max_us: s.max_us,
            jitter_us: s.jitter_us,
            p50_us: s.p50_us, p90_us: s.p90_us, p95_us: s.p95_us, p99_us: s.p99_us,
        },
    }
}