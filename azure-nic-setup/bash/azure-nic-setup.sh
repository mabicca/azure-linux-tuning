#!/usr/bin/env bash
set -euo pipefail

# Default values
AN_RX_RINGS=4096
AN_TX_RINGS=4096
SYNTH_RX_RINGS=1024
SYNTH_TX_RINGS=1024

# Behavior flags
ASSUME_YES=0
DEBUG=0

HELPER_SCRIPT="${HELPER_SCRIPT:-/usr/local/sbin/azure-apply-rings.sh}"

# Usage information
usage() {
    local exit_code=${1:-0}
    cat << EOF
Usage: $0 [OPTIONS]

Configure NIC ring sizes for Azure VMs via systemd units and udev rules.

OPTIONS:
    --an RX TX            Ring sizes for Accelerated NICs (default: $AN_RX_RINGS $AN_TX_RINGS)
    --synth RX TX         Ring sizes for Synthetic NICs (default: $SYNTH_RX_RINGS $SYNTH_TX_RINGS)
    --uninstall           Remove systemd units and udev rules
    -d, --debug           Enable debug output
    -y, --yes             Skip confirmation prompt
    -h, --help            Display this help message

EXAMPLES:
    $0 --an 4096 4096 --synth 1024 1024
    $0 --an 4096 4096
    $0 --synth 1024 1024
    $0 --debug --yes
    $0 --uninstall
EOF
    exit "$exit_code"
}

debug_log() {
    if [[ $DEBUG -eq 1 ]]; then
        echo "DEBUG: $*"
    fi
}

get_ring_maxima() {
    local iface="$1"
    ethtool -g "$iface" 2>/dev/null | awk '
        /Pre-set maximums:/ {preset=1; next}
        preset && $1=="RX:" && rx=="" {rx=$2}
        preset && $1=="TX:" && tx=="" {tx=$2}
        preset && rx != "" && tx != "" {print rx "," tx; exit}
    '
}

warn_if_exceeds_max() {
    local iface="$1"
    local target_rx="$2"
    local target_tx="$3"
    local max_values max_rx max_tx

    if ! command -v ethtool &> /dev/null; then
        return 0
    fi

    max_values=$(get_ring_maxima "$iface")
    if [[ -z "$max_values" ]]; then
        debug_log "Could not determine max ring values for $iface"
        return 0
    fi

    IFS=',' read -r max_rx max_tx <<< "$max_values"
    debug_log "$iface maximums: RX=$max_rx TX=$max_tx"

    if [[ -n "$max_rx" && "$target_rx" =~ ^[0-9]+$ && "$max_rx" =~ ^[0-9]+$ && $target_rx -gt $max_rx ]]; then
        echo "Warning: $iface requested RX=$target_rx exceeds max RX=$max_rx"
    fi

    if [[ -n "$max_tx" && "$target_tx" =~ ^[0-9]+$ && "$max_tx" =~ ^[0-9]+$ && $target_tx -gt $max_tx ]]; then
        echo "Warning: $iface requested TX=$target_tx exceeds max TX=$max_tx"
    fi
}

is_an_driver() {
    local driver="$1"
    case "$driver" in
        mana|mlx5|mlx5_core|mlx4|mlx4_en|mlx4_core)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

confirm_action() {
    local action="$1"

    if [[ $ASSUME_YES -eq 1 ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        echo "About to ${action}."
        read -r -p "Continue? [y/N]: " reply
        case "$reply" in
            y|Y|yes|YES)
                return 0
                ;;
            *)
                echo "Aborted."
                exit 0
                ;;
        esac
    else
        echo "Non-interactive mode detected; proceeding without confirmation prompt."
    fi
}

# Parse command-line arguments
HAS_PARAMS=0
HAS_AN_PARAMS=0
HAS_SYNTH_PARAMS=0
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --an)
            if [[ $# -lt 3 ]]; then
                echo "Error: --an requires two arguments (RX TX)"
                usage 1
            fi
            AN_RX_RINGS="$2"
            AN_TX_RINGS="$3"
            HAS_PARAMS=1
            HAS_AN_PARAMS=1
            shift 3
            ;;
        --synth)
            if [[ $# -lt 3 ]]; then
                echo "Error: --synth requires two arguments (RX TX)"
                usage 1
            fi
            SYNTH_RX_RINGS="$2"
            SYNTH_TX_RINGS="$3"
            HAS_PARAMS=1
            HAS_SYNTH_PARAMS=1
            shift 3
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -d|--debug)
            DEBUG=1
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "Unknown option: $1"
            usage 1
            ;;
    esac
done

# Uninstall function
uninstall() {
    echo "Removing NIC configuration files..."
    
    # Allow override via environment variables for testing
    SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
    UDEV_DIR="${UDEV_DIR:-/etc/udev/rules.d}"
    STATE_FILE="${STATE_FILE:-/etc/azure-nic-config.state}"
    
    # Remove systemd units
    if [[ -f "$SYSTEMD_DIR/set-rings-an@.service" ]]; then
        rm -f "$SYSTEMD_DIR/set-rings-an@.service"
        echo "Removed: $SYSTEMD_DIR/set-rings-an@.service"
    fi
    
    if [[ -f "$SYSTEMD_DIR/set-rings-synth@.service" ]]; then
        rm -f "$SYSTEMD_DIR/set-rings-synth@.service"
        echo "Removed: $SYSTEMD_DIR/set-rings-synth@.service"
    fi
    
    # Remove udev rules
    if [[ -f "$UDEV_DIR/99-azure-nic-config.rules" ]]; then
        rm -f "$UDEV_DIR/99-azure-nic-config.rules"
        echo "Removed: $UDEV_DIR/99-azure-nic-config.rules"
    fi

    # Remove helper script
    if [[ -f "$HELPER_SCRIPT" ]]; then
        rm -f "$HELPER_SCRIPT"
        echo "Removed: $HELPER_SCRIPT"
    fi
    
    # Reload systemd and udev
    echo "Reloading systemd and udev..."
    systemctl daemon-reload || echo "Note: systemctl not available (expected in test environment)"
    udevadm control --reload-rules || echo "Note: udevadm not available (expected in test environment)"
    udevadm trigger || echo "Note: udevadm not available (expected in test environment)"
    
    # Restore original ring settings if state file exists
    if [[ -f "$STATE_FILE" ]]; then
        echo "Restoring original NIC ring settings..."
        source "$STATE_FILE"
        
        # Restore settings for each NIC
        for nic in "${!NIC_ORIGINAL_RINGS[@]}"; do
            IFS=',' read -r orig_rx orig_tx <<< "${NIC_ORIGINAL_RINGS[$nic]}"
            if [[ -e /sys/class/net/"$nic" ]]; then
                echo "  Restoring $nic: RX=$orig_rx TX=$orig_tx"
                ethtool -G "$nic" rx "$orig_rx" tx "$orig_tx" 2>/dev/null || echo "    Warning: Could not restore $nic"
            fi
        done
        
        rm -f "$STATE_FILE"
        echo "Removed state file: $STATE_FILE"
    fi
    
    echo "Uninstall complete."
}

# Function to detect and save original NIC ring settings
save_original_settings() {
    local STATE_FILE="${STATE_FILE:-/etc/azure-nic-config.state}"
    
    # Only save if state file doesn't exist
    if [[ -f "$STATE_FILE" ]]; then
        return 0
    fi
    
    # Create state file header (silently skip if we don't have permissions)
    if ! cat > "$STATE_FILE" << 'EOF' 2>/dev/null
# Azure NIC Configuration State File
# Auto-generated on first run - used for uninstall restoration
declare -A NIC_ORIGINAL_RINGS
EOF
    then
        # Silently skip if we can't write (likely in test environment or no root)
        return 0
    fi
    
    echo "Detecting original NIC ring settings..."
    
    # Iterate through all NICs and save their ring settings
    shopt -s nullglob
    for nic_path in /sys/class/net/*; do
        local nic
        nic=$(basename "$nic_path")
        
        # Skip loopback
        if [[ "$nic" == "lo" ]]; then
            continue
        fi
        
        # Get ring settings using ethtool
        if command -v ethtool &> /dev/null; then
            local rx_tx
            rx_tx=$(ethtool -g "$nic" 2>/dev/null | awk '
                /Current hardware settings:/ {current=1; next}
                current && $1=="RX:" && rx=="" {rx=$2}
                current && $1=="TX:" && tx=="" {tx=$2}
                END {if (rx != "" && tx != "") print rx "," tx}
            ')
            if [[ -n "$rx_tx" ]]; then
                local rx tx
                IFS=',' read -r rx tx <<< "$rx_tx"
                echo "NIC_ORIGINAL_RINGS[$nic]=\"$rx,$tx\"" >> "$STATE_FILE" 2>/dev/null || true
                echo "  Saved $nic: RX=$rx TX=$tx"
            fi
        fi
    done
    shopt -u nullglob
    
    # Only show message if file was successfully created and written
    if [[ -f "$STATE_FILE" ]]; then
        echo "State file created: $STATE_FILE"
    fi
}

apply_ring_settings_now() {
    if ! command -v ethtool &> /dev/null; then
        echo "Warning: ethtool not found; skipping immediate ring update."
        return 0
    fi

    echo "Applying ring sizes immediately to active interfaces..."

    shopt -s nullglob
    for nic_path in /sys/class/net/*; do
        local nic driver target_rx target_tx
        nic=$(basename "$nic_path")

        if [[ "$nic" == "lo" ]]; then
            continue
        fi

        if [[ ! -e "$nic_path/device/driver" ]]; then
            continue
        fi

        driver=$(basename "$(readlink -f "$nic_path/device/driver" 2>/dev/null || true)")
        debug_log "Interface $nic driver=$driver"

        case "$driver" in
            mana|mlx5|mlx5_core|mlx4|mlx4_en|mlx4_core)
                # Skip if AN parameters were not explicitly specified
                if [[ $HAS_AN_PARAMS -eq 0 ]]; then
                    debug_log "Skipping $nic (accelerated NIC, but --an was not specified)"
                    continue
                fi
                target_rx="$AN_RX_RINGS"
                target_tx="$AN_TX_RINGS"
                debug_log "Classified $nic as accelerated (direct driver match)"
                ;;
            hv_netvsc)
                # Skip if SYNTH parameters were not explicitly specified
                if [[ $HAS_SYNTH_PARAMS -eq 0 ]]; then
                    debug_log "Skipping $nic (synthetic NIC, but --synth was not specified)"
                    continue
                fi
                target_rx="$SYNTH_RX_RINGS"
                target_tx="$SYNTH_TX_RINGS"
                debug_log "Classified $nic as synthetic (hv_netvsc)"
                ;;
            *)
                debug_log "Skipping $nic (unsupported driver)"
                continue
                ;;
        esac

        echo "  $nic ($driver): setting RX=$target_rx TX=$target_tx"
        warn_if_exceeds_max "$nic" "$target_rx" "$target_tx"
        if ! ethtool -G "$nic" rx "$target_rx" tx "$target_tx" 2>/dev/null; then
            echo "    Warning: could not apply settings to $nic"
        fi
    done
    shopt -u nullglob
}

# Handle uninstall flag
if [[ $UNINSTALL -eq 1 ]]; then
    confirm_action "remove NIC tuning configuration and restore original ring settings"
    uninstall
    exit 0
fi

# Save original NIC settings on first run (before installation)
save_original_settings

# Warn if using defaults (no parameters specified)
if [[ $HAS_PARAMS -eq 0 ]]; then
    echo "WARNING: No ring size parameters specified. Using defaults:"
    echo "  Accelerated NICs: RX=$AN_RX_RINGS TX=$AN_TX_RINGS"
    echo "  Synthetic NICs:   RX=$SYNTH_RX_RINGS TX=$SYNTH_TX_RINGS"
    echo "Use --help to see available options."
    echo ""
else
    # Inform user which NICs will be configured
    if [[ $HAS_AN_PARAMS -eq 0 ]]; then
        echo "Note: --an was not specified; Accelerated NICs will not be configured."
    fi
    if [[ $HAS_SYNTH_PARAMS -eq 0 ]]; then
        echo "Note: --synth was not specified; Synthetic NICs will not be configured."
    fi
    if [[ $HAS_AN_PARAMS -eq 1 || $HAS_SYNTH_PARAMS -eq 1 ]]; then
        echo ""
    fi
fi

# Validate that values are numeric
for var in AN_RX_RINGS AN_TX_RINGS SYNTH_RX_RINGS SYNTH_TX_RINGS; do
    if ! [[ ${!var} =~ ^[0-9]+$ ]]; then
        echo "Error: $var must be a positive integer, got '${!var}'"
        exit 1
    fi
done

confirm_action "configure NIC tuning files and apply ring settings"

echo "Configuring NICs with the following settings:"
if [[ $HAS_AN_PARAMS -eq 1 ]]; then
    echo "  Accelerated NICs: RX=$AN_RX_RINGS TX=$AN_TX_RINGS"
fi
if [[ $HAS_SYNTH_PARAMS -eq 1 ]]; then
    echo "  Synthetic NICs:   RX=$SYNTH_RX_RINGS TX=$SYNTH_TX_RINGS"
fi
echo ""

# Allow override via environment variables for testing
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
UDEV_DIR="${UDEV_DIR:-/etc/udev/rules.d}"

echo "Creating helper script: $HELPER_SCRIPT"
cat > "$HELPER_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

iface="\${1:-}"
mode="auto"
if [[ "\${1:-}" == "--mode" ]]; then
    mode="\${2:-auto}"
    shift 2
fi

iface="\${1:-}"
if [[ -z "\$iface" ]]; then
    echo "Usage: \\$0 [--mode an|synth|auto] <interface>" >&2
    exit 1
fi

AN_RX="$AN_RX_RINGS"
AN_TX="$AN_TX_RINGS"
SYNTH_RX="$SYNTH_RX_RINGS"
SYNTH_TX="$SYNTH_TX_RINGS"
DEBUG="$DEBUG"

debug_log() {
    if [[ "\$DEBUG" == "1" ]]; then
        echo "DEBUG: \$*"
    fi
}

get_ring_maxima() {
    local iface="\$1"
    "\$ethtool_bin" -g "\$iface" 2>/dev/null | awk '
        /Pre-set maximums:/ {preset=1; next}
        preset && \$1=="RX:" && rx=="" {rx=\$2}
        preset && \$1=="TX:" && tx=="" {tx=\$2}
        preset && rx != "" && tx != "" {print rx "," tx; exit}
    '
}

warn_if_exceeds_max() {
    local iface="\$1"
    local target_rx="\$2"
    local target_tx="\$3"
    local max_values max_rx max_tx

    max_values=\$(get_ring_maxima "\$iface")
    if [[ -z "\$max_values" ]]; then
        debug_log "Could not determine max ring values for \$iface"
        return 0
    fi

    IFS=',' read -r max_rx max_tx <<< "\$max_values"
    debug_log "\$iface maximums: RX=\$max_rx TX=\$max_tx"

    if [[ -n "\$max_rx" && "\$target_rx" =~ ^[0-9]+$ && "\$max_rx" =~ ^[0-9]+$ && \$target_rx -gt \$max_rx ]]; then
        echo "Warning: \$iface requested RX=\$target_rx exceeds max RX=\$max_rx" >&2
    fi

    if [[ -n "\$max_tx" && "\$target_tx" =~ ^[0-9]+$ && "\$max_tx" =~ ^[0-9]+$ && \$target_tx -gt \$max_tx ]]; then
        echo "Warning: \$iface requested TX=\$target_tx exceeds max TX=\$max_tx" >&2
    fi
}

is_an_driver() {
    local d="\$1"
    case "\$d" in
        mana|mlx5|mlx5_core|mlx4|mlx4_en|mlx4_core)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

target_rx="\$SYNTH_RX"
target_tx="\$SYNTH_TX"

driver=
if [[ -e "/sys/class/net/\$iface/device/driver" ]]; then
    driver=
    driver=\$(basename "\$(readlink -f "/sys/class/net/\$iface/device/driver" 2>/dev/null || true)")
fi

case "\$mode" in
    an)
        target_rx="\$AN_RX"
        target_tx="\$AN_TX"
        debug_log "\$iface forced accelerated mode"
        ;;
    synth)
        target_rx="\$SYNTH_RX"
        target_tx="\$SYNTH_TX"
        debug_log "\$iface forced synthetic mode"
        ;;
    auto)
        if is_an_driver "\$driver"; then
            target_rx="\$AN_RX"
            target_tx="\$AN_TX"
            debug_log "\$iface classified as accelerated (driver \$driver)"
        else
            target_rx="\$SYNTH_RX"
            target_tx="\$SYNTH_TX"
            debug_log "\$iface classified as synthetic (driver \$driver)"
        fi
        ;;
    *)
        echo "Invalid mode: \$mode" >&2
        exit 1
        ;;
esac

ethtool_bin=\$(command -v ethtool || true)
if [[ -z "\$ethtool_bin" ]]; then
    echo "ethtool not found" >&2
    exit 1
fi

warn_if_exceeds_max "\$iface" "\$target_rx" "\$target_tx"

"\$ethtool_bin" -G "\$iface" rx "\$target_rx" tx "\$target_tx"
EOF
chmod +x "$HELPER_SCRIPT"

echo "Creating systemd unit: set-rings-an@.service"
cat > "$SYSTEMD_DIR/set-rings-an@.service" <<EOF
[Unit]
Description=Set ring sizes for accelerated NIC %i
After=network.target

[Service]
Type=oneshot
ExecStart=$HELPER_SCRIPT --mode an %i

[Install]
WantedBy=multi-user.target
EOF

echo "Creating systemd unit: set-rings-synth@.service"
cat > "$SYSTEMD_DIR/set-rings-synth@.service" <<EOF
[Unit]
Description=Set ring sizes for synthetic NIC %i
After=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=$HELPER_SCRIPT --mode synth %i

[Install]
WantedBy=multi-user.target
EOF

echo "Creating udev rule: 99-azure-nic-config.rules"
cat > "$UDEV_DIR/99-azure-nic-config.rules" <<"EOF"
# Synthetic NICs (hv_netvsc)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="hv_netvsc", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-synth@%k.service"

# Accelerated NICs (mana)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mana", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx5_core)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mlx5_core", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_en)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mlx4_en", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_core)
SUBSYSTEM=="net", ACTION=="move", DRIVERS=="mlx4_core", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mana)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mana", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx5_core)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlx5_core", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_en)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlx4_en", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"

# Accelerated NICs (mlx4_core)
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mlx4_core", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="set-rings-an@%k.service"
EOF

apply_ring_settings_now

echo "Reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger

echo "Done."

