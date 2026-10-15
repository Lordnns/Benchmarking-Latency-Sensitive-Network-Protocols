#!/bin/bash

echo "=== Restoring system ==="

# Remove namespaces
ip netns del ns_server 2>/dev/null || true
ip netns del ns_client 2>/dev/null || true

# Restore CPU governor
# Not needed on this machine as the freq are pinned
#cpupower frequency-set -g ondemand

# Re-enable swap
swapon -a

# Re-enable ASLR
sysctl -w kernel.randomize_va_space=2

# Restart services
systemctl start irqbalance 2>/dev/null || true
systemctl start cron 2>/dev/null || true
systemctl start systemd-timesyncd 2>/dev/null || true

echo "=== System restored ==="
echo "NOTE: Remove isolcpus/nohz_full from GRUB for normal use"
