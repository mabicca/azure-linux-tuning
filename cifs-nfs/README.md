# CIFS/NFS Filesystem Cache Tuning

This folder contains sysctl configurations optimized for remote filesystem protocols (CIFS/SMB and NFS) with filesystem caching enabled on Azure.

## Files

- `sysctl-cifs-fscache.conf` - CIFS/SMB optimization with fscache
- `sysctl-nfs-fscache.conf` - NFS optimization with fscache (Azure NetApp Files)

## Overview

These configurations optimize kernel memory management for remote filesystems by tuning:
- **Dirty page caching** - When and how aggressively data is written to disk
- **Writeback timing** - How frequently the kernel flushes dirty data
- **Inode caching** - Memory management for filesystem metadata

## Use Cases

### CIFS/SMB (sysctl-cifs-fscache.conf)

**Use when:**
- Mounting Azure Files (SMB protocol)
- Using fscache for CIFS mounts
- Accessing shared SMB/CIFS storage
- Windows file shares or Samba servers

**Configuration focus:**
- Slightly longer writeback interval (20 seconds) - allows better batching
- Balanced cache pressure (40) - CIFS benefits from keeping more cache
- Good for: File serving, document storage, shared folders

### NFS (sysctl-nfs-fscache.conf)

**Use when:**
- Mounting Azure NetApp Files (NFS protocol)
- Using fscache for NFS mounts
- High-throughput NFS workloads
- Database or analytics over NFS

**Configuration focus:**
- Faster writeback interval (3 seconds) - NFS prefers more frequent flushes
- Same cache pressure as CIFS (40) - balanced approach
- Good for: Databases, analytics, performance-critical NFS

## Installation

### Option 1: Using sysctl.d (Recommended)

```bash
# For CIFS mounts
sudo cp sysctl-cifs-fscache.conf /etc/sysctl.d/99-cifs-fscache.conf
sudo chmod 644 /etc/sysctl.d/99-cifs-fscache.conf

# For NFS mounts
sudo cp sysctl-nfs-fscache.conf /etc/sysctl.d/99-nfs-fscache.conf
sudo chmod 644 /etc/sysctl.d/99-nfs-fscache.conf

# Apply both
sudo sysctl -p /etc/sysctl.d/99-cifs-fscache.conf
sudo sysctl -p /etc/sysctl.d/99-nfs-fscache.conf

# Or apply all sysctl.d changes at once
sudo sysctl -p
```

### Option 2: Combine with Main Configuration

```bash
# If using the main sysctl configuration, append these:
sudo cat sysctl-cifs-fscache.conf >> /etc/sysctl.d/99-sysctl-full.conf
sudo sysctl -p
```

## Configuration Details

### Dirty Page Thresholds

Both configurations set **absolute byte limits** rather than percentages for predictability:

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `vm.dirty_bytes` | 30MB | Process starts writeback at 30MB dirty |
| `vm.dirty_background_bytes` | 16MB | Background writeback starts at 16MB |
| `vm.dirty_ratio` | 0 | Disabled (using dirty_bytes instead) |
| `vm.dirty_background_ratio` | 0 | Disabled (using dirty_background_bytes instead) |

**Why fixed bytes?**
- Predictable behavior across different VM sizes
- Better performance than ratio-based (percentage) limits
- Easier to tune for specific workloads

### Writeback Timing

| Parameter | CIFS | NFS | Purpose |
|-----------|------|-----|---------|
| `vm.dirty_expire_centisecs` | 2000 (20s) | 300 (3s) | Max age of dirty data before flush |
| `vm.dirty_writeback_centisecs` | 100 (1s) | 100 (1s) | How often flusher threads wake up |
| `vm.dirtytime_expire_seconds` | 3600 (1h) | 3600 (1h) | Lazy inode timestamp expiration |

**Why different expire times?**
- **CIFS (20s)**: Allows better batching of writes, tolerates slightly longer latency
- **NFS (3s)**: Prefers frequent, smaller flushes for better consistency

### Cache Pressure

| Parameter | Value | Impact |
|-----------|-------|--------|
| `vm.vfs_cache_pressure` | 40 | Moderate cache aggressiveness |

**What this means:**
- Default is 100 (standard reclaim)
- Value of 40 (recommended): Keep more cached entries
- Lower values (10-20): Very aggressive caching
- Higher values (100+): Aggressively reclaim cache

**For remote filesystems:**
- 40 provides good balance
- Benefits: Fewer re-reads from network
- Trade-off: Uses more memory

## Performance Tuning

### Monitor Current Settings

```bash
# View dirty page configuration
sysctl vm.dirty_bytes vm.dirty_background_bytes
sysctl vm.dirty_expire_centisecs vm.dirty_writeback_centisecs

# Check cache pressure
sysctl vm.vfs_cache_pressure

# Monitor real-time dirty pages
watch -n 1 'grep Dirty /proc/meminfo'
```

### Monitor Writeback Activity

```bash
# Check writeback statistics
cat /proc/vmstat | grep writeback

# Monitor with iostat
iostat -x 1

# Watch system load during heavy write activity
top -b -d 1
```

### When to Adjust

**If experiencing:**
- **Long latency on writes**: Increase `dirty_expire_centisecs` (allow longer caching)
- **Memory pressure**: Decrease dirty_bytes or increase cache_pressure
- **NFS lock timeouts**: Decrease `dirty_expire_centisecs` (more frequent flushes)
- **High disk activity**: Could go either way - test both directions

**Tuning process:**
1. Start with provided configuration
2. Monitor performance for 1-2 weeks
3. Adjust one parameter at a time
4. Monitor for 3-5 days per change
5. Keep baseline metrics for comparison

## Combining with Main Configuration

These filesystem cache settings complement the main sysctl tuning:

### Apply in Order:

```bash
# 1. Main sysctl configuration (sets global networking/memory parameters)
sudo sysctl -p /etc/sysctl.d/99-sysctl-full.conf

# 2. Filesystem-specific tuning (refines behavior for CIFS/NFS)
sudo sysctl -p /etc/sysctl.d/99-cifs-fscache.conf  # or 99-nfs-fscache.conf
```

**What happens when both are applied:**
- Main config: Sets global network buffers, congestion control, swappiness
- CIFS/NFS config: Adjusts dirty page thresholds and writeback timing
- Result: Optimized for both network AND filesystem caching

### Example: Full Stack

```bash
# Copy all configurations
sudo cp /path/to/99-sysctl-full.conf /etc/sysctl.d/
sudo cp /path/to/sysctl-cifs-fscache.conf /etc/sysctl.d/99-cifs-fscache.conf

# Apply everything
sudo sysctl -p

# Verify all are applied
sudo sysctl -a | grep -E "tcp_mem|dirty_bytes|vfs_cache"
```

## Troubleshooting

### Settings Not Taking Effect

```bash
# Verify file is readable
ls -la /etc/sysctl.d/99-*fscache.conf

# Manually apply
sudo sysctl -p /etc/sysctl.d/99-cifs-fscache.conf

# Check for errors
sudo sysctl -p 2>&1 | head -20
```

### High Memory Usage

```bash
# Check dirty pages
grep Dirty /proc/meminfo

# If too high, reduce dirty_bytes:
sudo sysctl vm.dirty_bytes=16777216  # 16MB instead of 30MB

# Make permanent
sudo nano /etc/sysctl.d/99-cifs-fscache.conf
# Edit vm.dirty_bytes = 16777216
sudo sysctl -p
```

### Slow Remote Filesystem Access

```bash
# Check cache effectiveness
cat /proc/vmstat | grep -E "pginodesteal|slabs_scanned"

# If cache misses are high, try:
sudo sysctl vm.vfs_cache_pressure=30  # More aggressive caching

# Monitor improvement
watch -n 1 'cat /proc/vmstat | grep -E "pginodesteal|slabs_scanned"'
```

### NFS Lock Conflicts or Timeouts

```bash
# Try shorter writeback interval
sudo sysctl vm.dirty_expire_centisecs=100  # 1 second instead of 3

# Or increase inode expiration
sudo sysctl vm.dirtytime_expire_seconds=1800  # 30 minutes instead of 1 hour
```

## Key Differences: CIFS vs NFS

| Aspect | CIFS | NFS |
|--------|------|-----|
| **Protocol** | SMB/CIFS | NFS |
| **Azure Service** | Azure Files | Azure NetApp Files |
| **Writeback Interval** | 20s (longer) | 3s (shorter) |
| **Consistency Model** | Event-based | Time-based |
| **Lock Handling** | Lease-based | Stateful |
| **Cache Strategy** | Aggressive | Conservative |
| **Best For** | General file sharing | Performance-critical workloads |

## Performance Expectations

**With these configurations:**
- **Throughput**: 10-20% improvement for sequential access
- **Latency**: Slightly reduced for cached reads
- **Memory usage**: Increased (due to larger dirty_bytes)
- **Disk activity**: More bursty (batch writes every 1-20s)

**When benefits are highest:**
- Large sequential reads/writes
- Repeated access to same files
- Network with moderate latency
- Workloads with bursty traffic patterns

## References

- [Kernel VM Tuning Documentation](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/vm.html)
- [Azure NetApp Files Performance](https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-filesystem-cache)
- [Linux Filesystem Caching](https://www.baeldung.com/linux/file-system-caching)
- [CIFS/SMB Documentation](https://wiki.samba.org/index.php/Main_Page)
- [NFS Tuning Guide](https://linux.die.net/man/5/nfs)

## Related Configurations

- Main sysctl tuning: See `../sysctl/README.md`
- Systemd network tuning: See `../systemd/README.txt`
- MANA driver monitoring: See `../mana-driver-check/README.md`
