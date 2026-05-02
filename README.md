# Azure Linux Tuning

This repository contains documentation, configuration files, and utilities for optimizing Linux performance on Azure Cloud VMs. It covers kernel parameters, network interface tuning, filesystem caching, and driver monitoring with practical examples and best practices.

## Quick Start

Choose the approach that fits your needs:

| Need | Solution | Location |
|------|----------|----------|
| **Automatic NIC ring buffer setup** | azure-nic-setup utility (recommended) | [`azure-nic-setup/`](azure-nic-setup/) |
| **Manual NIC ring buffer tuning** | UDEV rules + sysctl | [`udev-rules/`](udev-rules/) + [`sysctl/`](sysctl/) |
| **CIFS/NFS cache optimization** | Filesystem cache config | [`cifs-nfs/`](cifs-nfs/) |
| **MANA driver monitoring** | Driver health monitor | [`mana-driver-check/`](mana-driver-check/) |
| **Systemd network config** | Interface buffer tuning | [`systemd/`](systemd/) |

## Repository Contents

### 🔧 [azure-nic-setup](azure-nic-setup/) - Automated NIC Configuration

Comprehensive bash script for configuring network interface ring buffers on Azure VMs.

**What it does:**
- Automatically detects and configures ring buffers for all NIC types (Synthetic, Accelerated, MANA)
- Installs udev rules for persistent configuration across reboots
- Integrates with systemd for automatic reapplication
- Provides configuration templates for different workload profiles

**Best for:** Production deployments, simplified setup, automatic management

**Languages:** Bash, Rust (utility versions available)

---

### 📊 [sysctl](sysctl/) - Kernel Parameter Tuning

Comprehensive kernel parameter configurations for optimizing network and memory performance.

**What it does:**
- Tunes TCP/UDP buffer sizes for higher throughput
- Configures congestion control algorithms (BBR vs CUBIC)
- Optimizes memory management (dirty pages, cache pressure)
- Provides two profiles: Full (maximum performance) and Minimal (conservative)

**Key parameters:**
- TCP/UDP buffers: Optimized for 8KB minimums
- BBR congestion control with fair queuing (fq) for cross-AZ traffic
- Memory: Dirty page thresholds, swappiness, orphan socket limits
- Security: SYN cookies, fragment protection

**Use cases:** High-throughput workloads, databases, cross-region replication

**Profiles:**
- **99-sysctl-full.conf** - Maximum performance with all optimizations
- **99-sysctl-minimal.conf** - Conservative approach for testing/staging

---

### 🌐 [systemd](systemd/) - Network Interface Optimization

Systemd network configuration for persistent buffer tuning at the interface level.

**What it does:**
- Configures RX/TX buffer sizes (max recommended)
- Enables offloading features (TSO, GSO, GRO)
- Applies settings on interface startup
- Works with systemd 243+ (250+ recommended)

**Parameters:**
- RX/TX buffers: Maximized for throughput
- TCP Segmentation Offload (TSO)
- Large Receive Offload (LRO)
- Generic Receive Offload (GRO)

**Use for:** Interface-level tuning that persists across reboots

---

### 🔌 [udev-rules](udev-rules/) - Dynamic Device Configuration

UDEV rules that automatically apply network tuning when NICs are discovered.

**What it does:**
- Sets ring buffer sizes on device attachment (1024 RX/TX)
- Disables UDP hashing on synthetic interfaces (prevents reordering)
- Applies NOQUEUE qdisc to accelerated interfaces (lower latency)
- Configures transmit queue lengths (2048 standard, 5000 loopback)

**Supports:**
- MANA accelerated networking (hv_pci)
- Mellanox accelerated networking (mlx*)
- Synthetic networking (hv_netvsc)

**Note:** For production, use [azure-nic-setup](azure-nic-setup/) which builds on these rules with better management

---

### 📁 [cifs-nfs](cifs-nfs/) - Filesystem Cache Tuning

Specialized sysctl configurations for CIFS/SMB and NFS workloads.

**What it does:**
- Optimizes dirty page thresholds for file sharing protocols
- Tunes writeback intervals (CIFS: 20s aggressive, NFS: 3s conservative)
- Configures dentry/inode cache pressure (40 for balanced performance)

**Configurations:**
- **sysctl-cifs-fscache.conf** - For Azure Files (SMB/CIFS)
- **sysctl-nfs-fscache.conf** - For Azure NetApp Files (NFS)

**Use when:** Mounting remote filesystems with fscache enabled

---

### 🔍 [mana-driver-check](mana-driver-check/) - MANA Driver Monitoring

Monitoring utility for Microsoft Azure Network Adapter (MANA) driver health.

**What it does:**
- Monitors MANA error counters (tx_cqe_unknown_type, rx_cqe_unknown_type)
- Automatically reloads driver if error thresholds exceeded
- Runs as systemd service for continuous monitoring
- Provides detailed error tracking and troubleshooting

**Best for:** MANA accelerated networking VMs, production monitoring

**Languages:** Bash with systemd integration

---

## Recommended Configuration Stack

### For Production High-Performance VMs

```
1. azure-nic-setup          (NIC ring buffers)
   ↓
2. sysctl/99-sysctl-full    (Global kernel tuning)
   ↓
3. systemd/network.conf     (Interface buffers)
   ↓
4. cifs-nfs/* (if applicable) (Filesystem cache)
   ↓
5. mana-driver-check        (Health monitoring)
```

### For Testing/Conservative Approach

```
1. udev-rules only          (Basic NIC tuning)
   ↓
2. sysctl/99-sysctl-minimal (Conservative tuning)
   ↓
3. Monitor and adjust...
```

### For Specific Workloads

- **Databases**: Full sysctl + azure-nic-setup + systemd tuning + MANA monitoring
- **File Sharing**: Full sysctl + cifs-nfs configs + azure-nic-setup
- **HPC/Scientific**: Full sysctl + azure-nic-setup + systemd tuning
- **Development/Test**: Minimal sysctl + udev-rules (quick feedback)

## Platform Support

Most configurations are platform-agnostic and work on:
- Ubuntu / Debian
- RHEL / CentOS / Oracle Linux
- SUSE Linux Enterprise

Scripts tested on systemd 243+ (recommended 250+)

## Key Concepts

**Ring Buffers** - Network packet queues on the NIC
- Default: Usually 256-512
- Tuned: 1024-2048 for better throughput
- Test higher values if experiencing packet loss

**Congestion Control** - TCP algorithm for network behavior
- **BBR**: Better for cross-AZ/WAN traffic, requires testing
- **CUBIC**: Default, good for LAN, well-tested

**Dirty Pages** - Memory waiting to be written to disk
- Lower thresholds: More frequent writes, lower latency
- Higher thresholds: Better throughput, more memory usage

**Queue Discipline** - Packet scheduling on NIC
- **NOQUEUE**: Direct processing, lowest latency
- **pfifo_fast**: Default, balanced fairness

## Documentation Structure

Each folder contains:
- **README.md** - Comprehensive guide for that component
- **Configuration files** - Ready-to-use parameter sets
- **Scripts** - Automation utilities

Start with the README in each folder for detailed information.

## References

### General Linux Tuning
https://fasterdata.es.net/host-tuning/linux/
https://github.com/leandromoreira/linux-network-performance-parameters
https://blog.cloudflare.com/author/marek-majkowski/
https://blog.packagecloud.io/illustrated-guide-monitoring-tuning-linux-networking-stack-receiving-data/
https://oxnz.github.io/2016/05/03/performance-tuning-networking/

### Azure Documentation
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-filesystem-cache
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-mount-options
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-concurrency-session-slots
https://learn.microsoft.com/en-us/azure/azure-netapp-files/performance-linux-nfs-read-ahead
https://learn.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-smb-performance

### Hyper-V Networking
https://www.kernel.org/doc/html/latest/networking/device_drivers/ethernet/microsoft/netvsc.html
