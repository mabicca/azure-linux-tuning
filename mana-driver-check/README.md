# Azure MANA Driver Monitor

This script and systemd unit monitor the Microsoft MANA driver on Linux and automatically reload the driver if error counters increase.

## Functionality

The `az-manacheck.sh` script:
- Monitors the `tx_cqe_unknown_type` and `rx_cqe_unknown_type` error counters for the MANA network interface
- Runs as a background daemon with automatic restart capability via systemd
- Reloads the MANA kernel modules if error counters are detected
- Ensures only one instance runs at a time using lock file management
- Logs all activity to `/var/log/az-mana.log`

## Requirements

- **Root/sudo access** - Required (script performs modprobe, rmmod, and other privileged operations)
- Linux kernel with MANA driver support
- Required utilities: `ip`, `ethtool`, `modprobe`, `lsmod`, `rmmod`
- Device `eth1` must exist on the system (or edit `DEVICE` variable in the script)

## Installation

1. Copy the script to `/usr/bin`
   ```bash
   sudo cp az-manacheck.sh /usr/bin/
   sudo chmod +x /usr/bin/az-manacheck.sh
   ```

2. Copy the systemd unit file to `/etc/systemd/system`
   ```bash
   sudo cp az-mana.service /etc/systemd/system/
   ```

3. Enable and start the systemd unit
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable az-mana.service
   sudo systemctl start az-mana.service
   ```

4. Verify the service is running
   ```bash
   sudo systemctl status az-mana.service
   ```

## Monitoring

View the script logs to monitor activity:
```bash
tail -f /var/log/az-mana.log
```

Common log entries:
- `INTERFACE ... is UP` - Normal operation
- `Counter increase detected` - Error condition detected and driver reloaded
- `ERROR` - Script encountered an error (check logs for details)

## Troubleshooting

If the service fails to start:
1. Check logs: `sudo journalctl -u az-mana.service -n 50`
2. Verify log file permissions: `ls -la /var/log/az-mana.log`
3. Ensure required commands are available: `which ip ethtool modprobe lsmod rmmod`
