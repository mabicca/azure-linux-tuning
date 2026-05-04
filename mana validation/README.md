# MANA Validation Script

This folder contains a diagnostic script to validate Microsoft Azure Network Adapter (MANA) status on Azure Linux VMs.

## File

- mana-validate.sh: validates whether the VM is MANA-capable and whether MANA is currently active.

## What the script checks

The script runs a multi-section validation flow:

1. OS and kernel information
2. PCI device inspection (including Virtual Function detection)
3. Loaded kernel modules (mana, hv_netvsc)
4. Driver files on disk (including built-in modules)
5. Network interface inventory
6. Interface driver mapping via ethtool -i
7. Ring buffer query results via ethtool -g
8. Recent kernel log signals from dmesg
9. Final capability and runtime classification

It finishes with a summary and an exit code that automation can consume.

## Requirements

Minimum:

- bash
- ip (iproute2)
- uname, grep, awk, cut, find

Optional but recommended tools:

- ethtool (driver and ring-buffer checks)
- pciutils (lspci checks)
- kmod tools (lsmod checks)

Without optional tools, the script still runs, but those sections are marked as skipped.

## Usage

Run directly to stdout:

    ./mana-validate.sh

Write output to log file:

    ./mana-validate.sh --log

When executed as Azure Custom Script Extension, logging is enabled automatically.

## Logging

When logging is enabled (with --log or Custom Script Extension), output is appended to:

- /var/log/mana-validate.log

## Exit codes

- 0: MANA driver active
- 10: MANA-capable system, but Accelerated Networking not active
- 20: Not MANA-capable (or no MANA evidence found)
- 30: NetVSC fallback path in use
- 40: MANA present, possible VF binding issue
- 50: Inconclusive state

## Output interpretation

- MANA Capable tells whether the OS/kernel/driver evidence supports MANA.
- Classification tells current runtime state (for example, MANA driver ACTIVE).
- Active Driver shows which path is currently driving traffic (mana or hv_netvsc).
- Ring Buffer section is informational. For some drivers, not-supported behavior is expected.

## Notes and caveats

- Driver evidence is prioritized over kernel-version heuristics. This avoids false negatives on distros with backported MANA support.
- If MANA is detected as active, the script treats Accelerated Networking as enabled even if VF PCI detection is inconsistent.
- ANSI colors are used for readability in terminal output.

## Troubleshooting quick checks

If results look inconsistent:

1. Confirm interface drivers:

       ethtool -i <interface>

2. Check MANA module state:

       lsmod | grep -E '^mana|hv_netvsc'

3. Review recent kernel messages:

       dmesg | grep -iE 'mana|hv_netvsc'

4. Run script with logging and compare across reboots:

       ./mana-validate.sh --log

## Typical automation pattern

Use the exit code in CI, cloud-init, or configuration management:

- success path on exit code 0
- warning/remediation path on 10, 30, or 40
- fail path on 20 or 50
