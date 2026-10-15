#!/bin/bash

# ==============================================================================
# Run All Tests — full suite, optimized OR unoptimized
# ==============================================================================
# Same test matrix as run_full_suite.sh (UDP, TCP, QUIC, GNS × 10 scenarios),
# with a flag to choose how the server/client processes are launched:
#
#   --optimized    veth namespaces + symmetric netem on both veth ends,
#                  taskset core pinning + chrt -f 50 (SCHED_FIFO), 2 cores/process
#   --unoptimized  loopback (127.0.0.1), no namespaces, netem on dev lo,
#                  NO taskset, NO chrt (the naive baseline)
#
# On lo each direction crosses the netem qdisc once, so per-direction delay/loss
# matches the symmetric veth setup. Machine-level setup and teardown
# (isolcpus, governor, IRQs, SMT, ...) is done separately with ubenchmon.
#
# Build first: RUSTFLAGS="-C target-cpu=native" cargo build --release
#
# USAGE: sudo ./scripts/run_all_test.sh --optimized|--unoptimized [--runs N] [--duration N] [--warmup N]
# ==============================================================================

set -euo pipefail

# --- Configuration ---
DURATION=60                     # Duration of measured data in seconds
WARMUP=10                       # Warmup seconds (discarded by client)
RUNS=10                         # Runs per configuration
PROTOCOLS=("udp" "tcp" "quic" "gns")
MODE=""

# Paths are resolved from the script location, so it can be run from anywhere
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_BIN="$REPO_ROOT/target/release/server"
CLIENT_BIN="$REPO_ROOT/target/release/client"

# Core layout (optimized mode only):
#   Core 0    → OS, IRQs, housekeeping
#   Core 1    → Unused (buffer)
#   Cores 2,4 → Server (game loop + Tokio runtime)
#   Cores 3,5 → Client (game loop + Tokio runtime)
#   Cores 6,7 → Unused
SERVER_CORES="2,4"
CLIENT_CORES="3,5"
RT_PRIORITY=50

# Network namespace config
NS_SERVER="ns_server"
NS_CLIENT="ns_client"
SERVER_IP="10.0.0.1"
CLIENT_IP="10.0.0.2"

# --- Parse CLI Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --optimized)   MODE="optimized"; shift ;;
        --unoptimized) MODE="unoptimized"; shift ;;
        --runs)        RUNS="$2"; shift 2 ;;
        --duration)    DURATION="$2"; shift 2 ;;
        --warmup)      WARMUP="$2"; shift 2 ;;
        *)             echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "ERROR: pick a mode: --optimized or --unoptimized"
    exit 1
fi

# Unoptimized runs on loopback: server and client talk over 127.0.0.1
if [ "$MODE" = "unoptimized" ]; then
    SERVER_IP="127.0.0.1"
fi

RESULTS_DIR="$REPO_ROOT/benchmark_results/all_test_${MODE}_$(date +%Y%m%d_%H%M%S)"

# --- Preflight Checks ---
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root (needed for tc, namespaces, chrt)."
    exit 1
fi

if [ ! -f "$SERVER_BIN" ] || [ ! -f "$CLIENT_BIN" ]; then
    echo "Binaries not found. Build first with:"
    echo "  RUSTFLAGS=\"-C target-cpu=native\" cargo build --release"
    exit 1
fi

# Verify isolated cores (only matters when we pin to them)
ISOLATED=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || true)
ISOLATED=${ISOLATED:-none}
if [ "$MODE" = "optimized" ]; then
    if [[ "$ISOLATED" != *"2"* ]] || [[ "$ISOLATED" != *"5"* ]]; then
        echo "WARNING: Cores 2-5 are not all isolated (isolated=$ISOLATED)"
        echo "Expected: isolcpus=2,3,4,5"
        echo "Results will have higher variance. Continue anyway? [y/N]"
        read -r REPLY
        [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
    fi
fi

# --- Cleanup: never leave an orphaned (SCHED_FIFO) server behind ---
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    pkill -f "$SERVER_BIN" 2>/dev/null || true
    pkill -f "$CLIENT_BIN" 2>/dev/null || true
    if [ "$MODE" = "unoptimized" ]; then
        tc qdisc del dev lo root 2>/dev/null || true
    else
        ip netns exec "$NS_CLIENT" tc qdisc del dev veth-cli root 2>/dev/null || true
        ip netns exec "$NS_SERVER" tc qdisc del dev veth-srv root 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$RESULTS_DIR"

# ==============================================================================
# System Info Capture (for paper reproducibility)
# ==============================================================================
capture_system_info() {
    local INFO_FILE="$RESULTS_DIR/system_info.txt"
    {
        echo "=== Benchmark System Info ==="
        echo "Timestamp: $(date -Iseconds)"
        echo "Mode: $MODE"
        echo ""
        echo "--- Hardware ---"
        echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Cores: $(nproc) (isolated: $ISOLATED)"
        echo "RAM: $(free -h | awk '/Mem:/{print $2}')"
        echo "SMT active: $(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo '?')  (0=off, 1=on)"
        echo "Freq boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')  (1=on)"
        echo "Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
        echo "Virt: $(systemd-detect-virt 2>/dev/null || true)"
        echo ""
        echo "--- CPU Frequency ---"
        grep "cpu MHz" /proc/cpuinfo || true
        echo ""
        echo "--- Kernel ---"
        uname -a
        echo ""
        echo "--- Boot Parameters ---"
        cat /proc/cmdline
        echo ""
        echo "--- Rust Toolchain ---"
        rustc --version 2>/dev/null || echo "rustc not found"
        echo ""
        echo "--- Test Parameters ---"
        echo "Duration: ${DURATION}s + ${WARMUP}s warmup"
        echo "Runs per config: $RUNS"
        echo "Protocols: ${PROTOCOLS[*]}"
        if [ "$MODE" = "optimized" ]; then
            echo "Transport: veth namespaces ($SERVER_IP <-> $CLIENT_IP), netem on both veth ends"
            echo "Server cores: $SERVER_CORES | Client cores: $CLIENT_CORES"
            echo "Scheduling: taskset + SCHED_FIFO $RT_PRIORITY"
        else
            echo "Transport: loopback ($SERVER_IP), no namespaces, netem on dev lo"
            echo "Scheduling: none (no taskset, no chrt) — SCHED_OTHER, default affinity"
        fi
    } > "$INFO_FILE"
    echo "System info saved to $INFO_FILE"
}

# ==============================================================================
# Network Namespace Setup
# ==============================================================================
setup_namespaces() {
    echo "Setting up network namespaces..."

    # Kill anything still living in the namespaces (stale servers, old ubenchmon
    # anchors) so the old namespaces are really destroyed, not just unnamed
    for NS in "$NS_SERVER" "$NS_CLIENT"; do
        ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null || true
    done
    sleep 0.5

    ip netns del "$NS_SERVER" 2>/dev/null || true
    ip netns del "$NS_CLIENT" 2>/dev/null || true
    ip link del veth-srv 2>/dev/null || true

    ip netns add "$NS_SERVER"
    ip netns add "$NS_CLIENT"
    ip link add veth-srv type veth peer name veth-cli
    ip link set veth-srv netns "$NS_SERVER"
    ip link set veth-cli netns "$NS_CLIENT"

    ip netns exec "$NS_SERVER" ip addr add ${SERVER_IP}/24 dev veth-srv
    ip netns exec "$NS_SERVER" ip link set veth-srv up
    ip netns exec "$NS_SERVER" ip link set lo up
    ip netns exec "$NS_SERVER" ip link set veth-srv mtu 1500

    ip netns exec "$NS_CLIENT" ip addr add ${CLIENT_IP}/24 dev veth-cli
    ip netns exec "$NS_CLIENT" ip link set veth-cli up
    ip netns exec "$NS_CLIENT" ip link set lo up
    ip netns exec "$NS_CLIENT" ip link set veth-cli mtu 1500

    # Disable hardware offloading for accurate tc behavior
    ip netns exec "$NS_SERVER" ethtool -K veth-srv tx off rx off tso off gso off gro off 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ethtool -K veth-cli tx off rx off tso off gso off gro off 2>/dev/null || true

    # ubenchmon monitor anchors: lets ubenchmon read veth stats via
    # /proc/<pid>/root/sys/... (start/restart the ubenchmon monitor after this)
    ip netns exec "$NS_SERVER" sleep infinity </dev/null >/dev/null 2>&1 &
    ip netns exec "$NS_CLIENT" sleep infinity </dev/null >/dev/null 2>&1 &

    ip netns exec "$NS_CLIENT" ping -c 3 -q "$SERVER_IP" > /dev/null
    echo "Namespaces ready: $SERVER_IP <-> $CLIENT_IP"
}

# ==============================================================================
# TC/Netem Helpers
# ==============================================================================
apply_netem() {
    local NETEM_ARGS="$*"
    reset_netem
    if [ -n "$NETEM_ARGS" ]; then
        if [ "$MODE" = "unoptimized" ]; then
            tc qdisc add dev lo root netem $NETEM_ARGS
        else
            ip netns exec "$NS_CLIENT" tc qdisc add dev veth-cli root netem $NETEM_ARGS
            ip netns exec "$NS_SERVER" tc qdisc add dev veth-srv root netem $NETEM_ARGS
        fi
    fi
}

reset_netem() {
    if [ "$MODE" = "unoptimized" ]; then
        tc qdisc del dev lo root 2>/dev/null || true
    else
        ip netns exec "$NS_CLIENT" tc qdisc del dev veth-cli root 2>/dev/null || true
        ip netns exec "$NS_SERVER" tc qdisc del dev veth-srv root 2>/dev/null || true
    fi
}

show_netem() {
    if [ "$MODE" = "unoptimized" ]; then
        tc qdisc show dev lo 2>/dev/null || true
    else
        ip netns exec "$NS_CLIENT" tc qdisc show dev veth-cli 2>/dev/null || true
        ip netns exec "$NS_SERVER" tc qdisc show dev veth-srv 2>/dev/null || true
    fi
}

ping_server() {
    if [ "$MODE" = "unoptimized" ]; then
        ping "$@" "$SERVER_IP"
    else
        ip netns exec "$NS_CLIENT" ping "$@" "$SERVER_IP"
    fi
}

validate_netem() {
    local SCENARIO_DIR="$1"
    ping_server -c 20 -q > "$SCENARIO_DIR/ping_validation.txt" 2>&1 || true
}

# ==============================================================================
# Process Launchers (the only difference between the two modes)
# ==============================================================================
start_server() {
    local PROTO="$1" PORT="$2"
    if [ "$MODE" = "optimized" ]; then
        ip netns exec "$NS_SERVER" \
            taskset -c "$SERVER_CORES" \
            chrt -f "$RT_PRIORITY" \
            "$SERVER_BIN" "$PROTO" --port "$PORT" \
            > /dev/null 2>&1 &
    else
        "$SERVER_BIN" "$PROTO" --port "$PORT" \
            > /dev/null 2>&1 &
    fi
    SERVER_PID=$!
}

run_client() {
    local PROTO="$1" PORT="$2" OUTPUT_FILE="$3"
    # Total runtime = DURATION + WARMUP; first WARMUP seconds are discarded
    if [ "$MODE" = "optimized" ]; then
        ip netns exec "$NS_CLIENT" \
            taskset -c "$CLIENT_CORES" \
            chrt -f "$RT_PRIORITY" \
            "$CLIENT_BIN" "$PROTO" \
                --ip "$SERVER_IP" --port "$PORT" \
                --duration "$((DURATION + WARMUP))" --warmup "$WARMUP" \
                --results "$OUTPUT_FILE" \
                > /dev/null
    else
        "$CLIENT_BIN" "$PROTO" \
                --ip "$SERVER_IP" --port "$PORT" \
                --duration "$((DURATION + WARMUP))" --warmup "$WARMUP" \
                --results "$OUTPUT_FILE" \
                > /dev/null
    fi
}

# ==============================================================================
# Core Test Runner
# ==============================================================================
run_test_case() {
    local SCENARIO_NAME="$1"
    local SCENARIO_DESC="$2"
    shift 2
    local NETEM_ARGS="$*"

    echo "================================================================"
    echo "SCENARIO: $SCENARIO_NAME  [$MODE]"
    echo "CONFIG:   $SCENARIO_DESC"
    echo "================================================================"

    local SCENARIO_DIR="$RESULTS_DIR/$SCENARIO_NAME"
    mkdir -p "$SCENARIO_DIR"

    apply_netem $NETEM_ARGS
    sleep 2  # Let netem settle

    validate_netem "$SCENARIO_DIR"

    # Save the exact tc config used
    {
        echo "$SCENARIO_DESC"
        echo "mode: $MODE"
        echo "netem args: $NETEM_ARGS"
        show_netem
    } > "$SCENARIO_DIR/config.txt"

    local CURRENT_PORT=8000

    for PROTO in "${PROTOCOLS[@]}"; do
        echo "  Protocol: ${PROTO^^}"

        for RUN in $(seq 1 "$RUNS"); do
            local OUTPUT_FILE="$SCENARIO_DIR/${PROTO}_run$(printf '%02d' "$RUN").csv"
            echo "    [$(date +%H:%M:%S)] Run $RUN/$RUNS -> $(basename "$OUTPUT_FILE")"

            start_server "$PROTO" "$CURRENT_PORT"
            sleep 1  # Let server bind

            # A failed run is logged, not fatal — the sanity check at the end counts CSVs
            run_client "$PROTO" "$CURRENT_PORT" "$OUTPUT_FILE" \
                || echo "    WARNING: client exited non-zero ($PROTO run $RUN)"

            kill "$SERVER_PID" 2>/dev/null || true
            wait "$SERVER_PID" 2>/dev/null || true
            SERVER_PID=""
            sleep 1

            CURRENT_PORT=$((CURRENT_PORT + 1))
        done

        echo "    ${PROTO^^} complete."
    done
    echo ""
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
echo "=================================================================="
echo "  Run All Tests — Game Network Protocol Benchmark"
echo "=================================================================="
echo "  Mode:         $MODE"
echo "  Protocols:    ${PROTOCOLS[*]}"
echo "  Runs/config:  $RUNS"
echo "  Duration:     ${DURATION}s + ${WARMUP}s warmup"
if [ "$MODE" = "optimized" ]; then
    echo "  Scheduling:   server $SERVER_CORES, client $CLIENT_CORES, SCHED_FIFO $RT_PRIORITY"
else
    echo "  Transport:    loopback ($SERVER_IP), netem on dev lo"
    echo "  Scheduling:   no taskset, no chrt"
fi
echo ""

TOTAL_SCENARIOS=10
TOTAL_RUNS=$((TOTAL_SCENARIOS * ${#PROTOCOLS[@]} * RUNS))
TOTAL_SECONDS=$((TOTAL_RUNS * (DURATION + WARMUP + 2)))
echo "Estimated runtime: ~$((TOTAL_SECONDS / 3600))h$(printf '%02d' $((TOTAL_SECONDS % 3600 / 60)))m ($TOTAL_RUNS total runs)"
echo "Results directory: $RESULTS_DIR"
echo ""

capture_system_info
if [ "$MODE" = "optimized" ]; then
    setup_namespaces
    BASELINE_FILE="baseline_veth_latency.txt"
    BASELINE_DESC="No Network Emulation (veth direct)"
else
    reset_netem
    BASELINE_FILE="baseline_lo_latency.txt"
    BASELINE_DESC="No Network Emulation (loopback direct)"
fi

echo "Recording baseline latency..."
ping_server -c 100 > "$RESULTS_DIR/$BASELINE_FILE" 2>&1 || true

# --- 1. Baseline (no emulation) ---
run_test_case "01_baseline" \
    "$BASELINE_DESC" \
    ""

# --- 2. Latency (symmetric: RTT = 2 × delay ± jitter) ---
run_test_case "02_latency_10ms" \
    "Latency: 10ms ±1ms each way (RTT ~20ms)" \
    "delay 10ms 1ms distribution normal"

run_test_case "03_latency_30ms" \
    "Latency: 30ms ±5ms each way (RTT ~60ms)" \
    "delay 30ms 5ms distribution normal"

run_test_case "04_latency_50ms" \
    "Latency: 50ms ±10ms each way (RTT ~100ms)" \
    "delay 50ms 10ms distribution normal"

# --- 3. Packet loss (symmetric) ---
run_test_case "05_loss_1p" \
    "Packet Loss: 1% (symmetric)" \
    "loss 1%"

run_test_case "06_loss_2p" \
    "Packet Loss: 2% (symmetric)" \
    "loss 2%"

run_test_case "07_loss_5p" \
    "Packet Loss: 5% (symmetric)" \
    "loss 5%"

# --- 4. Realistic composite scenarios ---
run_test_case "08_full_fiber" \
    "Fiber: 5ms ±1ms delay (RTT ~10ms)" \
    "delay 5ms 1ms distribution normal"

run_test_case "09_full_good" \
    "Good (Cable/DSL): 30ms ±5ms delay, 0.1% loss (RTT ~60ms)" \
    "delay 30ms 5ms distribution normal loss 0.1%"

run_test_case "10_full_bad" \
    "Bad (WiFi/4G): 80ms ±20ms delay, 2% loss (RTT ~160ms)" \
    "delay 80ms 20ms distribution normal loss 2%"

# ==============================================================================
# Summary
# ==============================================================================
reset_netem

TOTAL_FILES=$(find "$RESULTS_DIR" -name "*.csv" | wc -l)
EXPECTED=$((TOTAL_SCENARIOS * ${#PROTOCOLS[@]} * RUNS))

echo "=================================================================="
echo "  All tests completed [$MODE]"
echo "  Results: $RESULTS_DIR"
echo "=================================================================="
if [ "$TOTAL_FILES" -ne "$EXPECTED" ]; then
    echo "WARNING: Expected $EXPECTED CSV files but found $TOTAL_FILES — some runs failed."
else
    echo "All $EXPECTED runs completed successfully."
fi
echo ""
echo "Next steps:"
echo "  Aggregate: $REPO_ROOT/target/release/stats $RESULTS_DIR --all"
echo "  Plot:      $REPO_ROOT/target/release/plot $RESULTS_DIR"
