#!/bin/bash

# ==============================================================================
# Game Network Protocol Benchmark Suite — Research Edition
# ==============================================================================
# Benchmarks UDP, TCP, QUIC, and GNS under controlled network conditions.
#
# Key design decisions:
#   - Uses network namespaces + veth instead of loopback (realistic tc behavior)
#   - Each process gets 2 isolated cores: one for the game loop, one for the
#     async I/O runtime (Tokio). This prevents SCHED_FIFO starvation and
#     reflects realistic multi-threaded deployment.
#   - Multiple runs per configuration for statistical validity
#   - Warmup period discarded from measurements
#   - Captures system info for paper reproducibility
#
# PREREQUISITES:
#   - Debian 13 with: isolcpus=2,3,4,5 nohz_full=2,3,4,5 rcu_nocbs=2,3,4,5
#   - SMT disabled in BIOS, CPB disabled
#   - Run prepare_bench.sh first
#   - Build first: RUSTFLAGS="-C target-cpu=native" cargo build --release
#
# USAGE: sudo ./run_full_suite.sh [--runs N] [--duration N] [--warmup N]
# ==============================================================================

set -euo pipefail

# --- Configuration ---
DURATION=60                     # Duration of measured data in seconds
WARMUP=10                       # Warmup seconds (discarded by client)
RUNS=10                         # Runs per configuration
PROTOCOLS=("udp" "tcp" "quic" "gns")
RESULTS_DIR="../benchmark_results/$(date +%Y%m%d_%H%M%S)"
SERVER_BIN="../target/release/server"
CLIENT_BIN="../target/release/client"

# Hardware isolation (Ryzen 7 3800X, SMT off, 8 physical cores)
# Each process needs 2 cores: main thread + Tokio async runtime thread.
# Without this, SCHED_FIFO on a single core starves the runtime thread.
#
# Core layout (verify with lscpu -e after boot):
#   CCX 0: cores 0,1,2,3  (share 16MB L3)
#   CCX 1: cores 4,5,6,7  (share 16MB L3)
#
#   Core 0    → OS, IRQs, housekeeping
#   Core 1    → Unused (buffer)
#   Cores 2,4 → Server (game loop on 2, Tokio on 4)
#   Cores 3,5 → Client (game loop on 3, Tokio on 5)
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
        --runs)       RUNS="$2"; shift 2 ;;
        --duration)   DURATION="$2"; shift 2 ;;
        --warmup)     WARMUP="$2"; shift 2 ;;
        *)            echo "Unknown arg: $1"; exit 1 ;;
    esac
done

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

# Verify isolated cores
ISOLATED=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none")
if [[ "$ISOLATED" != *"2"* ]] || [[ "$ISOLATED" != *"5"* ]]; then
    echo "WARNING: Cores 2-5 are not all isolated (isolated=$ISOLATED)"
    echo "Expected: isolcpus=2,3,4,5"
    echo "Results will have higher variance. Continue anyway? [y/N]"
    read -r REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
fi

# --- Create Results Directory ---
mkdir -p "$RESULTS_DIR"

# ==============================================================================
# System Info Capture (for paper reproducibility)
# ==============================================================================
capture_system_info() {
    local INFO_FILE="$RESULTS_DIR/system_info.txt"
    {
        echo "=== Benchmark System Info ==="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
        echo "--- Hardware ---"
        echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Cores: $(nproc) (isolated: $ISOLATED)"
        echo "RAM: $(free -h | awk '/Mem:/{print $2}')"
        echo ""
        echo "--- CPU Frequency ---"
        grep "cpu MHz" /proc/cpuinfo
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
        echo "Server cores: $SERVER_CORES | Client cores: $CLIENT_CORES"
        echo "RT priority: SCHED_FIFO $RT_PRIORITY"
    } > "$INFO_FILE"
    echo "System info saved to $INFO_FILE"
}

# ==============================================================================
# Network Namespace Setup
# ==============================================================================
setup_namespaces() {
    echo "Setting up network namespaces..."

    # Clean up any previous run
    ip netns del "$NS_SERVER" 2>/dev/null || true
    ip netns del "$NS_CLIENT" 2>/dev/null || true
    ip link del veth-srv 2>/dev/null || true

    # Create namespaces
    ip netns add "$NS_SERVER"
    ip netns add "$NS_CLIENT"

    # Create veth pair
    ip link add veth-srv type veth peer name veth-cli

    # Assign to namespaces
    ip link set veth-srv netns "$NS_SERVER"
    ip link set veth-cli netns "$NS_CLIENT"

    # Configure server side
    ip netns exec "$NS_SERVER" ip addr add ${SERVER_IP}/24 dev veth-srv
    ip netns exec "$NS_SERVER" ip link set veth-srv up
    ip netns exec "$NS_SERVER" ip link set lo up
    ip netns exec "$NS_SERVER" ip link set veth-srv mtu 1500

    # Configure client side
    ip netns exec "$NS_CLIENT" ip addr add ${CLIENT_IP}/24 dev veth-cli
    ip netns exec "$NS_CLIENT" ip link set veth-cli up
    ip netns exec "$NS_CLIENT" ip link set lo up
    ip netns exec "$NS_CLIENT" ip link set veth-cli mtu 1500

    # Disable hardware offloading for accurate tc behavior
    ip netns exec "$NS_SERVER" ethtool -K veth-srv tx off rx off tso off gso off gro off 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ethtool -K veth-cli tx off rx off tso off gso off gro off 2>/dev/null || true

    # Verify connectivity
    ip netns exec "$NS_CLIENT" ping -c 3 -q "$SERVER_IP" > /dev/null
    echo "Namespaces ready: $SERVER_IP <-> $CLIENT_IP"
}

# ==============================================================================
# TC/Netem Helpers
# ==============================================================================

apply_netem() {
    local NETEM_ARGS="$*"

    # Clear existing
    ip netns exec "$NS_CLIENT" tc qdisc del dev veth-cli root 2>/dev/null || true
    ip netns exec "$NS_SERVER" tc qdisc del dev veth-srv root 2>/dev/null || true

    if [ -n "$NETEM_ARGS" ]; then
        ip netns exec "$NS_CLIENT" tc qdisc add dev veth-cli root netem $NETEM_ARGS
        ip netns exec "$NS_SERVER" tc qdisc add dev veth-srv root netem $NETEM_ARGS
    fi
}

reset_netem() {
    ip netns exec "$NS_CLIENT" tc qdisc del dev veth-cli root 2>/dev/null || true
    ip netns exec "$NS_SERVER" tc qdisc del dev veth-srv root 2>/dev/null || true
}

validate_netem() {
    local SCENARIO_DIR="$1"
    ip netns exec "$NS_CLIENT" ping -c 20 -q "$SERVER_IP" \
        > "$SCENARIO_DIR/ping_validation.txt" 2>&1
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
    echo "SCENARIO: $SCENARIO_NAME"
    echo "CONFIG:   $SCENARIO_DESC"
    echo "================================================================"

    local SCENARIO_DIR="$RESULTS_DIR/$SCENARIO_NAME"
    mkdir -p "$SCENARIO_DIR"

    # Apply network conditions
    reset_netem
    if [ -n "$NETEM_ARGS" ]; then
        apply_netem $NETEM_ARGS
    fi
    sleep 2  # Let netem settle

    # Validate conditions
    validate_netem "$SCENARIO_DIR"

    # Save the exact tc config used
    echo "$SCENARIO_DESC" > "$SCENARIO_DIR/config.txt"
    echo "netem args: $NETEM_ARGS" >> "$SCENARIO_DIR/config.txt"
    ip netns exec "$NS_CLIENT" tc qdisc show dev veth-cli >> "$SCENARIO_DIR/config.txt" 2>/dev/null
    ip netns exec "$NS_SERVER" tc qdisc show dev veth-srv >> "$SCENARIO_DIR/config.txt" 2>/dev/null

    local CURRENT_PORT=8000

    for PROTO in "${PROTOCOLS[@]}"; do
        echo "  Protocol: ${PROTO^^}"

        for RUN in $(seq 1 "$RUNS"); do
            local OUTPUT_FILE="$SCENARIO_DIR/${PROTO}_run$(printf '%02d' $RUN).csv"
            echo "    Run $RUN/$RUNS -> $(basename $OUTPUT_FILE)"

            # 1. Start Server — pinned to 2 cores, RT priority, in server namespace
            ip netns exec "$NS_SERVER" \
                taskset -c "$SERVER_CORES" \
                chrt -f "$RT_PRIORITY" \
                "$SERVER_BIN" "$PROTO" \
                    --port "$CURRENT_PORT" \
                    > /dev/null 2>&1 &
            local SERVER_PID=$!
            sleep 1  # Let server bind

            # 2. Run Client — pinned to 2 cores, RT priority, in client namespace
            #    Total runtime = DURATION + WARMUP; first WARMUP seconds are discarded
            ip netns exec "$NS_CLIENT" \
                taskset -c "$CLIENT_CORES" \
                chrt -f "$RT_PRIORITY" \
                "$CLIENT_BIN" "$PROTO" \
                    --ip "$SERVER_IP" \
                    --port "$CURRENT_PORT" \
                    --duration "$((DURATION + WARMUP))" \
                    --warmup "$WARMUP" \
                    --results "$OUTPUT_FILE" \
                    > /dev/null

            # 3. Cleanup
            kill "$SERVER_PID" 2>/dev/null || true
            wait "$SERVER_PID" 2>/dev/null || true
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

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║       Game Network Protocol Benchmark Suite — Research Edition  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Protocols: UDP, TCP, QUIC, GNS                                ║"
echo "║  Runs/config: $RUNS                                            ║"
echo "║  Duration: ${DURATION}s + ${WARMUP}s warmup                    ║"
echo "║  Server cores: $SERVER_CORES (game loop + async I/O)           ║"
echo "║  Client cores: $CLIENT_CORES (game loop + async I/O)           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Estimate total time
TOTAL_SCENARIOS=10
TOTAL_RUNS=$((TOTAL_SCENARIOS * ${#PROTOCOLS[@]} * RUNS))
TOTAL_SECONDS=$((TOTAL_RUNS * (DURATION + WARMUP + 5)))
TOTAL_HOURS=$(echo "scale=1; $TOTAL_SECONDS / 3600" | bc)
echo "Estimated runtime: ~${TOTAL_HOURS} hours ($TOTAL_RUNS total runs)"
echo "Results directory: $RESULTS_DIR"
echo ""
echo "Press Enter to start, Ctrl+C to abort..."
#read -r

# Setup
capture_system_info
setup_namespaces

# Record baseline latency (no netem) for the paper
echo "Recording baseline veth latency..."
ip netns exec "$NS_CLIENT" ping -c 100 "$SERVER_IP" \
    > "$RESULTS_DIR/baseline_veth_latency.txt"

# ==============================================================================
# 1. Baseline Test (No Emulation)
# ==============================================================================
run_test_case "01_baseline" \
    "No Network Emulation (veth direct)" \
    ""

# ==============================================================================
# 2. Latency Tests (Symmetric: delay applied both directions)
# Note: With namespaces + symmetric netem, RTT = 2 × delay ± jitter
# ==============================================================================

run_test_case "02_latency_10ms" \
    "Latency: 10ms ±1ms each way (RTT ~20ms)" \
    "delay 10ms 1ms distribution normal"

run_test_case "03_latency_30ms" \
    "Latency: 30ms ±5ms each way (RTT ~60ms)" \
    "delay 30ms 5ms distribution normal"

run_test_case "04_latency_50ms" \
    "Latency: 50ms ±10ms each way (RTT ~100ms)" \
    "delay 50ms 10ms distribution normal"

# ==============================================================================
# 3. Packet Loss Tests (Symmetric)
# ==============================================================================

run_test_case "05_loss_1p" \
    "Packet Loss: 1% (symmetric)" \
    "loss 1%"

run_test_case "06_loss_2p" \
    "Packet Loss: 2% (symmetric)" \
    "loss 2%"

run_test_case "07_loss_5p" \
    "Packet Loss: 5% (symmetric)" \
    "loss 5%"

# ==============================================================================
# 4. Realistic Composite Scenarios
# ==============================================================================

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
# Cleanup & Summary
# ==============================================================================
reset_netem

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  All local tests completed.                                     ║"
echo "║  Results saved in: $RESULTS_DIR                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Count results
TOTAL_FILES=$(find "$RESULTS_DIR" -name "*.csv" | wc -l)
echo "Total result files: $TOTAL_FILES"
echo ""

# Quick sanity check
EXPECTED=$((TOTAL_SCENARIOS * ${#PROTOCOLS[@]} * RUNS))
if [ "$TOTAL_FILES" -ne "$EXPECTED" ]; then
    echo "WARNING: Expected $EXPECTED CSV files but found $TOTAL_FILES"
    echo "Some runs may have failed. Check logs."
else
    echo "All $EXPECTED runs completed successfully."
fi

echo ""
echo "Next steps:"
echo "  1. Back up results: cp -r $RESULTS_DIR /path/to/backup/"
echo "  2. Aggregate: ./target/release/stats $RESULTS_DIR --all"
echo "  3. Plot: ./target/release/plot $RESULTS_DIR"
echo "  4. (Optional) Run internet validation on remote VPS"
