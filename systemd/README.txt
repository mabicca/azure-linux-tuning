# Systemd Network Configuration

This folder contains systemd network configuration files that optimize network interface performance for Azure Linux environments.

## Overview

Modern systemd (version 243+) allows network tuning through `.link` and `.network` files without requiring custom kernel parameters or ethtool commands. These settings are applied early during boot and persist across network interface resets.

## Files

- `network.conf` - Core network interface optimization settings
- `99-default.link` - (if created) Directory containing network link configurations

## Installation

### Option 1: Using a Separate Directory (Recommended)

```bash
sudo mkdir -p /etc/systemd/network/99-azure-mana.link.d
sudo cp network.conf /etc/systemd/network/99-azure-mana.link.d/
sudo systemctl restart systemd-networkd
```

### Option 2: Create as a Direct Link File (Simple)

```bash
sudo cp network.conf /etc/systemd/network/99-azure-network.link
sudo systemctl restart systemd-networkd
```

## Configuration Details

### Match Section

`OriginalName=*`
- Applies these settings to all network interfaces
- Can be customized to target specific interfaces (e.g., `eth1`, `eth0`, etc.)

### Link Section Settings

**Naming & MAC Policy:**
- `NamePolicy=keep kernel database onboard slot path` - Determines network interface naming priority
- `AlternativeNamesPolicy=database onboard slot path` - Provides alternative names for the interface
- `MACAddressPolicy=persistent` - Ensures MAC address remains stable across reboots

**Buffer Sizes (RX/TX):**
- `RXBufferSize=max` - Maximizes receive buffer (improves throughput for high-speed connections)
- `TXBufferSize=max` - Maximizes transmit buffer (reduces packet loss during bursts)
- Supported values: `max`, or specific sizes (e.g., `RXBufferSize=4096`)
- Requires systemd 245+

**Offloading Options:**
- `GenericReceiveOffload=true` - Enables GRO (Large packets reassembled by hardware)
- `LargeReceiveOffload=true` - Enables LRO (Coalesces TCP packets into larger buffers)
- `TCPSegmentationOffload=true` - Enables TSO (Allows TCP stack to offload packet segmentation)
- These improve CPU efficiency by moving packet processing to NIC hardware

## Verification

After applying these settings, verify they are active:

```bash
# Check systemd-networkd status
systemctl status systemd-networkd

# View applied link settings
networkctl status eth1

# Check individual interface properties
cat /proc/net/dev
ethtool -k eth1  # View current offload settings
ethtool -S eth1  # View interface statistics
```

## Systemd Version Requirements

- **Minimum**: systemd 243
- **Recommended**: systemd 250+ (best support for buffer size tuning)

Check your systemd version:
```bash
systemctl --version
```

## Troubleshooting

### Troubleshooting

**Settings Not Applied:**
1. Verify file location: `/etc/systemd/network/99-*.link`
2. Check file permissions: `sudo chmod 644 /etc/systemd/network/99-*.link`
3. Restart systemd-networkd: `sudo systemctl restart systemd-networkd`
4. Check logs: `sudo journalctl -u systemd-networkd -n 50`

**Interface Naming Issues:**
- Unexpected interface names: Adjust the `NamePolicy` section
- Device name changes require systemd-networkd restart
- Verify with: `ip link show`

**Buffer Size Not at Maximum:**
- Some NICs do not support hardware buffer configuration
- Check supported values: `ethtool -g <interface>`
- Fall back to ethtool or sysctl if needed

## Manual Alternative (Without Systemd)

If using an older systemd or for temporary settings:

```bash
# View current buffer sizes
ethtool -g eth1

# Set buffer sizes (temporary)
ethtool -G eth1 rx 4096 tx 4096

# Enable offloading (temporary)
ethtool -K eth1 gro on lro on tso on

# Make persistent with sysctl (see ../sysctl/ folder)
```

## Related Files

- See `../sysctl/` folder for additional kernel parameter tuning
- See `../mana-driver-check/` folder for MANA driver monitoring
- See `../udev-rules/` folder for custom udev rules

## Documentation References

- Systemd Link Files: `man systemd.link`
- Systemd Network: `man systemd-networkd.service`
- Ethtool Documentation: `man ethtool`
- Azure Linux Tuning Guide: https://learn.microsoft.com/azure/virtual-machines/
