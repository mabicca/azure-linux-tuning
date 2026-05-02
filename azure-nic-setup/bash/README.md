# azure-nic-setup

A bash script to configure NIC ring buffer sizes on Azure VMs. It installs a
helper script, systemd service units, and udev rules so ring sizes are applied
automatically whenever a NIC is added or moved.

## Prerequisites

| Requirement | Notes |
|---|---|
| Linux (systemd) | Ubuntu, Debian, RHEL, Oracle Linux, SUSE |
| `bash` ≥ 4.0 | Pre-installed on all supported distros |
| `ethtool` | Used to read and apply ring sizes |
| `root` / `sudo` | Required to write to `/etc/systemd/system`, `/etc/udev/rules.d`, and `/usr/local/sbin` |

Known limitation: Red Hat Enterprise Linux 9 is not currently reliable for MANA-based accelerated networking with this setup due to missing upstream/backported MANA patches in some kernel builds.

Install `ethtool` if it is not already present:

```bash
# Debian / Ubuntu
sudo apt-get install -y ethtool

# RHEL / Oracle Linux / CentOS
sudo yum install -y ethtool

# SUSE
sudo zypper install -y ethtool
```

## Installation

### 1. Download the script

```bash
curl -O https://your-host/azure-nic-setup.sh
# or copy it from this repository
```

### 2. Make it executable

```bash
chmod +x azure-nic-setup.sh
```

### 3. Run it (as root)

```bash
sudo ./azure-nic-setup.sh [OPTIONS]
```

Running without options applies the built-in defaults and will prompt for
confirmation before making any changes.

**Important:** When you specify only `--an` or only `--synth`, only those NIC types
will be configured. The other type will be skipped (not configured with defaults).

## What it does

When installed, the script:

1. Saves the current ring settings to `/etc/azure-nic-config.state` (used by
   `--uninstall` to restore original values).
2. Writes a helper script to `/usr/local/sbin/azure-apply-rings.sh`.
3. Creates two systemd template units:
   - `set-rings-an@.service` — for accelerated NICs (mana, mlx4, mlx5)
   - `set-rings-synth@.service` — for synthetic NICs (hv_netvsc)
4. Writes a udev rule at `/etc/udev/rules.d/99-azure-nic-config.rules` that
   triggers the correct unit whenever a NIC appears.
5. Immediately applies the ring sizes to all currently active interfaces.
6. Reloads `systemd` and `udevadm`.

## Usage

```
Usage: azure-nic-setup.sh [OPTIONS]

OPTIONS:
    --an RX TX      Ring sizes for Accelerated NICs   (default: 4096 4096)
    --synth RX TX   Ring sizes for Synthetic NICs     (default: 1024 1024)
    --uninstall     Remove all installed files and restore original ring sizes
    -d, --debug     Enable verbose debug output
    -y, --yes       Skip the confirmation prompt
    -h, --help      Display this help message
```

## Examples

```bash
# Use built-in defaults (prompts for confirmation)
sudo ./azure-nic-setup.sh

# Custom ring sizes for both NIC types
sudo ./azure-nic-setup.sh --an 4096 4096 --synth 1024 1024

# Tune only accelerated NICs (synthetic NICs will not be modified)
sudo ./azure-nic-setup.sh --an 8192 8192

# Tune only synthetic NICs (accelerated NICs will not be modified)
sudo ./azure-nic-setup.sh --synth 2048 2048

# Apply large rings non-interactively (e.g. from cloud-init)
sudo ./azure-nic-setup.sh --an 8192 8192 --synth 2048 2048 --yes

# Debug mode — shows driver classification and ethtool output
sudo ./azure-nic-setup.sh --an 4096 4096 --debug

# Remove everything and restore original ring sizes
sudo ./azure-nic-setup.sh --uninstall
```

## NIC classification

| Driver | Type | Option used |
|---|---|---|
| `mana`, `mlx5_core`, `mlx4_en`, `mlx4_core` | Accelerated | `--an` |
| `hv_netvsc` | Synthetic | `--synth` |
| anything else | — | skipped |

## Environment variable overrides

These are primarily intended for testing but can be used in any environment:

| Variable | Default | Description |
|---|---|---|
| `HELPER_SCRIPT` | `/usr/local/sbin/azure-apply-rings.sh` | Path for the installed helper script |
| `SYSTEMD_DIR` | `/etc/systemd/system` | Where systemd unit files are written |
| `UDEV_DIR` | `/etc/udev/rules.d` | Where the udev rules file is written |
| `STATE_FILE` | `/etc/azure-nic-config.state` | Where original ring sizes are saved |

Example — install to non-default paths:

```bash
sudo SYSTEMD_DIR=/tmp/test-systemd UDEV_DIR=/tmp/test-udev ./azure-nic-setup.sh --yes
```

## Verifying the installation

After running the script, confirm the installed files are in place:

```bash
# Check systemd units
sudo systemctl list-units | grep set-rings
cat /etc/systemd/system/set-rings-an@.service
cat /etc/systemd/system/set-rings-synth@.service

# Check udev rules
cat /etc/udev/rules.d/99-azure-nic-config.rules

# Check helper script
cat /usr/local/sbin/azure-apply-rings.sh

# Check current ring sizes on a live interface
ethtool -g <interface-name>
```

## Uninstalling

```bash
sudo ./azure-nic-setup.sh --uninstall
```

This removes all installed files and uses the saved state file to restore each
NIC's original ring sizes.

## Troubleshooting

**ethtool reports ring sizes were not changed**
Ring size limits vary by driver and VM size. The script will print a warning if
a requested value exceeds the NIC's reported maximum. Check the maximum with:
```bash
ethtool -g <interface>
```

**systemctl / udevadm not found**
The script prints a notice rather than failing when these are not available
(expected in test environments). On a production Azure VM they should always be
present.

**RHEL 9 and MANA reliability**
Red Hat Enterprise Linux 9 may not behave reliably for MANA-based accelerated
networking with this setup due to missing upstream/backported MANA patches in
some kernel builds.

**Permission denied writing to /etc/**
Run the script with `sudo`.

**Non-interactive / cloud-init usage**
Pass `--yes` to skip the confirmation prompt when running from automation:
```bash
sudo ./azure-nic-setup.sh --an 4096 4096 --synth 1024 1024 --yes
```
