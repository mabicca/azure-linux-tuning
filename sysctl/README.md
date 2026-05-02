# Sysctl Kernel Parameter Tuning

This folder contains kernel parameter tuning configurations for Azure Linux environments, optimized for virtual machines with 8GB or more of RAM.

## Overview

These sysctl configurations optimize network performance, memory management, and TCP/UDP buffer handling for Azure VMs. Two profile levels are provided to suit different workload requirements.

## Files

- `99-sysctl-full.conf` - Comprehensive tuning with all recommended parameters enabled
- `99-sysctl-minimal.conf` - Streamlined configuration with essential parameters only
- `sysctl-cifs-fscache.conf` - CIFS/SMB file sharing optimization (in parent folder)
- `sysctl-nfs-fscache.conf` - NFS file sharing optimization (in parent folder)

## System Requirements

- Linux kernel: 4.9 or higher
- Minimum RAM: 8GB (configurations optimized for this)
- Root/sudo access

## Installation

### Option 1: Using sysctl.d (Recommended)

```bash
# Copy configuration to sysctl.d
sudo cp 99-sysctl-full.conf /etc/sysctl.d/
sudo chmod 644 /etc/sysctl.d/99-sysctl-full.conf

# Apply immediately
sudo sysctl -p /etc/sysctl.d/99-sysctl-full.conf

# Verify changes
sudo sysctl -a | grep -E "tcp_mem|tcp_rmem|tcp_wmem|rmem_default|wmem_default"
```

### Option 2: Direct sysctl.conf

```bash
# Append to existing sysctl.conf
sudo cat 99-sysctl-full.conf >> /etc/sysctl.conf

# Apply changes
sudo sysctl -p
```

## Configuration Details

### TCP/UDP Buffer Sizing

**Minimum Values (increased from 4096 to 8192 bytes):**
- `net.ipv4.tcp_mem` - TCP memory allocation thresholds (min pressure max in pages)
- `net.ipv4.udp_mem` - UDP memory allocation thresholds
- `net.ipv4.tcp_rmem` - TCP receive buffer sizes (min default max)
- `net.ipv4.tcp_wmem` - TCP transmit buffer sizes

**Default Buffer Sizes (32MB):**
- `net.core.rmem_default` - Default receive buffer (33554432 bytes)
- `net.core.wmem_default` - Default transmit buffer (33554432 bytes)

**Maximum Buffer Sizes (128MB):**
- `net.core.rmem_max` - Maximum receive buffer (134217728 bytes)
- `net.core.wmem_max` - Maximum transmit buffer (can scale to 2GB for 100G+ NICs)

**UDP Socket Buffers:**
- `net.ipv4.udp_rmem_min` - UDP receive buffer minimum (16384 bytes)
- `net.ipv4.udp_wmem_min` - UDP transmit buffer minimum (16384 bytes)

### Network Performance Tuning

**Busy Poll Configuration:**
- `net.core.busy_poll` - Busy loop timeout for poll/select (50μs)
- `net.core.busy_read` - Busy loop timeout for network reads (50μs)
- Benefits: Lower latency for latency-sensitive workloads
- Trade-off: Increased CPU usage

**TCP Connection Tuning:**
- `net.ipv4.tcp_window_scaling` - Enable window scaling for high-bandwidth connections
- `net.ipv4.tcp_moderate_rcvbuf` - Auto-tune receive buffers to match path capacity
- `net.ipv4.tcp_no_metrics_save` - Disable connection metric caching

**SYN Attack Protection:**
- `net.ipv4.tcp_syncookies` - Enable SYN cookies for DoS protection
- `net.ipv4.tcp_max_syn_backlog` - Maximum SYN backlog (65535)
- `net.ipv4.tcp_syn_retries` - SYN retry count (2)
- `net.ipv4.tcp_synack_retries` - SYN-ACK retry count (2)

**Keepalive Settings:**
- `net.ipv4.tcp_keepalive_time` - Idle time before sending keepalives (300s)
- `net.ipv4.tcp_keepalive_probes` - Number of keepalive probes (5)
- `net.ipv4.tcp_keepalive_intvl` - Interval between probes (15s)

**Connection Timeout:**
- `net.ipv4.tcp_fin_timeout` - Time to close finished connections (10s)

### IP Fragment Protection

**IP Fragment Reassembly Limits (CVE-2018-5391):**
- `net.ipv4.ipfrag_low_thresh` - Low threshold (196608 bytes)
- `net.ipv4.ipfrag_high_thresh` - High threshold (262144 bytes)
- `net.ipv6.ip6frag_low_thresh` - IPv6 low threshold
- `net.ipv6.ip6frag_high_thresh` - IPv6 high threshold

## Profile Comparison

| Category | Full | Minimal |
|----------|------|---------|
| **Buffer Sizing** | ✓ | ✓ |
| TCP/UDP memory allocation | ✓ | ✓ |
| Socket buffer defaults | ✓ | ✓ |
| Busy poll (latency opt.) | ✓ | ✓ |
| **Connection Management** | ✓ | ✓ |
| SYN attack protection | ✓ | ✓ |
| Congestion control (BBR) | ✓ | ✓ |
| TCP connection backlog | ✓ | ✓ |
| **Advanced TCP Tuning** | ✓ | - |
| TCP keepalive parameters | ✓ | - |
| TCP connection timeout | ✓ | - |
| Time-wait bucket limits | ✓ | - |
| Orphan connection handling | ✓ | - |
| TCP NOTSENT_LOWAT | ✓ | - |
| **Security & Safety** | ✓ | ✓ |
| Fragment protection (CVE-2018-5391) | ✓ | - |
| Reverse path filtering | ✓ | ✓ |
| IP spoofing prevention | ✓ | ✓ |
| **Network Optimization** | ✓ | - |
| ARP table tuning | ✓ | - |
| Early demux (packet routing) | ✓ | - |
| **Memory Management** | ✓ | ✓ |
| Dirty page threshold | ✓ | ✓ |
| Swap usage tuning | ✓ | ✓ |

### When to Use Each Profile

**Use `99-sysctl-full.conf` when:**
- Running production workloads requiring maximum performance
- Database servers (Cassandra, MySQL, PostgreSQL, etc.)
- High-throughput streaming applications
- Message queues and event processors
- Deployments requiring security hardening (CVE protection)
- You have adequate system resources to monitor and tune

**Use `99-sysctl-minimal.conf` when:**
- Conservative approach to system tuning preferred
- Resource-constrained environments
- Testing/development environments
- Simpler workloads with modest performance requirements
- You prefer incremental optimization (start minimal, add full later)
- Minimal surface area for potential compatibility issues

### Detailed Differences

#### Removed in Minimal Profile

**1. IP Fragment Protection (CVE-2018-5391)**
- Removed: `ipfrag_low_thresh`, `ipfrag_high_thresh` (IPv4 and IPv6)
- Impact: Less protection against IP fragment reassembly attacks
- Risk: Minimal in most cloud environments with managed firewalls
- Recommendation: Include if running exposed services

**2. TCP Keepalive Parameters**
- Removed: `tcp_keepalive_time`, `tcp_keepalive_probes`, `tcp_keepalive_intvl`
- Impact: Uses kernel defaults (120s idle, 9 probes, 75s interval)
- Trade-off: Longer idle connection detection, but more predictable
- Use case: Full profile recommended for database connections

**3. TCP Connection Timeout**
- Removed: `tcp_fin_timeout`
- Impact: Uses kernel default (60s instead of 10s)
- Effect: Longer time-wait state cleanup
- Trade-off: More memory used by TIME_WAIT connections, but safer

**4. Advanced TCP Tuning**
- Removed: `tcp_notsent_lowat` (HTTP/2 optimization)
- Removed: `tcp_max_tw_buckets` (time-wait bucket limits)
- Removed: `tcp_max_orphans` (orphan connection limits)
- Impact: Less control over connection state memory usage
- Benefit: Simpler configuration, fewer tuning knobs

**5. ARP Table Tuning**
- Removed: `neigh.default.gc_*` parameters
- Removed: `neigh.default.proxy_qlen`, `neigh.default.unres_qlen`
- Impact: Uses kernel defaults for ARP garbage collection
- Recommendation: Include in large networks (many neighbors)

**6. Early Demux**
- Removed: `ip_early_demux`, `tcp_early_demux`, `udp_early_demux`
- Impact: Slightly higher CPU for packet demultiplexing
- Recommendation: Include for high-PPS (packets/second) workloads

**Shared Between Both Profiles:**

**Core Network Tuning:**
- TCP/UDP buffer sizing (8192 minimum, 128MB maximum)
- Busy poll for low-latency applications
- MTU path discovery
- Auto-tuned receive buffers
- TCP window scaling

**Connection Management:**
- SYN cookie protection
- BBR congestion control
- Connection backlog optimization
- Fair queuing (fq) discipline

**Security:**
- Reverse path filtering (loose mode)
- RFC 1337 time-wait assassination prevention
- TCP sequence validation

**Performance:**
- Slow start after idle disabled (high-throughput optimization)
- Abort on overflow for resilience
- TCP Fast Open enabled
- Explicit Congestion Notification (ECN)

**Memory:**
- 600MB dirty page threshold (optimized for 8GB+ VMs)
- Reduced swappiness (10) for performance

## Verification

### Check Applied Settings

```bash
# View all current sysctl settings
sysctl -a

# View specific TCP parameters
sysctl -a | grep tcp_mem
sysctl -a | grep tcp_rmem

# View buffer sizes
sysctl net.core.rmem_default
sysctl net.core.wmem_default
```

### Runtime Status

```bash
# Check if settings are active
sudo sysctl net.ipv4.tcp_mem
sudo sysctl net.ipv4.tcp_rmem

# Monitor network performance
netstat -s  # Protocol statistics
ss -tni     # TCP socket info
```

## Reverting Changes

**Option 1: Remove Configuration File**

```bash
# Remove the configuration
sudo rm /etc/sysctl.d/99-sysctl-full.conf

# Revert to defaults (requires reboot)
sudo reboot

# Or apply default sysctl immediately
sudo sysctl -p
```

**Option 2: Manually Reset Parameters**

```bash
# Reset individual parameters
sudo sysctl net.ipv4.tcp_mem=4096\ 65536\ 262144
sudo sysctl net.ipv4.tcp_rmem=4096\ 87380\ 6291456
```

**Backup Current Settings**

```bash
# Save current settings before changes
sysctl -a > /tmp/sysctl-backup-$(date +%s).conf
```

## Workload-Specific Recommendations

**High-Throughput Scenarios:**
- Use `99-sysctl-full.conf`
- Enable busy poll for additional latency reduction
- Consider increasing `net.core.wmem_max` to 2GB

**Database Servers (e.g., Cassandra, MySQL, PostgreSQL):**
- Use `99-sysctl-full.conf`
- Uncomment Cassandra-specific keepalive settings in the configuration
- Monitor memory usage with increased buffer sizes

**File Sharing (NFS/CIFS):**
- Apply `sysctl-nfs-fscache.conf` or `sysctl-cifs-fscache.conf`
- Combine with main profile for comprehensive tuning

**Low-Latency Workloads:**
- Use `99-sysctl-full.conf`
- Enable `net.core.busy_poll` and `net.core.busy_read`
- Ensure network interface supports RX interrupt coalescing tuning

## Related Configurations

- See `../systemd/` - Network interface tuning via systemd.link
- See `../udev-rules/` - Custom udev rules for network devices
- See `../mana-driver-check/` - MANA driver monitoring and reload

## Kernel Parameter References

- TCP window scaling: `man tcp` 
- Memory management: `man sysctl`
- Network tuning: `man ip-sysctl`
- Busy poll: kernel documentation `/usr/share/doc/linux-doc/networking/`

## Performance Impact

**Expected improvements with these settings:**

- **Throughput**: 10-30% increase for high-bandwidth workloads
- **Latency**: 5-15% reduction with busy poll enabled
- **Memory efficiency**: Better utilization of available RAM
- **Stability**: Reduced packet loss during burst traffic

**Potential trade-offs:**

- Increased memory usage (buffers set to 128MB default)
- Slightly higher CPU usage with busy poll enabled
- Connection metric caching disabled (negligible impact)

## Troubleshooting

**Settings Not Applied After Reboot:**

```bash
# Check if file exists and is readable
ls -la /etc/sysctl.d/99-sysctl-*.conf

# Verify sysctl service is enabled
systemctl status systemd-sysctl.service

# Manually apply after boot
sudo sysctl -p /etc/sysctl.d/99-sysctl-full.conf
```

**Connection Issues After Applying:**

1. Check kernel version compatibility
2. Review commented-out parameters for your workload
3. Try minimal profile first, then gradually enable additional parameters
4. Monitor with: `dmesg | tail` for kernel messages

**Memory Usage Increased:**

- Buffers are allocated on-demand, not pre-allocated
- High values are defaults; actual usage depends on workload
- Monitor with: `free -h` and `ss -tni`

## Advanced Customization

For specific workloads, calculate personalized buffer values:

```
TCP receive buffer = BDP (Bandwidth × Delay Product)
Example: 10Gbps link with 100ms RTT = 125MB optimal
Formula: (bandwidth_gbps × 1,000,000,000 / 8) × (rtt_ms / 1000)
```

Edit the configuration files and adjust max values accordingly, then reapply.

## TCP Congestion Control: BBR vs CUBIC

This is a critical decision for Azure cross-region and cross-AZ deployments. Both configurations default to **BBR**, which is recommended for most scenarios, but requires testing.

### Algorithm Comparison

| Aspect | BBR | CUBIC |
|--------|-----|-------|
| **Algorithm Type** | Model-based (BDP) | Loss-based (AIMD) |
| **Latency** | Lower, more predictable | Variable, can spike |
| **Throughput** | Optimized for WAN | Optimized for LAN |
| **Queue Depth** | Smaller (better) | Larger (can buildup) |
| **Cross-AZ Performance** | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐ Poor |
| **Same-Region Performance** | ⭐⭐⭐⭐ Good | ⭐⭐⭐⭐ Good |
| **CPU Overhead** | Slightly higher | Lower |
| **Kernel Version** | 4.9+ required | Always available |
| **Testing Needed** | **YES** | No |

### When to Use Each

#### Use BBR (Recommended for Azure):
- **Cross-availability zone traffic** - BBR handles multi-AZ latency better
- **Cross-region replication** - Database replication, backup transfers
- **Geographic distribution** - Multi-region deployments
- **Geo-redundant storage** - Blob storage replication
- **WAN links** - Any long-haul connections
- **Variable latency networks** - Cloud interconnect, ExpressRoute
- **High throughput requirements** - Need to fill high-BDP pipes
- **HTTP/2 and modern applications** - Better header compression and prioritization

#### Use CUBIC (Traditional approach):
- **Single region deployments** - All VMs in same region/VNET
- **Low-latency cluster communication** - Local database clusters
- **Legacy kernel** - Kernel < 4.9 (no BBR support)
- **Conservative deployment** - When no performance issues exist
- **Simple topologies** - No multi-path routing or failover
- **Legacy application compatibility** - Known to work well with CUBIC

### Implementation Details

#### Enable BBR (Current Default)

```bash
# Check kernel version
uname -r  # Must be >= 4.9

# Check available congestion control algorithms
cat /proc/sys/net/ipv4/tcp_available_congestion_control

# Load BBR module (if not already loaded)
sudo modprobe tcp_bbr

# Apply configuration (already set in 99-sysctl-full.conf and 99-sysctl-minimal.conf)
sudo sysctl -p /etc/sysctl.d/99-sysctl-*.conf

# Verify BBR is active
cat /proc/sys/net/ipv4/tcp_congestion_control  # Should output: bbr
```

#### Switch to CUBIC (If Needed)

```bash
# Option 1: Modify sysctl file
sudo nano /etc/sysctl.d/99-sysctl-full.conf
# Change: net.ipv4.tcp_congestion_control = bbr
# To:     net.ipv4.tcp_congestion_control = cubic
# Also change: net.core.default_qdisc = fq
# To:         net.core.default_qdisc = pfifo_fast

# Option 2: Apply immediately (temporary until reboot)
sudo sysctl net.ipv4.tcp_congestion_control=cubic
sudo sysctl net.core.default_qdisc=pfifo_fast

# Apply permanently
sudo sysctl -p /etc/sysctl.d/99-sysctl-full.conf
```

### Queue Discipline (qdisc) Pairing

Queue discipline **must** be matched with congestion control algorithm:

| CC Algorithm | Recommended qdisc | Why |
|--------------|-------------------|-----|
| BBR | **fq** (Fair Queue) | BBR needs per-flow fairness; fq provides it |
| CUBIC | pfifo_fast | Traditional pairing; lower CPU |
| Any | fqcodel | Advanced, good for mixed workloads |

**Current Configuration:**
```
net.ipv4.tcp_congestion_control = bbr      # Model-based, WAN-optimized
net.core.default_qdisc = fq                # Fair queuing for per-flow isolation
```

This pairing (BBR + fq) is optimal for:
- Azure cross-AZ traffic
- Multi-tenant workloads
- Variable latency environments
- High-throughput scenarios

### Testing & Verification

**CRITICAL: Always test before production deployment!**

BBR behavior varies significantly based on:
- Network path characteristics
- Application type (streaming vs request/response)
- Traffic patterns (burst vs steady)
- Competing flows

#### 1. Verify Configuration

```bash
# Check active congestion control
cat /proc/sys/net/ipv4/tcp_congestion_control

# Check active qdisc
tc qdisc show

# Check socket-level status
ss -tni | grep -E "bbr|cubic|State"

# Monitor in real-time
watch -n 1 'cat /proc/sys/net/ipv4/tcp_congestion_control'
```

#### 2. Baseline Test (Before BBR)

```bash
# Test with CUBIC first to establish baseline
sudo sysctl net.ipv4.tcp_congestion_control=cubic
sudo sysctl net.core.default_qdisc=pfifo_fast

# Run benchmark
iperf3 -c <remote-ip> -t 60 -i 10 -R  # Download test
iperf3 -c <remote-ip> -t 60 -i 10     # Upload test

# Record results: throughput, jitter, retransmits
```

#### 3. BBR Test

```bash
# Switch to BBR
sudo sysctl net.ipv4.tcp_congestion_control=bbr
sudo sysctl net.core.default_qdisc=fq

# Run same benchmark
iperf3 -c <remote-ip> -t 60 -i 10 -R  # Download test
iperf3 -c <remote-ip> -t 60 -i 10     # Upload test

# Compare results
```

#### 4. Application-Specific Testing

```bash
# For database replication
# Monitor replication lag with: 
# MySQL: SHOW SLAVE STATUS\G | grep Seconds_Behind_Master
# PostgreSQL: SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag

# For S3/blob transfers
# Monitor with: aws s3 sync --monitoring (for CloudWatch metrics)

# For general workloads
# Monitor: tcpdump, ss -tni, sar (network metrics)
```

#### 5. Monitor These Metrics

When testing BBR, monitor:

| Metric | CUBIC Baseline | BBR Goal | Tools |
|--------|----------------|----------|-------|
| Throughput | Baseline | ≥ Baseline (usually +10-30%) | iperf3, netperf |
| Latency | High variance | Lower, more stable | ping, iperf3 |
| Packet loss | % | Should decrease | tcpdump, sar |
| RTT (Round Trip Time) | Variable | Stable | tc -s qdisc show |
| Retransmits | Count | Should decrease | ss -i, netstat -s |
| Queue depth | High | Smaller | tc -s qdisc show |
| CPU usage | Low | Slightly higher but acceptable | top, mpstat |

#### 6. Real-World Scenarios to Test

**Cross-AZ Database Replication:**
```bash
# Monitor replication performance
# Before: CUBIC baseline
# After: BBR optimization
# Goal: Lower lag, smoother throughput
```

**Backup Transfer (BlobStorage, S3):**
```bash
# Test large file transfer (10GB+)
# Monitor: Transfer speed, retransmits, connection stability
# BBR should show more stable throughput
```

**High-Frequency Trading / Real-time Apps:**
```bash
# Latency measurements with iperf3 -R (reverse)
# BBR typically shows lower max latency
# Monitor variance and p99/p95 percentiles
```

### Troubleshooting BBR Issues

#### Problem: Lower Throughput with BBR

**Possible Causes:**
- Network path doesn't support BBR well (edge case)
- Application expects CUBIC congestion window behavior
- Firewall/middlebox dropping BBR-specific packets

**Solutions:**
```bash
# Try CUBIC for that specific path
sudo sysctl net.ipv4.tcp_congestion_control=cubic

# Or use bbr2 if available (kernel 5.8+)
sudo sysctl net.ipv4.tcp_congestion_control=bbr2

# Check for packet loss
tcpdump -i eth0 'tcp and host <remote-ip>'
```

#### Problem: Increased Latency with BBR

**Possible Causes:**
- TCP_NOTSENT_LOWAT setting (only in full config)
- Flow starts up too slowly
- Network has unusual characteristics

**Solutions:**
```bash
# Check TCP_NOTSENT_LOWAT setting
sysctl net.ipv4.tcp_notsent_lowat

# Temporarily disable for testing
sudo sysctl net.ipv4.tcp_notsent_lowat=0

# Run latency test again
ping -c 100 -s 1472 <remote-ip> | tail -5
```

#### Problem: Application Timeout with BBR

**Possible Causes:**
- Initial slow start behavior
- Flow doesn't reach desired throughput quickly enough

**Solutions:**
```bash
# Application-side: Increase timeouts
# Or use TCP_NOTSENT_LOWAT socket option to trigger faster sends

# System-side: Check if CUBIC works better
sudo sysctl net.ipv4.tcp_congestion_control=cubic
```

### Decision Tree: BBR or CUBIC?

```
Is this Azure cross-AZ or cross-region traffic?
├─ YES → Use BBR (Recommended)
│   ├─ Test before production
│   ├─ Monitor first 2 weeks closely
│   └─ Keep CUBIC config handy for fallback
│
└─ NO → Is this single-region, same-VNET traffic?
    └─ YES → Can use CUBIC or BBR (BBR usually better)
    │   ├─ If unsure → Start with BBR
    │   └─ If CUBIC works → Can stay on CUBIC
    │
    └─ NO → What's your requirement?
        ├─ Performance critical → Use BBR (with testing)
        ├─ Conservative approach → Use CUBIC
        └─ Legacy system → Use CUBIC (kernel < 4.9)
```

### Performance Expectations

**Typical improvements with BBR (cross-AZ/region):**
- **Throughput**: +10-30% (especially on long-haul links)
- **Latency variance**: -20-40% (more predictable)
- **Packet loss**: -50-80% (fewer retransmits)
- **Queue depth**: -30-50% (less buffering)

**When results may vary:**
- Workload-specific: Some apps see no difference
- Path-specific: Some routes don't benefit
- Competition: With other flows, results differ
- Transient: Network conditions change

**Bottom line:** Test in your specific environment!

## Additional Resources

- Azure Linux Performance Tuning: https://learn.microsoft.com/azure/virtual-machines/
- Linux Kernel Documentation: https://www.kernel.org/doc/
- Man pages: `man sysctl`, `man ip-sysctl`, `man tcp`
