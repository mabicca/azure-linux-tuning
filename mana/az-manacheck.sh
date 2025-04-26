#!/bin/bash
# AZ Mana Check
# Script configuration
COUNTERS=("tx_cqe_unknown_type" "rx_cqe_unknown_type")
DEVICE="eth1"
LOCKFILE="/var/tmp/monitor_script.lock"
LOGFILE="/var/log/az-mana.log"

# Function to clean up resources
cleanup() {
    echo "Cleaning up and exiting..."
    rm -f "$LOCKFILE"
    exit 1
}

# Ensure only one instance of the script runs
if [ -f "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE")
    if ps -p "$PID" > /dev/null 2>&1; then
        echo "AZURE-MANA: Script is already running with PID $PID. Exiting."
        exit 1
    else
        echo "AZURE-MANA: Stale lock file detected. Removing it."
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"
trap cleanup INT TERM EXIT

if [ ! -f "$LOGFILE" ]; then
    echo "LOGFILE missing. Creating LOGFILE ..."
    touch "$LOGFILE"
else
    echo "LOGFILE already exists."
fi

while true; do

    # Initial checks and reload driver if necessary
    if ! ip link show eth1 > /dev/null 2>&1; then
        echo "$(date) | AZURE-MANA: INTERFACE ETH1 DRIVER IS DOWN. RELOADLING DRIVER." >> $LOGFILE
        modprobe mana
        else
           echo "$(date) | AZURE-MANA: INTERFACE ETH1 is UP. PROCEEDING WITH CHECK."  >> $LOGFILE
    fi

    RELOAD_NEEDED=false

    for COUNTER in "${COUNTERS[@]}"; do
        COUNT=$(ethtool -S "$DEVICE" | grep "^\s*$COUNTER:" | awk '{print $2}')
        if [ "$COUNT" != "" ]; then
            if [ "$COUNT" -gt 0 ]; then
                echo "$(date) | AZURE-MANA: $0: $COUNTER is $COUNT for $DEVICE, reloading MANA driver" >> $LOGFILE
                RELOAD_NEEDED=true
            fi
        else
            echo "$(date) | AZURE-MANA: $0: Unable to retrieve $COUNTER for $DEVICE. Skipping this counter." >> $LOGFILE
        fi

    done

    if [ "$RELOAD_NEEDED" = true ]; then
        echo "$(date) | AZURE-MANA: $0: Counter increase detected, reloading MANA driver" >> $LOGFILE

        # Check and unload modules if loaded
        if lsmod | grep -q "^mana_ib"; then
            rmmod mana_ib || {
                echo "$(date) | AZURE-MANA: $0: Failed to unload mana_ib module. Exiting." >> $LOGFILE
                cleanup
            }
        fi

        if lsmod | grep -q "^mana"; then
            rmmod mana || {
                echo "$(date) | AZURE-MANA: $0: Failed to unload mana module. Exiting." >> $LOGFILE
                cleanup
            }
        fi

        # Reload modules and check success
        modprobe mana || {
            echo "$(date) | AZURE-MANA: $0: Failed to load mana module. Exiting." >> $LOGFILE
            cleanup
        }

        modprobe mana_ib || {
            echo "$(date) | AZURE-MANA: $0: Failed to load mana_ib module. Exiting." >> $LOGFILE
            cleanup
        }
    fi

sleep 20

done
