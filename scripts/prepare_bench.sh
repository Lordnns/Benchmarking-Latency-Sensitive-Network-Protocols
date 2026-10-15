#!/bin/bash
set -euo pipefail

echo "=== Benchmark Environment Preparation ==="
echo "Hardware: AMD Ryzen 7 3800X / 64GB DDR4 / Debian 13 Trixie"
echo "Date: $(date -Iseconds)"
echo ""

# 1. CPU frequency: lock to performance
echo "[1/8] Setting CPU governor to performance..."
echo "No need since all BIOS parameters are disabled otherwise uncomment those lines"
#cpupower frequency-set -g performance
#cpupower frequency-info | grep "current CPU frequency"

# 2. Disable swap
echo "[2/8] Disabling swap..."
swapoff -a

# 3. Stop unnecessary services
echo "[3/8] Stopping background services..."
SERVICES=(
    irqbalance
    cron
    unattended-upgrades
    apt-daily.timer
    apt-daily-upgrade.timer
    man-db.timer
    fstrim.timer
    systemd-timesyncd
    NetworkManager-wait-online
    # NVIDIA-specific — prevent GPU driver from interrupting CPU
    nvidia-persistenced
)
for svc in "${SERVICES[@]}"; do
    systemctl stop "$svc" 2>/dev/null && echo "  Stopped $svc" || true
done

# 4. Move ALL IRQs to core 0
echo "[4/8] Pinning all IRQs to core 0..."
for irq in /proc/irq/*/smp_affinity_list; do
    echo 0 > "$irq" 2>/dev/null || true
done

# 5. Drop filesystem caches
echo "[5/8] Dropping caches..."
sync
echo 3 > /proc/sys/vm/drop_caches

# 6. Network buffer tuning
echo "[6/8] Tuning kernel network buffers..."
sysctl -w net.core.rmem_max=26214400
sysctl -w net.core.wmem_max=26214400
sysctl -w net.core.rmem_default=1048576
sysctl -w net.core.wmem_default=1048576
sysctl -w net.core.netdev_max_backlog=5000

# 7. Disable ASLR (reduces measurement noise from address randomization)
echo "[7/8] Disabling ASLR..."
sysctl -w kernel.randomize_va_space=0

# 8. Set kernel timer to high resolution
echo "[8/8] Checking timer resolution..."
cat /proc/timer_list | head -5

echo ""
echo "=== Environment ready ==="
echo "Isolated cores: $(cat /sys/devices/system/cpu/isolated)"
