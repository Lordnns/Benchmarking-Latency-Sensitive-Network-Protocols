#!/bin/bash
# Usage: ./set_netem.sh <delay_ms> <jitter_ms> <loss_pct> <rate_mbit>
# Example: ./set_netem.sh 25 5 1 10

DELAY=${1:-25}
JITTER=${2:-5}
LOSS=${3:-0}
RATE=${4:-100}

echo "=== Configuring netem (symmetric) ==="
echo "Delay: ${DELAY}ms ±${JITTER}ms | Loss: ${LOSS}% | Rate: ${RATE}Mbit"

# Clear existing qdiscs
ip netns exec ns_client tc qdisc del dev veth-cli root 2>/dev/null || true
ip netns exec ns_server tc qdisc del dev veth-srv root 2>/dev/null || true

# Client -> Server
ip netns exec ns_client tc qdisc add dev veth-cli root netem \
    delay ${DELAY}ms ${JITTER}ms distribution normal \
    loss ${LOSS}% \
    rate ${RATE}mbit

# Server -> Client
ip netns exec ns_server tc qdisc add dev veth-srv root netem \
    delay ${DELAY}ms ${JITTER}ms distribution normal \
    loss ${LOSS}% \
    rate ${RATE}mbit

echo "=== Netem configured ==="
