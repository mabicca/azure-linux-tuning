#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="sysctl-checker/sysctl-check.sh"
README_PATH="sysctl-checker/README.md"

if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "Error: $SCRIPT_PATH not found." >&2
    exit 2
fi

if [[ ! -f "$README_PATH" ]]; then
    echo "Error: $README_PATH not found." >&2
    exit 2
fi

# Extract long options from the argument parser case block.
mapfile -t long_flags < <(
    awk '/while \[\[ \$# -gt 0 \]\]; do/,/esac/' "$SCRIPT_PATH" \
        | grep -oE -- '--[a-z0-9][a-z0-9-]*' \
        | sort -u
)

if [[ ${#long_flags[@]} -eq 0 ]]; then
    echo "Error: no long flags found in $SCRIPT_PATH parser block." >&2
    exit 2
fi

missing=()
for flag in "${long_flags[@]}"; do
    if ! grep -Fq -- "$flag" "$README_PATH"; then
        missing+=("$flag")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "README option coverage check failed." >&2
    echo "Missing flags in $README_PATH:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "README option coverage check passed."
echo "Checked ${#long_flags[@]} long flags from $SCRIPT_PATH against $README_PATH."
