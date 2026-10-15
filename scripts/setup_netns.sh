#!/bin/bash
set -euo pipefail

echo "=== Setting up network namespaces ==="

# Clean up any previous run
ip netns del ns_server 2>/dev/null || true
ip netns del ns_client 2>/dev/null || true
ip link del veth-srv 2>/dev/null || true

# Create namespaces
ip netns add ns_server
ip netns add ns_client

# Create veth pair
ip link add veth-srv type veth peer name veth-cli

# Assign to namespaces
ip link set veth-srv netns ns_server
ip link set veth-cli netns ns_client

# Configure server side
ip netns exec ns_server ip addr add 10.0.0.1/24 dev veth-srv
ip netns exec ns_server ip link set veth-srv up
ip netns exec ns_server ip link set lo up
ip netns exec ns_server ip link set veth-srv mtu 1500

# Configure client side
ip netns exec ns_client ip addr add 10.0.0.2/24 dev veth-cli
ip netns exec ns_client ip link set veth-cli up
ip netns exec ns_client ip link set lo up
ip netns exec ns_client ip link set veth-cli mtu 1500

# Disable hardware offloading — critical for tc accuracy
ip netns exec ns_server ethtool -K veth-srv tx off rx off tso off gso off gro off 2>/dev/null || true
ip netns exec ns_client ethtool -K veth-cli tx off rx off tso off gso off gro off 2>/dev/null || true

echo "=== Namespaces ready ==="
echo "Server: 10.0.0.1 (ns_server, veth-srv)"
echo "Client: 10.0.0.2 (ns_client, veth-cli)"

# Quick connectivity test
ip netns exec ns_client ping -c 3 -q 10.0.0.1
