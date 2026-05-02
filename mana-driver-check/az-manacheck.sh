#!/bin/bash
# AZ Mana Check - Monitors MANA driver for error counters and reloads driver if needed
set -o pipefail

# Script configuration
COUNTERS=("tx_cqe_unknown_type" "rx_cqe_unknown_type")
DEVICE="eth1"
LOCKFILE="/var/tmp/monitor_script.lock"
LOGFILE="/var/log/az-mana.log"
CHECK_INTERVAL=20

# Validate required commands are available
require_commands() {
    local missing=0
    for cmd in ip ethtool modprobe lsmod rmmod; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "AZURE-MANA: ERROR - Required command not found: $cmd" >&2
            ((missing++))
        fi
    done
    if [[ $missing -gt 0 ]]; then
        echo "AZURE-MANA: ERROR - Missing $missing required command(s). Exiting." >&2
        exit 1
    fi
}

# Verify running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "AZURE-MANA: ERROR - This script must be run as root. Exiting." >&2
        exit 1
    fi
}

# Verify device exists
verify_device() {
    if ! ip link show "$DEVICE" > /dev/null 2>&1; then
        echo "AZURE-MANA: ERROR - Device $DEVICE not found. Exiting." >&2
        exit 1
    fi
}

# Function to log messages
log_msg() {
    local msg="$1"
    echo "$(date) | AZURE-MANA: $msg" >> "$LOGFILE"
}

# Function to clean up resources
cleanup() {
    local exit_code=${1:-0}
    rm -f "$LOCKFILE"
    exit "$exit_code"
}

# Validate prerequisites
require_commands
check_root
verify_device

# Initialize log file if it doesn't exist
if [[ ! -f "$LOGFILE" ]]; then
    touch "$LOGFILE" || {
        echo "AZURE-MANA: ERROR - Cannot create log file: $LOGFILE" >&2
        exit 1
    }
    log_msg "Log file created"
fi

# Ensure only one instance of the script runs
if [[ -f "$LOCKFILE" ]]; then
    PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        echo "AZURE-MANA: Script is already running with PID $PID. Exiting."
        exit 1
    else
        log_msg "Stale lock file detected. Removing it."
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"
trap "cleanup 0" EXIT
trap "cleanup 1" INT TERM

while true; do

    # Check if interface is up
    if ! ip link show "$DEVICE" > /dev/null 2>&1; then
        log_msg "INTERFACE $DEVICE DRIVER IS DOWN. RELOADING DRIVER."
        modprobe mana
    else
        log_msg "INTERFACE $DEVICE is UP. PROCEEDING WITH CHECK."
    fi

    RELOAD_NEEDED=false

    # Check each counter for non-zero values
    for COUNTER in "${COUNTERS[@]}"; do
        COUNT=$(ethtool -S "$DEVICE" 2>/dev/null | grep "^\s*$COUNTER:" | awk '{print $2}')
        
        if [[ -z "$COUNT" ]]; then
            log_msg "Unable to retrieve $COUNTER for $DEVICE. Skipping this counter."
        elif [[ $COUNT -gt 0 ]]; then
            log_msg "$COUNTER is $COUNT for $DEVICE, reloading MANA driver"
            RELOAD_NEEDED=true
        fi
    done

    # Reload driver if any counter was non-zero
    if [[ "$RELOAD_NEEDED" == true ]]; then
        log_msg "Counter increase detected, reloading MANA driver"

        # Unload mana_ib first (depends on mana)
        if lsmod | grep -q "^mana_ib"; then
            rmmod mana_ib || {
                log_msg "ERROR - Failed to unload mana_ib module. Exiting."
                cleanup 1
            }
        fi

        # Unload mana
        if lsmod | grep -q "^mana"; then
            rmmod mana || {
                log_msg "ERROR - Failed to unload mana module. Exiting."
                cleanup 1
            }
        fi

        # Reload mana first
        modprobe mana || {
            log_msg "ERROR - Failed to load mana module. Exiting."
            cleanup 1
        }

        # Then reload mana_ib
        modprobe mana_ib || {
            log_msg "ERROR - Failed to load mana_ib module. Exiting."
            cleanup 1
        }
    fi

    sleep "$CHECK_INTERVAL"

done
