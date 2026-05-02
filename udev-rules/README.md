# Azure Network Adapter UDEV Rules

UDEV rules for optimizing Azure network interface performance on VM startup. These rules automatically configure ring buffers, queue disciplines, and transmit queue lengths for different adapter types.

## Overview

These UDEV rules apply network interface tuning automatically when devices are discovered, making the optimizations persistent across reboots and interface resets.

> **Note:** For a more comprehensive and automated solution, consider using the **[azure-nic-setup](../azure-nic-setup/)** utility instead. It provides:
> - Combined approach using udev rules, systemd services, and helper scripts
> - Automatic ring buffer management with persistent configuration
> - Better integration with systemd and automatic reapplication
> - This is the recommended approach for production deployments
> 
> Use these standalone UDEV rules if you only need ring buffer tuning without the additional systemd integration.

## Files

- `99-azure-network-tuned.rules` - UDEV rules for network interface optimization

## Network Adapter Types

Azure VMs support three types of network interfaces, each with different optimization strategies:

### 1. Accelerated Networking (MANA/Mellanox)

**When present:**
- VM size supports accelerated networking (enabled in Azure portal)
- Driver: `hv_pci` for MANA, `mlx*` for Mellanox
- Used in: High-performance workloads, databases, real-time processing

**Optimizations applied:**
- Ring buffer size: 1024 RX, 1024 TX
- Queue discipline: NOQUEUE (direct processing)
- Transmit queue: 2048 packets

### 2. Synthetic Networking (Standard)

**When present:**
- Basic Azure VM networking
- Driver: `hv_netvsc*`
- Used in: General-purpose VMs, default configuration

**Optimizations applied:**
- Ring buffer size: 1024 RX, 1024 TX
- UDP hash: Disabled (prevents packet reordering)
- Transmit queue: 2048 packets

### 3. Loopback Interface

**When present:**
- Always present on all VMs
- Kernel: `lo`
- Used in: Local inter-process communication

**Optimizations applied:**
- Transmit queue: 5000 packets (higher for local traffic)

## Installation

### Prerequisites

- Linux kernel 4.9+ with udev support
- `ethtool` and `tc` utilities installed
- Root access

```bash
# Verify prerequisites
which ethtool
which tc
```

### Installation Steps

```bash
# 1. Copy the rules file
sudo cp 99-azure-network-tuned.rules /etc/udev/rules.d/

# 2. Set correct permissions
sudo chmod 644 /etc/udev/rules.d/99-azure-network-tuned.rules

# 3. Verify installation
ls -la /etc/udev/rules.d/99-azure-network-tuned.rules

# 4. Option A: Reboot to apply
sudo reboot

# 4. Option B: Apply immediately without reboot
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Verify Application

After installation, verify the rules were applied:

```bash
# Check ring buffer settings
ethtool -g eth0
ethtool -g eth1

# Check queue discipline
tc qdisc show dev eth0
tc qdisc show dev eth1

# Check transmit queue length
grep tx_queue_len /sys/class/net/eth0/tx_queue_len
grep tx_queue_len /sys/class/net/eth1/tx_queue_len
```

## Configuration Details

### Ring Buffers

Ring buffers store transmitted and received packets before kernel processing.

| Tunable | Value | Impact |
|---------|-------|--------|
| RX ring | 1024 | Receive buffer capacity |
| TX ring | 1024 | Transmit buffer capacity |

**Performance implications:**
- **Larger buffers** (e.g., 2048, 4096):
  - Benefits: More bursty traffic absorption, higher throughput
  - Costs: Higher memory usage, higher latency, potential packet loss if configured too large
  
- **Smaller buffers** (e.g., 512):
  - Benefits: Lower latency, less memory
  - Costs: Packet drops under bursty traffic

**Recommendations:**
- Start with 1024 (current setting)
- For high-throughput workloads: Try 2048 or 4096
- For low-latency: Keep at 1024 or reduce to 512
- Test thoroughly before changing in production

### UDP Hash Configuration

The UDP hash setting controls how UDP traffic is distributed across receive queues.

| Setting | Effect |
|---------|--------|
| `rx-flow-hash udp4 sd` | Disabled - uses source/destination only |
| Default | Enabled - includes port information |

**Why disabled for Synthetic (hv_netvsc)?**
- Prevents UDP packet reordering
- Improves consistency for streaming/real-time protocols
- Particularly important for DNS, VoIP, streaming applications

**Note:** Only applied to synthetic interfaces (hv_netvsc), not to accelerated networking.

### Queue Discipline (NOQUEUE)

The queue discipline controls packet scheduling and queuing.

| Qdisc | Behavior | Latency | Throughput |
|-------|----------|---------|-----------|
| `noqueue` | Direct processing | Very low | High (for burst) |
| `pfifo_fast` | Priority queuing | Low | Balanced |
| Default | Kernel default | Variable | Balanced |

**NOQUEUE advantages:**
- Minimal latency
- No packet reordering
- Ideal for low-latency requirements

**When to keep NOQUEUE:**
- Default for accelerated networking (MANA/Mellanox)
- Recommended for: databases, trading, HPC

**When to consider alternatives:**
- If experiencing packet loss at saturation
- If fairness between flows matters
- If you need traffic shaping

### Transmit Queue Length

Maximum number of packets allowed in the transmit queue before backpressure.

| Interface | Value | Rationale |
|-----------|-------|-----------|
| Accelerated/Synthetic | 2048 | Balance throughput vs. latency |
| Loopback | 5000 | Local traffic can be bursty |

**Tuning guidance:**
- Higher values: Better for sustained throughput
- Lower values: Better latency
- Loopback higher: Local traffic pattern differences

## Performance Tuning

### Monitor Current Settings

```bash
# View all settings for eth0
echo "=== Ring Buffers ==="
ethtool -g eth0

echo "=== Transmit Queue Length ==="
cat /sys/class/net/eth0/tx_queue_len

echo "=== Queue Discipline ==="
tc qdisc show dev eth0

echo "=== UDP Hash (if applicable) ==="
ethtool -n eth0 rx-flow-hash udp4
```

### Monitor Network Performance

```bash
# Real-time network statistics
watch -n 1 'ethtool -S eth0 | grep -E "rx_|tx_"'

# Per-second interface statistics
watch -n 1 'ifstat 1 1'

# Queue drops and errors
watch -n 1 'netstat -i'
```

### When to Adjust

**If experiencing:**
- **Packet loss/dropped**: Increase RX/TX ring buffers or TX queue length
- **High latency**: Check for queue saturation, may need NOQUEUE (already applied)
- **Uneven performance**: Verify UDP hash settings are correct
- **Memory pressure**: Reduce ring buffer sizes or TX queue length

**Tuning process:**
1. Establish baseline metrics (throughput, latency, packet loss)
2. Change one parameter at a time
3. Run workload for 5-10 minutes
4. Compare metrics to baseline
5. Make incremental adjustments
6. Only commit changes if improvement is consistent

### Temporary Testing

To test changes without permanent modification:

```bash
# Test new ring buffer size
sudo ethtool -G eth0 rx 2048 tx 2048
# Run test...
# Revert (applies rules again)
sudo udevadm trigger

# Test queue length
sudo ip link set eth0 txqueuelen 4096
# Run test...
# Revert
sudo udevadm trigger

# Permanent: edit the rules file
sudo nano /etc/udev/rules.d/99-azure-network-tuned.rules
# Change values, save
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## Troubleshooting

### Rules Not Applying

**Problem:** Settings don't apply after installation

**Solutions:**
```bash
# Check file location and permissions
ls -la /etc/udev/rules.d/99-azure-network-tuned.rules
# Should show: -rw-r--r-- root root

# Fix permissions if needed
sudo chmod 644 /etc/udev/rules.d/99-azure-network-tuned.rules

# Reload and trigger
sudo udevadm control --reload-rules
sudo udevadm trigger

# Check for syntax errors
sudo udevadm test /sys/class/net/eth0 2>&1 | head -20
```

### Tools Not Found

**Problem:** `ethtool` or `tc` not installed

**Solution:**
```bash
# Ubuntu/Debian
sudo apt-get install ethtool iproute2

# RHEL/CentOS
sudo yum install ethtool iproute

# Verify
which ethtool
which tc
```

### Path Issues (Older Distributions)

**Problem:** Rules don't work on Ubuntu 18.04 or older

**Cause:** `ethtool` and `tc` may be in `/sbin` instead of `/usr/sbin`

**Solution:**
```bash
# Find correct paths
which ethtool
which tc

# Update rules with correct paths
sudo sed -i 's|/usr/sbin/ethtool|/sbin/ethtool|g' \
  /etc/udev/rules.d/99-azure-network-tuned.rules

sudo sed -i 's|/usr/sbin/tc|/sbin/tc|g' \
  /etc/udev/rules.d/99-azure-network-tuned.rules

# Reapply
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Verify Settings Persisted

**Problem:** Settings reset after reboot

**Check:**
```bash
# After reboot, verify settings are applied
ethtool -g eth0  # Check ring buffers
cat /sys/class/net/eth0/tx_queue_len  # Check queue length

# If not applied, check boot logs
sudo journalctl -u systemd-udevd -n 50
```

### High Latency Despite NOQUEUE

**Problem:** Still experiencing high latency

**Possible causes:**
- System load or other bottleneck
- Application code issue
- Other kernel parameters not optimized

**Verify:**
```bash
# Confirm NOQUEUE is applied
tc qdisc show dev eth0  # Should show "qdisc noqueue"

# Check system load
uptime

# Check other network tunables
sysctl -a | grep -E "tcp_|udp_" | head -10
```

## Integration with Other Tuning

These UDEV rules work together with other optimization components:

| Component | Purpose | Integration |
|-----------|---------|-------------|
| sysctl tuning | Kernel parameters | Rules apply device-level; sysctl applies system-wide |
| systemd.link | Network interface config | Rules apply first; systemd.link can override |
| MANA driver monitoring | Driver health | Works independently; complements tuning |
| **azure-nic-setup** | **Comprehensive NIC setup** | **Recommended for ring buffers** - see note above |

**Recommended application order:**
1. **azure-nic-setup** (if using for ring buffers - handles everything)
2. OR UDEV rules only (if minimal setup needed)
3. systemd.link (applied after UDEV/azure-nic-setup)
4. sysctl tuning (system-wide defaults)
5. Application-specific tuning (highest priority)

## Performance Expectations

**With these UDEV rules:**
- **Accelerated Networking**: 2-5% latency reduction, 5-10% throughput improvement
- **Synthetic Networking**: 1-2% latency improvement, negligible throughput change
- **Real benefits**: Consistency across reboots, automatic application on device changes

**When benefits are highest:**
- High-frequency trading, low-latency applications
- Bulk data transfer workloads
- Consistent performance requirements
- VMs with network device resets

## References

- [UDEV Documentation](https://man7.org/linux/man-pages/man7/udev.7.html)
- [ethtool Manual](https://man7.org/linux/man-pages/man8/ethtool.8.html)
- [tc Command Documentation](https://man7.org/linux/man-pages/man8/tc.8.html)
- [Azure Accelerated Networking](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-how-it-works)
- [MANA Overview](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-overview)
- [Netvsc Driver Documentation](https://www.kernel.org/doc/html/latest/networking/device_drivers/ethernet/microsoft/netvsc.html)

## Related Configurations

- Systemd network tuning: See `../systemd/README.txt`
- Main sysctl tuning: See `../sysctl/README.md`
- MANA driver monitoring: See `../mana-driver-check/README.md`
