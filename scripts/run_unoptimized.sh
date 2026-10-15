#!/bin/bash
set -euo pipefail

# ==============================================================================
# Unoptimized QUIC Baseline — no CPU pinning, no SCHED_FIFO
# ==============================================================================
# The counterpart to run_optimized.sh. Runs the SAME binary with NONE of the
# process-isolation optimizations: no taskset core pinning, no chrt/SCHED_FIFO.
# You are expected to also revert the machine-level optimizations for a true
# baseline (SMT on, frequency boost on, etc. — via BIOS / ubenchmon teardown);
# this script records whatever state it finds into system_info.txt.
#
# Two transports (paper Table I compares against loopback):
#   --transport lo     loopback (127.0.0.1), no network namespaces  [paper default]
#   --transport veth   veth namespaces (same path as optimized), isolates the
#                      effect of CPU/scheduler optimization from the transport
#
# Both apply netem "loss 2%" so results are comparable to the optimized run.
#
#   Build first: RUSTFLAGS="-C target-cpu=native" cargo build --release
#
# USAGE: sudo ./scripts/run_unoptimized.sh --transport {lo|veth} [--runs N] [--duration N] [--warmup N]
# ==============================================================================

RUNS=30
DURATION=60
WARMUP=10
PORT=8000
TRANSPORT="lo"

# --- Parse CLI arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --transport) TRANSPORT="$2"; shift 2 ;;
        --veth)      TRANSPORT="veth"; shift ;;
        --lo|--loopback) TRANSPORT="lo"; shift ;;
        --runs)      RUNS="$2"; shift 2 ;;
        --duration)  DURATION="$2"; shift 2 ;;
        --warmup)    WARMUP="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ "$TRANSPORT" != "lo" && "$TRANSPORT" != "veth" ]]; then
    echo "ERROR: --transport must be 'lo' or 'veth' (got '$TRANSPORT')."
    exit 1
fi

SERVER_BIN="./target/release/server"
CLIENT_BIN="./target/release/client"

NS_SERVER="ns_server"
NS_CLIENT="ns_client"
VETH_SRV="veth-srv"
VETH_CLI="veth-cli"
NETEM_ARGS="loss 2%"

if [ "$TRANSPORT" = "veth" ]; then
    SERVER_IP="10.0.0.1"
    CLIENT_IP="10.0.0.2"
else
    SERVER_IP="127.0.0.1"
fi

SRV=""

# --- Cleanup: kill strays + remove any netem we added to lo ---
cleanup() {
    [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true
    pkill -f "$SERVER_BIN quic" 2>/dev/null || true
    pkill -f "$CLIENT_BIN quic" 2>/dev/null || true
    if [ "$TRANSPORT" = "lo" ]; then
        tc qdisc del dev lo root 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# --- Preflight ---
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: must run as root (needed for tc" \
         "$([ "$TRANSPORT" = veth ] && echo '+ ip netns'))."
    exit 1
fi

if [ ! -f "$SERVER_BIN" ] || [ ! -f "$CLIENT_BIN" ]; then
    echo "ERROR: binaries not found. Build first:"
    echo "  RUSTFLAGS=\"-C target-cpu=native\" cargo build --release"
    exit 1
fi

RESULTS_DIR="./benchmark_results/validation_unoptimized_${TRANSPORT}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# --- Transport setup ---
setup_veth() {
    echo "Setting up veth namespaces (clean rebuild)..."
    pkill -f "$SERVER_BIN quic" 2>/dev/null || true
    pkill -f "$CLIENT_BIN quic" 2>/dev/null || true
    ip netns del "$NS_SERVER" 2>/dev/null || true
    ip netns del "$NS_CLIENT" 2>/dev/null || true
    ip link del "$VETH_SRV" 2>/dev/null || true

    ip netns add "$NS_SERVER"
    ip netns add "$NS_CLIENT"
    ip link add "$VETH_SRV" type veth peer name "$VETH_CLI"
    ip link set "$VETH_SRV" netns "$NS_SERVER"
    ip link set "$VETH_CLI" netns "$NS_CLIENT"

    ip netns exec "$NS_SERVER" ip addr add "${SERVER_IP}/24" dev "$VETH_SRV"
    ip netns exec "$NS_SERVER" ip link set "$VETH_SRV" up
    ip netns exec "$NS_SERVER" ip link set lo up
    ip netns exec "$NS_SERVER" ip link set "$VETH_SRV" mtu 1500

    ip netns exec "$NS_CLIENT" ip addr add "${CLIENT_IP}/24" dev "$VETH_CLI"
    ip netns exec "$NS_CLIENT" ip link set "$VETH_CLI" up
    ip netns exec "$NS_CLIENT" ip link set lo up
    ip netns exec "$NS_CLIENT" ip link set "$VETH_CLI" mtu 1500

    ip netns exec "$NS_SERVER" ethtool -K "$VETH_SRV" tx off rx off tso off gso off gro off 2>/dev/null || true
    ip netns exec "$NS_CLIENT" ethtool -K "$VETH_CLI" tx off rx off tso off gso off gro off 2>/dev/null || true

    # netem on both legs
    ip netns exec "$NS_CLIENT" tc qdisc del dev "$VETH_CLI" root 2>/dev/null || true
    ip netns exec "$NS_SERVER" tc qdisc del dev "$VETH_SRV" root 2>/dev/null || true
    ip netns exec "$NS_CLIENT" tc qdisc add dev "$VETH_CLI" root netem $NETEM_ARGS
    ip netns exec "$NS_SERVER" tc qdisc add dev "$VETH_SRV" root netem $NETEM_ARGS
    echo "veth ready: $SERVER_IP <-> $CLIENT_IP  (netem: $NETEM_ARGS)"
}

setup_lo() {
    echo "Setting up loopback netem..."
    tc qdisc del dev lo root 2>/dev/null || true
    tc qdisc add dev lo root netem $NETEM_ARGS
    echo "loopback ready: $SERVER_IP  (netem: $NETEM_ARGS on dev lo)"
}

if [ "$TRANSPORT" = "veth" ]; then
    setup_veth
else
    setup_lo
fi
sleep 2   # let netem settle

# --- System info (records the un-optimized state for the record) ---
{
    echo "=== Unoptimized Validation System Info ==="
    echo "Timestamp:    $(date -Iseconds)"
    echo "Transport:    $TRANSPORT"
    echo "CPU:          $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Cores:        $(nproc) (isolated: $(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo none))"
    echo "SMT active:   $(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo '?')  (0=off, 1=on)"
    echo "Freq boost:   $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')  (1=on)"
    echo "Governor:     $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
    echo "Kernel:       $(uname -a)"
    echo "cmdline:      $(cat /proc/cmdline)"
    echo "Scheduling:   none (no taskset, no chrt) — SCHED_OTHER on housekeeping cores"
    echo "Runs:         $RUNS | measured ${DURATION}s + ${WARMUP}s warmup"
    echo ""
    echo "--- netem applied: $NETEM_ARGS ---"
    if [ "$TRANSPORT" = "veth" ]; then
        echo "ns_client / $VETH_CLI:"; ip netns exec "$NS_CLIENT" tc qdisc show dev "$VETH_CLI" 2>/dev/null || echo "  (none)"
        echo "ns_server / $VETH_SRV:"; ip netns exec "$NS_SERVER" tc qdisc show dev "$VETH_SRV" 2>/dev/null || echo "  (none)"
    else
        echo "dev lo:"; tc qdisc show dev lo 2>/dev/null || echo "  (none)"
    fi
} | tee "$RESULTS_DIR/system_info.txt"
echo ""

# --- Connectivity sanity-check ---
if [ "$TRANSPORT" = "veth" ]; then
    ip netns exec "$NS_CLIENT" ping -c 5 -q "$SERVER_IP" > "$RESULTS_DIR/ping_validation.txt" 2>&1
else
    ping -c 5 -q "$SERVER_IP" > "$RESULTS_DIR/ping_validation.txt" 2>&1
fi
echo "Ping validation saved → $RESULTS_DIR/ping_validation.txt"
echo ""

# --- Launch helpers (NO taskset, NO chrt — that is the whole point) ---
start_server() {
    if [ "$TRANSPORT" = "veth" ]; then
        ip netns exec "$NS_SERVER" "$SERVER_BIN" quic --port "$PORT" > /dev/null 2>&1 &
    else
        "$SERVER_BIN" quic --port "$PORT" > /dev/null 2>&1 &
    fi
    SRV=$!
}

run_client() {
    local CSV="$1"
    if [ "$TRANSPORT" = "veth" ]; then
        ip netns exec "$NS_CLIENT" "$CLIENT_BIN" quic \
            --ip "$SERVER_IP" --port "$PORT" \
            --duration "$((DURATION + WARMUP))" --warmup "$WARMUP" \
            --results "$CSV" > /dev/null
    else
        "$CLIENT_BIN" quic \
            --ip "$SERVER_IP" --port "$PORT" \
            --duration "$((DURATION + WARMUP))" --warmup "$WARMUP" \
            --results "$CSV" > /dev/null
    fi
}

# --- Main loop ---
for RUN in $(seq 1 "$RUNS"); do
    CSV="${RESULTS_DIR}/quic_run$(printf '%02d' "$RUN").csv"
    echo "[$(date +%H:%M:%S)] Run ${RUN}/${RUNS} → $(basename "$CSV")"

    start_server
    sleep 1
    run_client "$CSV"

    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
    SRV=""

    PORT=$((PORT + 1))
    sleep 1
done

# --- Teardown netem ---
if [ "$TRANSPORT" = "veth" ]; then
    ip netns exec "$NS_CLIENT" tc qdisc del dev "$VETH_CLI" root 2>/dev/null || true
    ip netns exec "$NS_SERVER" tc qdisc del dev "$VETH_SRV" root 2>/dev/null || true
else
    tc qdisc del dev lo root 2>/dev/null || true
fi

echo ""
echo "Done. Results: ${RESULTS_DIR}/"
TOTAL=$(find "$RESULTS_DIR" -name "*.csv" | wc -l)
echo "CSV files written: ${TOTAL}/${RUNS}"
