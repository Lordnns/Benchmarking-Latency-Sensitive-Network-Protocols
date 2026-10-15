#!/bin/bash
set -euo pipefail

# ==============================================================================
# Optimized QUIC Validation — paper protocol, self-managed namespaces
# ==============================================================================
# Self-contained runner modelled on run_full_suite.sh. It owns the network
# namespaces and netem so every invocation starts from clean state — this is
# what prevents a killed/orphaned run from leaving a stale SCHED_FIFO server on
# the isolated cores (which starves the next run's handshake). It:
#   - tears down + recreates ns_server/ns_client + veth from scratch
#   - applies netem "loss 2%" symmetrically (paper Table I scenario)
#   - launches server/client with taskset core pinning + chrt -f 50 (SCHED_FIFO)
#   - restarts the ubenchmon monitor anchors so --monitored still works
#
# Matches run_full_suite.sh / paper Table I optimized config:
#   veth namespaces + taskset core pinning + SCHED_FIFO priority 50 + 2% loss.
#   (SCHED_FIFO is what keeps the RTT std-dev / jitter in the single-digit-µs
#    range — without it the threads are preempted and jitter balloons to ms.)
#
# The host must still be configured by ubenchmon for isolation/governor/etc.
# (isolcpus=2,3,4,5 nohz_full=2,3,4,5 rcu_nocbs=2,3,4,5, performance governor,
#  swap off, IRQ affinity) — this script only manages netns + netem.
#
#   Build first: RUSTFLAGS="-C target-cpu=native" cargo build --release
#
# USAGE: sudo ./scripts/run_optimized.sh [--monitored] [--runs N] [--duration N] [--warmup N]
# ==============================================================================

RUNS=30
DURATION=60          # measured seconds (warmup is added on top)
WARMUP=10            # warmup seconds, discarded by the client
PORT=8000
MONITORED=false

# --- Parse CLI arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --monitored) MONITORED=true; shift ;;
        --runs)      RUNS="$2"; shift 2 ;;
        --duration)  DURATION="$2"; shift 2 ;;
        --warmup)    WARMUP="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

SERVER_BIN="./target/release/server"
CLIENT_BIN="./target/release/client"

# Core pinning — must match ubenchmon's isolcpus (cores 2-5).
# Two cores per process: game loop + Tokio async runtime. Using two cores is
# what prevents SCHED_FIFO from starving the runtime/softirq thread, so RT
# scheduling is safe here (same layout as run_full_suite.sh).
#   Cores 2,4 → server (game loop + Tokio runtime)
#   Cores 3,5 → client (game loop + Tokio runtime)
SERVER_CORES="2,4"
CLIENT_CORES="3,5"
RT_PRIORITY=50

NS_SERVER="ns_server"
NS_CLIENT="ns_client"
VETH_SRV="veth-srv"
VETH_CLI="veth-cli"
SERVER_IP="10.0.0.1"
CLIENT_IP="10.0.0.2"
NETEM_ARGS="loss 2%"        # paper Table I scenario (symmetric, both legs)

SRV=""

# --- Cleanup: never leave an orphaned SCHED_FIFO server behind ---
cleanup() {
    [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true
    # Belt-and-suspenders: kill any stray benchmark procs from this or a prior run
    pkill -f "$SERVER_BIN quic" 2>/dev/null || true
    pkill -f "$CLIENT_BIN quic" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- Preflight ---
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: must run as root (needed for ip netns + tc + chrt)."
    exit 1
fi

if [ ! -f "$SERVER_BIN" ] || [ ! -f "$CLIENT_BIN" ]; then
    echo "ERROR: binaries not found. Build first:"
    echo "  RUSTFLAGS=\"-C target-cpu=native\" cargo build --release"
    exit 1
fi

# Verify CPU isolation is actually active (the #1 cause of jitter regressions).
ISOLATED=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "")
if [[ "$ISOLATED" != *"2"* ]] || [[ "$ISOLATED" != *"5"* ]]; then
    echo "WARNING: cores 2-5 are not all isolated (isolated='${ISOLATED:-none}')."
    echo "         Expected isolcpus=2,3,4,5 — did the host reboot after ubenchmon apply?"
    echo "         Jitter will be dominated by scheduler preemption. Continue anyway? [y/N]"
    read -r REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
fi

# Warn if running under virtualization (invalidates sub-ms results per the paper).
# Note: systemd-detect-virt prints "none" on bare metal but exits non-zero, so
# swallow the exit status (|| true) rather than appending a fallback string.
VIRT=$(systemd-detect-virt 2>/dev/null || true)
VIRT=${VIRT:-unknown}
if [ "$VIRT" != "none" ]; then
    echo "WARNING: virtualization detected (systemd-detect-virt=${VIRT})."
    echo "         GRUB isolcpus/nohz_full may be ignored and the vCPU can be"
    echo "         descheduled by the host — latency results will be unreliable."
    echo "         Continue anyway? [y/N]"
    read -r REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
fi

if [ "$MONITORED" = true ]; then
    RESULTS_DIR="./benchmark_results/validation_optimized_monitored_$(date +%Y%m%d_%H%M%S)"
else
    RESULTS_DIR="./benchmark_results/validation_optimized_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$RESULTS_DIR"

# --- (Re)create namespaces + veth from clean state (like run_full_suite.sh) ---
setup_namespaces() {
    echo "Setting up network namespaces (clean rebuild)..."

    # Kill any lingering procs (orphaned servers, old monitor anchors)
    pkill -f "$SERVER_BIN quic" 2>/dev/null || true
    pkill -f "$CLIENT_BIN quic" 2>/dev/null || true
    pkill -f "ip netns exec $NS_SERVER sleep" 2>/dev/null || true
    pkill -f "ip netns exec $NS_CLIENT sleep" 2>/dev/null || true

    # Idempotent teardown
    ip netns del "$NS_SERVER" 2>/dev/null || true
    ip netns del "$NS_CLIENT" 2>/dev/null || true
    ip link del "$VETH_SRV" 2>/dev/null || true

    # Create namespaces + veth pair
    ip netns add "$NS_SERVER"
    ip netns add "$NS_CLIENT"
    ip link add "$VETH_SRV" type veth peer name "$VETH_CLI"
    ip link set "$VETH_SRV" netns "$NS_SERVER"
    ip link set "$VETH_CLI" netns "$NS_CLIENT"

    # Server side
    ip netns exec "$NS_SERVER" ip addr add "${SERVER_IP}/24" dev "$VETH_SRV"
    ip netns exec "$NS_SERVER" ip link set "$VETH_SRV" up
    ip netns exec "$NS_SERVER" ip link set lo up
    ip netns exec "$NS_SERVER" ip link set "$VETH_SRV" mtu 1500

    # Client side
    ip netns exec "$NS_CLIENT" ip addr add "${CLIENT_IP}/24" dev "$VETH_CLI"
    ip netns exec "$NS_CLIENT" ip link set "$VETH_CLI" up
    ip netns exec "$NS_CLIENT" ip link set lo up
    ip netns exec "$NS_CLIENT" ip link set "$VETH_CLI" mtu 1500

    # Disable hardware offloading for accurate tc/netem behaviour
    ip netns exec "$NS_SERVER" ethtool -K "$VETH_SRV" tx off rx off tso off gso off gro off 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ethtool -K "$VETH_CLI" tx off rx off tso off gso off gro off 2>/dev/null || true

    # Restart the ubenchmon monitor anchors so --monitored can read veth stats
    # via /proc/<pid>/root/sys/... (mirrors ubenchmon setup.c).
    ip netns exec "$NS_SERVER" sleep infinity </dev/null >/dev/null 2>&1 &
    ip netns exec "$NS_CLIENT" sleep infinity </dev/null >/dev/null 2>&1 &

    echo "Namespaces ready: $SERVER_IP <-> $CLIENT_IP"
}

# --- Apply netem symmetrically on both legs (like run_full_suite.sh) ---
apply_netem() {
    ip netns exec "$NS_CLIENT" tc qdisc del dev "$VETH_CLI" root 2>/dev/null || true
    ip netns exec "$NS_SERVER" tc qdisc del dev "$VETH_SRV" root 2>/dev/null || true
    ip netns exec "$NS_CLIENT" tc qdisc add dev "$VETH_CLI" root netem $NETEM_ARGS
    ip netns exec "$NS_SERVER" tc qdisc add dev "$VETH_SRV" root netem $NETEM_ARGS
}

setup_namespaces
apply_netem
sleep 2   # let netem settle

# --- Capture system info + the netem this script applied ---
{
    echo "=== Optimized Validation System Info ==="
    echo "Timestamp:    $(date -Iseconds)"
    echo "CPU:          $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Cores:        $(nproc) (isolated: ${ISOLATED:-none})"
    echo "Virt:         $VIRT"
    echo "Kernel:       $(uname -a)"
    echo "cmdline:      $(cat /proc/cmdline)"
    echo "Governor:     $(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_governor 2>/dev/null || echo '?')"
    echo "Server cores: $SERVER_CORES | Client cores: $CLIENT_CORES"
    echo "Scheduling:   taskset -c <cores> + chrt -f $RT_PRIORITY (SCHED_FIFO)"
    echo "Runs:         $RUNS | measured ${DURATION}s + ${WARMUP}s warmup"
    echo ""
    echo "--- netem applied (symmetric, both legs): $NETEM_ARGS ---"
    echo "ns_client / $VETH_CLI:"
    ip netns exec "$NS_CLIENT" tc qdisc show dev "$VETH_CLI" 2>/dev/null || echo "  (none)"
    echo "ns_server / $VETH_SRV:"
    ip netns exec "$NS_SERVER" tc qdisc show dev "$VETH_SRV" 2>/dev/null || echo "  (none)"
} | tee "$RESULTS_DIR/system_info.txt"
echo ""

# Connectivity sanity-check
ip netns exec "$NS_CLIENT" ping -c 5 -q "$SERVER_IP" \
    > "$RESULTS_DIR/ping_validation.txt" 2>&1
echo "Ping validation saved → $RESULTS_DIR/ping_validation.txt"
echo ""

# --- Main loop ---
for RUN in $(seq 1 "$RUNS"); do
    CSV="${RESULTS_DIR}/quic_run$(printf '%02d' "$RUN").csv"
    echo "[$(date +%H:%M:%S)] Run ${RUN}/${RUNS} → $(basename "$CSV")"

    # Start server — pinned to isolated cores + SCHED_FIFO (paper protocol)
    ip netns exec "$NS_SERVER" \
        taskset -c "$SERVER_CORES" \
        chrt -f "$RT_PRIORITY" \
        "$SERVER_BIN" quic --port "$PORT" \
        > /dev/null 2>&1 &
    SRV=$!
    sleep 1

    # Run client — pinned to isolated cores + SCHED_FIFO (paper protocol)
    # Total runtime = DURATION + WARMUP; first WARMUP seconds are discarded.
    ip netns exec "$NS_CLIENT" \
        taskset -c "$CLIENT_CORES" \
        chrt -f "$RT_PRIORITY" \
        "$CLIENT_BIN" quic \
            --ip "$SERVER_IP" \
            --port "$PORT" \
            --duration "$((DURATION + WARMUP))" \
            --warmup "$WARMUP" \
            --results "$CSV" \
        > /dev/null

    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
    SRV=""

    PORT=$((PORT + 1))
    sleep 1
done

# --- Teardown netem (leave namespaces up for a following --monitored read) ---
ip netns exec "$NS_CLIENT" tc qdisc del dev "$VETH_CLI" root 2>/dev/null || true
ip netns exec "$NS_SERVER" tc qdisc del dev "$VETH_SRV" root 2>/dev/null || true

echo ""
echo "Done. Results: ${RESULTS_DIR}/"
TOTAL=$(find "$RESULTS_DIR" -name "*.csv" | wc -l)
echo "CSV files written: ${TOTAL}/${RUNS}"
