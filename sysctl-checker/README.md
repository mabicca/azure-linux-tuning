# sysctl-checker

Scans sysctl configuration files for **duplicate parameters** and reports effective load order so you can quickly identify which definition wins and which ones are silently overridden.

## What it checks

| Path | Load order |
|------|------------|
| `/usr/lib/sysctl.d/*.conf` | Considered first (lowest priority) |
| `/usr/local/lib/sysctl.d/*.conf` | Higher priority than `/usr/lib` |
| `/run/sysctl.d/*.conf` | Higher priority than `/usr/local/lib` |
| `/etc/sysctl.d/*.conf` | Highest priority among `sysctl.d` directories |
| `/etc/sysctl.conf` | Applied last |

Within `sysctl.d`, files are resolved by basename.
If the same filename exists in multiple directories (for example `99-custom.conf`), only the one from the highest-priority directory is active.
The active files are then processed in lexicographic filename order.

The last definition of a key is the **effective** value applied by the kernel, matching the behaviour of `sysctl --system`.

## Usage

```bash
# Basic duplicate check
sudo bash sysctl-check.sh

# Duplicate check + full list of effective values
sudo bash sysctl-check.sh --all

# Include Azure recommendation compliance check
sudo bash sysctl-check.sh --check-azure

# Check currently applied runtime values via sysctl -a
sudo bash sysctl-check.sh --check-azure-live

# Generate a file with Azure recommendations that are missing or mismatched
sudo bash sysctl-check.sh --check-azure --write-missing-azure

# Same, but write to a custom path
sudo bash sysctl-check.sh --check-azure --write-missing-azure-file /tmp/azure-missing.conf

# Optional: custom rollback backup path for --write-missing-azure
sudo bash sysctl-check.sh --check-azure --write-missing-azure --write-missing-azure-backup-file /tmp/azure-missing-rollback.conf

# Optional: custom rollback backup path for --check-azure-live differences
sudo bash sysctl-check.sh --check-azure-live --write-azure-live-backup-file /tmp/azure-live-rollback.conf

# Optional: custom backup path for duplicate-line pruning done by -W
sudo bash sysctl-check.sh --check-azure --write-missing-azure --write-duplicate-backup-file /tmp/azure-duplicate-pruned.backup

# Show help and all available options
bash sysctl-check.sh --help
```

`sudo` is not strictly required for reading the files, but some paths under `/run/` may be root-only.
To write under `/etc/sysctl.d`, run with `sudo`.

When scanning `/etc` with `--dir /etc`, only `/etc/sysctl.conf` and `/etc/sysctl.d/*.conf` are considered.

## New option: generate missing Azure recommendations

When `--write-missing-azure` is provided, the script writes Azure-recommended keys that are either missing or mismatched to:

- `/etc/sysctl.d/99-azure-missing-recommendations.conf`

In `--dir <path>` mode, the default output is written inside the target tree:

- `<path>/etc/sysctl.d/99-azure-missing-recommendations.conf` (if that directory exists), otherwise
- `<path>/sysctl.d/99-azure-missing-recommendations.conf`

If no recommendations are missing or mismatched, no file is written.

Use `--write-missing-azure-file <path>` to write to an alternate path.

When this file is generated, the script also creates a rollback
backup file containing current runtime values for those changed keys.

Default rollback path:

- `<output-without-.conf>.<UTC timestamp>.backup`

Example:

- `/etc/sysctl.d/99-azure-missing-recommendations.20260529-201500.backup`

Override it with `--write-missing-azure-backup-file <path>`.

When `--write-missing-azure` is used, the script also prunes overridden
duplicate parameter definitions in writable admin scope:

- System mode: files under `/etc`
- `--dir` mode: files under the target directory

Removed lines are backed up automatically.

Default duplicate-pruning backup path:

- `./sysctl-duplicate-pruned.<UTC timestamp>.backup`

Override with `--write-duplicate-backup-file <path>`.

## Live runtime validation

Use `--check-azure-live` to compare Azure recommendations against the current
kernel runtime values from `sysctl -a`.

This is useful when external tooling (for example SAPTune) applies values
outside the scanned config files.

When live differences are found, the script writes a rollback backup file for
mismatched keys using current runtime values.

Default rollback path:

- `./sysctl-azure-live-rollback.<UTC timestamp>.backup`

Override it with `--write-azure-live-backup-file <path>`.

## Sample output

```
=== sysctl config checker ===

Files scanned (in load order):
   1. /usr/lib/sysctl.d/50-default.conf
   2. /etc/sysctl.d/99-azure-tuned.conf
   3. /etc/sysctl.conf

=== Duplicate parameters ===
[DUP] net.core.rmem_max
      (overridden)  /usr/lib/sysctl.d/50-default.conf:12 = 212992
      (effective)   /etc/sysctl.d/99-azure-tuned.conf:5 = 16777216

  Total duplicate keys: 1
```

## Exit code

| Code | Meaning |
|------|---------|
| `0`  | No duplicates detected |
| `1`  | One or more duplicate parameters found |
| `2`  | Usage/runtime/write error (`sysctl` unavailable, bad args, backup/write failure) |

A non-zero exit code makes it easy to integrate into CI pipelines or image-build validation steps.

## README consistency check

The repository includes an automated check that verifies every long option in
`sysctl-check.sh` is mentioned in this README.

Run it locally:

```bash
bash .github/scripts/check-sysctl-checker-readme-flags.sh
```
