use std::collections::HashMap;
use plotters::prelude::*;
use serde::Deserialize;
use std::fs::File;
use std::io::BufReader;
use std::ops::Range;

// =============================================================================
// JSON Structures (matching aggregated stats.rs output)
// =============================================================================

#[derive(Deserialize)]
struct AggregatedReport {
    scenario: String,
    protocol: String,
    num_runs: usize,
    global: AggregatedStats,
}

#[derive(Deserialize)]
struct AggregatedStats {
    latency: AggregatedLatency,
    loss_rate_percent: SummaryStatistic,
}

#[derive(Deserialize)]
struct AggregatedLatency {
    avg_us: SummaryStatistic,
    p50_us: SummaryStatistic,
    p95_us: SummaryStatistic,
    p99_us: SummaryStatistic,
}

#[derive(Deserialize)]
struct SummaryStatistic {
    median: f64,
    mean: f64,
    stddev: f64,
    ci95_low: f64,
    ci95_high: f64,
    min: f64,
    max: f64,
}

// =============================================================================
// Legacy JSON (backward compat for single-run files)
// =============================================================================

#[derive(Deserialize)]
struct LegacyJson {
    global: LegacyGlobal,
}

#[derive(Deserialize)]
struct LegacyGlobal {
    latency: LegacyLatency,
}

#[derive(Deserialize)]
struct LegacyLatency {
    avg_us: f64,
    p99_us: f64,
}

// =============================================================================
// Constants
// =============================================================================

const COLOR_UDP: RGBColor = RGBColor(127, 127, 127);
const COLOR_TCP: RGBColor = RGBColor(214, 39, 40);
const COLOR_QUIC: RGBColor = RGBColor(31, 119, 180);
const COLOR_GNS: RGBColor = RGBColor(44, 160, 44);

const UDP_NAME: &str = "UDP";
const TCP_NAME: &str = "TCP";
const QUIC_NAME: &str = "QUIC";
const GNS_NAME: &str = "GNS";

fn proto_color(name: &str) -> RGBColor {
    match name {
        UDP_NAME => COLOR_UDP,
        TCP_NAME => COLOR_TCP,
        QUIC_NAME => COLOR_QUIC,
        GNS_NAME => COLOR_GNS,
        _ => COLOR_GNS,
    }
}

// =============================================================================
// Data Loading
// =============================================================================

/// A data point with error bounds for one (x, protocol) combination
struct DataPoint {
    x: f64,
    protocol: String,
    median: f64,     // central value (plotted as line)
    ci_low: f64,     // 95% CI lower bound
    ci_high: f64,    // 95% CI upper bound
}

/// Load from aggregated JSON (new format from multi-run stats)
fn load_aggregated(path: &str) -> Option<AggregatedReport> {
    let file = File::open(path).ok()?;
    let reader = BufReader::new(file);
    serde_json::from_reader(reader).ok()
}

/// Load from legacy single-run JSON (backward compat)
fn load_legacy(path: &str) -> Option<LegacyJson> {
    let file = File::open(path).ok()?;
    let reader = BufReader::new(file);
    serde_json::from_reader(reader).ok()
}

/// Try aggregated first, fall back to legacy. Returns (median_ms, ci_low_ms, ci_high_ms).
fn load_p99_with_ci(path: &str) -> (f64, f64, f64) {
    if let Some(agg) = load_aggregated(path) {
        let stat = &agg.global.latency.p99_us;
        (stat.median / 1000.0, stat.ci95_low / 1000.0, stat.ci95_high / 1000.0)
    } else if let Some(legacy) = load_legacy(path) {
        let val = legacy.global.latency.p99_us / 1000.0;
        (val, val, val) // no CI for single run
    } else {
        eprintln!("Warning: Could not load {}", path);
        (0.0, 0.0, 0.0)
    }
}

fn load_avg_with_ci(path: &str) -> (f64, f64, f64) {
    if let Some(agg) = load_aggregated(path) {
        let stat = &agg.global.latency.avg_us;
        (stat.median / 1000.0, stat.ci95_low / 1000.0, stat.ci95_high / 1000.0)
    } else if let Some(legacy) = load_legacy(path) {
        let val = legacy.global.latency.avg_us / 1000.0;
        (val, val, val)
    } else {
        eprintln!("Warning: Could not load {}", path);
        (0.0, 0.0, 0.0)
    }
}

// =============================================================================
// Data Point Builders
// =============================================================================

fn build_latency_data(base: &str) -> Vec<DataPoint> {
    let scenarios = vec![
        (0.0, "01_baseline"),
        (10.0, "02_latency_10ms"),
        (30.0, "03_latency_30ms"),
        (50.0, "04_latency_50ms"),
    ];
    let protocols = vec![UDP_NAME, TCP_NAME, QUIC_NAME, GNS_NAME];

    let mut points = Vec::new();
    for (x, scenario) in &scenarios {
        for proto in &protocols {
            let path = format!("{}/aggregated/{}_{}.json", base, scenario, proto.to_lowercase());
            let (med, lo, hi) = load_p99_with_ci(&path);
            points.push(DataPoint {
                x: *x, protocol: proto.to_string(), median: med, ci_low: lo, ci_high: hi,
            });
        }
    }
    points
}

fn build_loss_data(base: &str, include_tcp: bool) -> Vec<DataPoint> {
    let scenarios = vec![
        (0.0, "01_baseline"),
        (1.0, "05_loss_1p"),
        (2.0, "06_loss_2p"),
        (5.0, "07_loss_5p"),
    ];
    let mut protocols = vec![UDP_NAME, QUIC_NAME, GNS_NAME];
    if include_tcp {
        protocols.insert(1, TCP_NAME);
    }

    let mut points = Vec::new();
    for (x, scenario) in &scenarios {
        for proto in &protocols {
            let path = format!("{}/aggregated/{}_{}.json", base, scenario, proto.to_lowercase());
            let (med, lo, hi) = load_p99_with_ci(&path);
            points.push(DataPoint {
                x: *x, protocol: proto.to_string(), median: med, ci_low: lo, ci_high: hi,
            });
        }
    }
    points
}

fn build_scenario_data(base: &str) -> Vec<DataPoint> {
    let scenarios = vec![
        (0.0, "08_full_fiber"),
        (1.0, "09_full_good"),
        (2.0, "10_full_bad"),
    ];
    let protocols = vec![UDP_NAME, TCP_NAME, QUIC_NAME, GNS_NAME];

    let mut points = Vec::new();
    for (x, scenario) in &scenarios {
        for proto in &protocols {
            let path = format!("{}/aggregated/{}_{}.json", base, scenario, proto.to_lowercase());
            let (med, lo, hi) = load_p99_with_ci(&path);
            points.push(DataPoint {
                x: *x, protocol: proto.to_string(), median: med, ci_low: lo, ci_high: hi,
            });
        }
    }
    points
}

// =============================================================================
// Chart Drawing with Error Bars
// =============================================================================

fn draw_line_chart_with_ci(
    path: &str,
    caption: &str,
    x_range: Range<f64>,
    y_range: Range<f64>,
    x_desc: &str,
    y_desc: &str,
    protocols: &[&str],
    data: &[DataPoint],
) -> Result<(), Box<dyn std::error::Error>> {
    let root = SVGBackend::new(path, (800, 600)).into_drawing_area();
    root.fill(&WHITE)?;

    let mut chart = ChartBuilder::on(&root)
        .caption(caption, ("sans-serif", 35).into_font())
        .margin(20)
        .x_label_area_size(50)
        .y_label_area_size(90)
        .build_cartesian_2d(x_range, y_range)?;

    chart.configure_mesh()
        .x_desc(x_desc)
        .y_desc(y_desc)
        .axis_desc_style(("sans-serif", 30))
        .label_style(("sans-serif", 20))
        .draw()?;

    for proto in protocols {
        let color = proto_color(proto);
        let proto_data: Vec<&DataPoint> = data.iter()
            .filter(|p| p.protocol == *proto)
            .collect();

        // Draw line (median values)
        let line_data: Vec<(f64, f64)> = proto_data.iter()
            .map(|p| (p.x, p.median))
            .collect();

        chart.draw_series(LineSeries::new(line_data, color.stroke_width(3)))?
            .label(proto.to_string())
            .legend(move |(x, y)| PathElement::new(vec![(x, y), (x + 20, y)], color.filled()));

        // Draw error bars (95% CI)
        for p in &proto_data {
            // Skip error bars if no CI (single run)
            if (p.ci_high - p.ci_low).abs() < 0.001 { continue; }

            // Vertical bar
            chart.draw_series(std::iter::once(
                PathElement::new(
                    vec![(p.x, p.ci_low), (p.x, p.ci_high)],
                    color.stroke_width(1),
                )
            ))?;

            // Top cap
            let cap_w = 0.3;
            chart.draw_series(std::iter::once(
                PathElement::new(
                    vec![(p.x - cap_w * 0.1, p.ci_high), (p.x + cap_w * 0.1, p.ci_high)],
                    color.stroke_width(1),
                )
            ))?;

            // Bottom cap
            chart.draw_series(std::iter::once(
                PathElement::new(
                    vec![(p.x - cap_w * 0.1, p.ci_low), (p.x + cap_w * 0.1, p.ci_low)],
                    color.stroke_width(1),
                )
            ))?;

            // Dot at median
            chart.draw_series(std::iter::once(
                Circle::new((p.x, p.median), 4, color.filled())
            ))?;
        }
    }

    chart.configure_series_labels()
        .background_style(&WHITE.mix(0.8))
        .border_style(&BLACK)
        .label_font(("sans-serif", 20))
        .draw()?;

    root.present()?;
    println!("Saved to {}", path);
    Ok(())
}

fn draw_bar_chart_with_ci(
    path: &str,
    caption: &str,
    y_max: f64,
    condition_names: &[&str],
    protocols: &[&str],
    data: &[DataPoint],
) -> Result<(), Box<dyn std::error::Error>> {
    let root = SVGBackend::new(path, (1000, 600)).into_drawing_area();
    root.fill(&WHITE)?;

    let mut chart = ChartBuilder::on(&root)
        .caption(caption, ("sans-serif", 40).into_font())
        .margin(20)
        .x_label_area_size(60)
        .y_label_area_size(110)
        .build_cartesian_2d(-0.5f64..condition_names.len() as f64 - 0.5, 0.0..y_max)?;

    chart.configure_mesh()
        .x_labels(condition_names.len())
        .y_desc("Latency (ms)")
        .axis_desc_style(("sans-serif", 35))
        .label_style(("sans-serif", 25))
        .x_label_formatter(&|v| {
            let idx = v.round();
            if (v - idx).abs() < 0.1 {
                let i = idx as usize;
                if i < condition_names.len() {
                    return condition_names[i].to_string();
                }
            }
            "".to_string()
        })
        .draw()?;

    let total_bars = protocols.len();
    let total_width_ratio = 0.8;
    let bar_width = total_width_ratio / total_bars as f64;

    for p in data {
        let group_idx = p.x as usize;
        let proto_idx = protocols.iter().position(|&name| name == p.protocol).unwrap_or(0);
        let color = proto_color(&p.protocol);

        let group_center = group_idx as f64;
        let group_start_x = group_center - (total_width_ratio / 2.0);
        let bar_start_x = group_start_x + (proto_idx as f64 * bar_width);
        let bar_end_x = bar_start_x + bar_width;
        let bar_center_x = (bar_start_x + bar_end_x) / 2.0;

        // Draw bar
        chart.draw_series(std::iter::once(
            Rectangle::new(
                [(bar_start_x, 0.0), (bar_end_x, p.median)],
                color.filled(),
            )
        ))?;

        // Draw error bar if CI exists
        if (p.ci_high - p.ci_low).abs() > 0.001 {
            let cap_w = bar_width * 0.3;

            // Vertical line
            chart.draw_series(std::iter::once(
                PathElement::new(
                    vec![(bar_center_x, p.ci_low), (bar_center_x, p.ci_high)],
                    BLACK.stroke_width(2),
                )
            ))?;

            // Top cap
            chart.draw_series(std::iter::once(
                PathElement::new(
                    vec![(bar_center_x - cap_w, p.ci_high), (bar_center_x + cap_w, p.ci_high)],
                    BLACK.stroke_width(2),
                )
            ))?;

            // Bottom cap
            chart.draw_series(std::iter::once(
                PathElement::new(
                    vec![(bar_center_x - cap_w, p.ci_low), (bar_center_x + cap_w, p.ci_low)],
                    BLACK.stroke_width(2),
                )
            ))?;
        }
    }

    // Legend
    for proto in protocols {
        let color = proto_color(proto);
        chart.draw_series(std::iter::once(PathElement::new(vec![], color.filled())))?
            .label(proto.to_string())
            .legend(move |(x, y)| Rectangle::new([(x, y - 5), (x + 10, y + 5)], color.filled()));
    }

    chart.configure_series_labels()
        .background_style(&WHITE.mix(0.8))
        .border_style(&BLACK)
        .label_font(("sans-serif", 20))
        .position(SeriesLabelPosition::UpperLeft)
        .draw()?;

    root.present()?;
    println!("Saved to {}", path);
    Ok(())
}

// =============================================================================
// Main
// =============================================================================

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let base = if args.len() > 1 { &args[1] } else { "benchmark_results" };

    let all_protocols = vec![UDP_NAME, TCP_NAME, QUIC_NAME, GNS_NAME];
    let no_tcp = vec![UDP_NAME, QUIC_NAME, GNS_NAME];

    // --- Line Charts ---

    let latency_data = build_latency_data(base);
    let loss_data_tcp = build_loss_data(base, true);
    let loss_data_no_tcp = build_loss_data(base, false);

    draw_line_chart_with_ci(
        "latency_trend.svg",
        "Protocol Latency vs Network Latency",
        0.0..60.0, 0.0..350.0,
        "Network Latency (ms)", "P99 Latency (ms)",
        &all_protocols, &latency_data,
    )?;

    draw_line_chart_with_ci(
        "packet_loss_trend_tcp.svg",
        "Latency vs Packet Loss",
        0.0..6.0, 0.0..450.0,
        "Packet Loss (%)", "P99 Latency (ms)",
        &all_protocols, &loss_data_tcp,
    )?;

    draw_line_chart_with_ci(
        "packet_loss_trend_no_tcp.svg",
        "Latency vs Packet Loss (No TCP)",
        0.0..6.0, 0.0..100.0,
        "Packet Loss (%)", "P99 Latency (ms)",
        &no_tcp, &loss_data_no_tcp,
    )?;

    // --- Bar Charts ---

    let scenario_data = build_scenario_data(base);
    let y_max = scenario_data.iter()
        .map(|p| p.ci_high.max(p.median))
        .fold(0.0f64, |a, b| a.max(b)) * 1.1;

    draw_bar_chart_with_ci(
        "scenario.svg",
        "Protocol Performance by Network Condition (P99)",
        y_max,
        &["Excellent", "Good", "Bad"],
        &all_protocols,
        &scenario_data,
    )?;

    Ok(())
}