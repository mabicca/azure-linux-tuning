#!/usr/bin/env bash
# sysctl-check.sh — Scans sysctl config files for duplicate parameters and
# reports effective load order (last definition wins).
#
# By default scans the standard system paths following sysctl.d precedence:
# /usr/lib/sysctl.d, /usr/local/lib/sysctl.d, /run/sysctl.d, /etc/sysctl.d,
# with same-basename files masked by higher-priority directories.
# /etc/sysctl.conf is processed last.
# Use --dir <path> to scan an arbitrary folder instead.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Disable colors when not writing to a terminal (e.g. piped/redirected output)
[[ -t 1 ]] || { RED=''; YELLOW=''; GREEN=''; CYAN=''; BLUE=''; MAGENTA=''; WHITE=''; DIM=''; BOLD=''; RESET=''; }

# --------------------------------------------------------------------------- #
# Collect config files in the order the kernel applies them                   #
# --------------------------------------------------------------------------- #

# Build merged sysctl.d file list from directories.
#
# Rules mirrored from sysctl.d behavior:
#   1) If the same basename exists in multiple directories, keep only the
#      file from the highest-priority directory.
#   2) Sort the resulting active files lexicographically by basename.
collect_merged_sysctld_files() {
    local -n _dirs="$1"
    local -A chosen=()      # basename -> full path
    local -a basenames=()

    local dir f base
    for dir in "${_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            base="${f##*/}"
            if [[ ! -v chosen["$base"] ]]; then
                chosen["$base"]="$f"
                basenames+=("$base")
            fi
        done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)
    done

    if [[ ${#basenames[@]} -gt 0 ]]; then
        while IFS= read -r base; do
            printf '%s\n' "${chosen[$base]}"
        done < <(printf '%s\n' "${basenames[@]}" | sort -u)
    fi
}

# System mode: standard paths, standard load order
collect_system_files() {
    local files=()
    local -a dirs=(
        /etc/sysctl.d
        /run/sysctl.d
        /usr/local/lib/sysctl.d
        /usr/lib/sysctl.d
    )

    # 1. Active sysctl.d files (basename masking + lexicographic order)
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        files+=("$f")
    done < <(collect_merged_sysctld_files dirs)

    # 2. /etc/sysctl.conf (processed last)
    [[ -f /etc/sysctl.conf ]] && files+=("/etc/sysctl.conf")

    printf '%s\n' "${files[@]+"${files[@]}"}"
}

# Directory mode: collect *.conf files under <path> in sysctl-like load order:
#   1. Active files from these roots, merged by basename and sorted by name:
#        <path>/etc/sysctl.d
#        <path>/sysctl.d
#        <path>/run/sysctl.d
#        <path>/usr/local/lib/sysctl.d
#        <path>/usr/lib/sysctl.d
#   2. <path>/etc/sysctl.conf or <path>/sysctl.conf (last)
#   3. Any remaining *.conf not already listed (sorted by full path)
collect_dir_files() {
    local dir="${1%/}"   # strip trailing slash
    [[ -z "$dir" ]] && dir="/"
    local -a seen=()
    local -a out=()
    local dir_base="${dir##*/}"
    local scan_is_etc_root=false
    [[ "$dir" == "/etc" || "$dir_base" == "etc" ]] && scan_is_etc_root=true
    local -a roots=(
        "${dir}/etc/sysctl.d"
        "${dir}/sysctl.d"
        "${dir}/run/sysctl.d"
        "${dir}/usr/local/lib/sysctl.d"
        "${dir}/usr/lib/sysctl.d"
    )

    _add_file() {
        local f="$1"
        # Skip if already added
        local x
        for x in "${seen[@]+"${seen[@]}"}"; do [[ "$x" == "$f" ]] && return; done
        seen+=("$f")
        out+=("$f")
    }

    # 1. Active files from sysctl.d-style roots
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        _add_file "$f"
    done < <(collect_merged_sysctld_files roots)

    # 2. sysctl.conf (last)
    # Prefer rootfs-style <path>/etc/sysctl.conf when present.
    [[ -f "${dir}/etc/sysctl.conf" ]] && _add_file "${dir}/etc/sysctl.conf"
    [[ -f "${dir}/sysctl.conf" ]] && _add_file "${dir}/sysctl.conf"

    # 3. Any other *.conf files outside known sysctl.d roots
    #    (avoid re-adding masked lower-priority files).
    #    Special case: when scanning an /etc tree directly, do not scan
    #    unrelated /etc/*.conf files (e.g. waagent.conf).
    if ! $scan_is_etc_root; then
        while IFS= read -r -d '' f; do
            _add_file "$f"
        done < <(
            find "$dir" \
                \( -path "${dir}/etc" -o -path "${dir}/sysctl.d" -o -path "${dir}/run/sysctl.d" -o -path "${dir}/usr/local/lib/sysctl.d" -o -path "${dir}/usr/lib/sysctl.d" \) -prune \
                -o -type f -name '*.conf' -print0 2>/dev/null | sort -z
        )
    fi

    printf '%s\n' "${out[@]+"${out[@]}"}"
}

# --------------------------------------------------------------------------- #
# Parse a single file — emit "key<TAB>value<TAB>file<TAB>lineno" per param    #
# --------------------------------------------------------------------------- #
parse_file() {
    local file="$1"
    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++)) || true
        # Strip inline comments and blank lines
        line="${line%%#*}"
        line="${line%%\;*}"
        # Collapse whitespace around the = sign but keep value intact
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_./-]+)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            # Trim trailing whitespace from value
            val="${val%"${val##*[![:space:]]}"}"
            printf '%s\t%s\t%s\t%d\n' "$key" "$val" "$file" "$lineno"
        fi
    done < "$file"
}

# --------------------------------------------------------------------------- #
# Accumulate entries from a list of files                                      #
# Populates the caller's key_entries associative array                         #
# --------------------------------------------------------------------------- #
accumulate() {
    local -n _files="$1"         # nameref: array of file paths
    local -n _key_entries="$2"   # nameref: associative array key -> entries

    for f in "${_files[@]}"; do
        while IFS=$'\t' read -r key val file lineno; do
            local entry="${file}:${lineno}=${val}"
            if [[ -v _key_entries["$key"] ]]; then
                _key_entries["$key"]+=$'\n'"${entry}"
            else
                _key_entries["$key"]="${entry}"
            fi
        done < <(parse_file "$f")
    done
}

# --------------------------------------------------------------------------- #
# Report: duplicates                                                           #
# --------------------------------------------------------------------------- #
report_duplicates() {
    local -n _ke="$1"
    local dup_count=0

    echo -e "${CYAN}${BOLD}┌─ Duplicate parameters ──────────────────────────────────────────┐${RESET}"
    echo

    while IFS= read -r key; do
        local raw="${_ke[$key]}"
        local total
        total=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
        if (( total > 1 )); then
            ((dup_count++)) || true
            echo -e "  ${YELLOW}${BOLD}⚠  ${key}${RESET}  ${DIM}(${total} definitions)${RESET}"
            local i=0
            while IFS= read -r entry; do
                ((i++)) || true
                local loc="${entry%%=*}"
                local file_part="${loc%:*}"
                local line_part="${loc##*:}"
                local val="${entry#*=}"
                if (( i == total )); then
                    echo -e "     ${GREEN}${BOLD}✔ effective ${RESET} ${DIM}${file_part}${RESET}${DIM}:${line_part}${RESET}  =  ${GREEN}${val}${RESET}"
                else
                    echo -e "     ${RED}✘ overridden${RESET} ${DIM}${file_part}${RESET}${DIM}:${line_part}${RESET}  =  ${RED}${val}${RESET}"
                fi
            done <<< "$raw"
            echo
        fi
    done < <(printf '%s\n' "${!_ke[@]}" | sort)

    if (( dup_count == 0 )); then
        echo -e "  ${GREEN}${BOLD}✔  No duplicates found.${RESET}"
        echo
    else
        echo -e "  ${YELLOW}${BOLD}Total duplicate keys: ${dup_count}${RESET}"
        echo
    fi

    return $(( dup_count > 0 ? 1 : 0 ))
}

# --------------------------------------------------------------------------- #
# Report: full parameter rundown                                               #
# --------------------------------------------------------------------------- #
report_all() {
    local -n _ke="$1"
    local total_keys=0

    echo -e "${CYAN}${BOLD}┌─ Effective parameter values ────────────────────────────────────┐${RESET}"
    echo

    # Group keys by top-level namespace (e.g. net, vm, kernel, fs, …)
    local prev_ns=""
    while IFS= read -r key; do
        local ns="${key%%.*}"
        if [[ "$ns" != "$prev_ns" ]]; then
            [[ -n "$prev_ns" ]] && echo
            echo -e "  ${MAGENTA}${BOLD}[ ${ns} ]${RESET}"
            prev_ns="$ns"
        fi

        local raw="${_ke[$key]}"
        local effective
        effective=$(printf '%s\n' "$raw" | tail -n1)
        local loc="${effective%%=*}"
        local file_part="${loc%:*}"
        local line_part="${loc##*:}"
        local val="${effective#*=}"
        local def_count
        def_count=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')

        local val_color="${GREEN}"
        local dup_marker=""
        if (( def_count > 1 )); then
            val_color="${YELLOW}"
            dup_marker="  ${YELLOW}${BOLD}[dup x${def_count}]${RESET}"
        fi

        printf "    ${CYAN}%-48s${RESET} ${WHITE}=${RESET} ${val_color}%-20s${RESET}  ${DIM}%s:%s${RESET}%b\n" \
            "$key" "$val" "$file_part" "$line_part" "$dup_marker"
        ((total_keys++)) || true
    done < <(printf '%s\n' "${!_ke[@]}" | sort)

    echo
    echo -e "  ${BOLD}Total parameters: ${WHITE}${total_keys}${RESET}"
    echo
}

# --------------------------------------------------------------------------- #
# Azure recommended sysctl values                                              #
# Source: https://ale-network-performance                                       #
# --------------------------------------------------------------------------- #
declare -A AZURE_RECOMMENDED=(
    # Network buffer settings
    [net.ipv4.tcp_mem]="4096 87380 67108864"
    [net.ipv4.udp_mem]="4096 87380 33554432"
    [net.ipv4.tcp_rmem]="4096 87380 67108864"
    [net.ipv4.tcp_wmem]="4096 65536 67108864"
    [net.core.rmem_default]="33554432"
    [net.core.wmem_default]="33554432"
    [net.ipv4.udp_wmem_min]="16384"
    [net.ipv4.udp_rmem_min]="16384"
    [net.core.wmem_max]="134217728"
    [net.core.rmem_max]="134217728"
    [net.core.busy_poll]="50"
    [net.core.busy_read]="50"
    # Congestion control
    [net.ipv4.tcp_congestion_control]="bbr"
    # Extra TCP / network parameters
    [net.ipv4.tcp_timestamps]="1"
    [net.ipv4.tcp_tw_reuse]="1"
    [net.ipv4.ip_local_port_range]="1024 65535"
    [net.core.netdev_budget]="1000"
    [net.core.optmem_max]="65535"
    [net.ipv4.tcp_frto]="0"
    [net.core.somaxconn]="32768"
    [net.core.netdev_max_backlog]="32768"
    [net.core.dev_weight]="64"
    # Queue discipline
    [net.core.default_qdisc]="fq"
)

# Category labels shown next to each parameter in the Azure report
declare -A AZURE_CATEGORY=(
    [net.ipv4.tcp_mem]="buffer"
    [net.ipv4.udp_mem]="buffer"
    [net.ipv4.tcp_rmem]="buffer"
    [net.ipv4.tcp_wmem]="buffer"
    [net.core.rmem_default]="buffer"
    [net.core.wmem_default]="buffer"
    [net.ipv4.udp_wmem_min]="buffer"
    [net.ipv4.udp_rmem_min]="buffer"
    [net.core.wmem_max]="buffer"
    [net.core.rmem_max]="buffer"
    [net.core.busy_poll]="buffer"
    [net.core.busy_read]="buffer"
    [net.ipv4.tcp_congestion_control]="congestion"
    [net.ipv4.tcp_timestamps]="tcp"
    [net.ipv4.tcp_tw_reuse]="tcp"
    [net.ipv4.ip_local_port_range]="tcp"
    [net.core.netdev_budget]="tcp"
    [net.core.optmem_max]="tcp"
    [net.ipv4.tcp_frto]="tcp"
    [net.core.somaxconn]="tcp"
    [net.core.netdev_max_backlog]="tcp"
    [net.core.dev_weight]="tcp"
    [net.core.default_qdisc]="qdisc"
)

# Populated by report_azure_check (ordered list of missing recommendation keys)
declare -a AZURE_MISSING_KEYS=()
declare -a AZURE_NONCOMPLIANT_KEYS=()
# Populated by report_azure_live_check
declare -a AZURE_LIVE_DIFF_KEYS=()
declare -a AZURE_LIVE_MISSING_KEYS=()

# Normalize whitespace in a value for comparison (collapse runs of spaces/tabs)
normalize_val() { printf '%s' "$*" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'; }

# Build backup file path with UTC timestamp and .backup suffix.
# Examples:
#   /etc/sysctl.d/99-azure.conf -> /etc/sysctl.d/99-azure.20260529-201500.backup
#   ./sysctl-azure-live-rollback -> ./sysctl-azure-live-rollback.20260529-201500.backup
build_backup_file_path() {
    local base_path="$1"
    local ts
    ts="$(date -u '+%Y%m%d-%H%M%S')"

    # Normalize input by removing trailing .conf/.backup when present.
    base_path="${base_path%.conf}"
    base_path="${base_path%.backup}"

    printf '%s.%s.backup\n' "$base_path" "$ts"
}

# Remove overridden duplicate definitions from writable admin config files and
# write a rollback backup containing the removed lines.
#
# Scope rules:
#   - system mode: only files under /etc are modified
#   - --dir mode: only files under <dir> are modified
prune_duplicate_parameters() {
    local -n _ke="$1"
    local backup_file="$2"
    local target_dir="${3:-}"

    local scope_prefix
    if [[ -n "$target_dir" ]]; then
        scope_prefix="${target_dir%/}/"
    else
        scope_prefix="/etc/"
    fi

    local -a prune_entries=()   # file<TAB>line<TAB>key<TAB>value
    local key raw total i entry loc file_part line_part val

    while IFS= read -r key; do
        raw="${_ke[$key]}"
        total=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
        if (( total > 1 )); then
            i=0
            while IFS= read -r entry; do
                ((i++)) || true
                (( i == total )) && continue  # keep effective (last) definition

                loc="${entry%%=*}"
                file_part="${loc%:*}"
                line_part="${loc##*:}"
                val="${entry#*=}"

                if [[ "$file_part" == "$scope_prefix"* ]]; then
                    prune_entries+=("${file_part}"$'\t'"${line_part}"$'\t'"${key}"$'\t'"${val}")
                fi
            done <<< "$raw"
        fi
    done < <(printf '%s\n' "${!_ke[@]}" | sort)

    if [[ ${#prune_entries[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✔  No removable duplicate definitions found in scope (${scope_prefix}).${RESET}"
        echo
        return 0
    fi

    local backup_dir
    backup_dir="$(dirname "$backup_file")"
    if [[ ! -d "$backup_dir" ]]; then
        echo -e "${RED}Error: duplicate-backup directory '$backup_dir' does not exist.${RESET}" >&2
        return 2
    fi

    local backup_tmp="${backup_file}.tmp.$$"
    {
        echo "# Duplicate-removal backup generated by sysctl-check.sh"
        echo "# Date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# Scope: ${scope_prefix}"
        echo "# Removed lines are listed below as file:line with original content."
        echo
    } > "$backup_tmp" || {
        rm -f "$backup_tmp" 2>/dev/null || true
        echo -e "${RED}Error: failed to create duplicate backup temp file '$backup_tmp'.${RESET}" >&2
        return 2
    }

    local -A file_lines=()  # file -> newline-separated line numbers
    local rec f ln txt
    for rec in "${prune_entries[@]}"; do
        IFS=$'\t' read -r f ln _ _ <<< "$rec"
        if [[ -v file_lines["$f"] ]]; then
            file_lines["$f"]+=$'\n'"$ln"
        else
            file_lines["$f"]="$ln"
        fi
    done

    local removed_count=0
    for rec in "${prune_entries[@]}"; do
        IFS=$'\t' read -r f ln key val <<< "$rec"
        txt="$(sed -n "${ln}p" "$f" 2>/dev/null || true)"
        printf '%s:%s\t%s\n' "$f" "$ln" "$txt" >> "$backup_tmp"
        ((removed_count++)) || true
    done

    if ! mv "$backup_tmp" "$backup_file"; then
        rm -f "$backup_tmp" 2>/dev/null || true
        echo -e "${RED}Error: failed to write duplicate backup '$backup_file'.${RESET}" >&2
        return 2
    fi

    local -A skip_done=()
    local lines_csv tmpf
    for f in "${!file_lines[@]}"; do
        [[ -v skip_done["$f"] ]] && continue
        skip_done["$f"]=1

        if [[ ! -w "$f" ]]; then
            echo -e "  ${YELLOW}${BOLD}⚠  Skipping non-writable file:${RESET} ${DIM}${f}${RESET}"
            continue
        fi

        lines_csv="$(printf '%s\n' "${file_lines[$f]}" | sort -n | uniq | paste -sd, -)"
        tmpf="${f}.tmp.$$"

        if ! awk -v lines="$lines_csv" '
            BEGIN {
                split(lines, a, ",")
                for (i in a) rm[a[i]] = 1
            }
            !(FNR in rm) { print }
        ' "$f" > "$tmpf"; then
            rm -f "$tmpf" 2>/dev/null || true
            echo -e "${RED}Error: failed processing duplicate removal for '$f'.${RESET}" >&2
            return 2
        fi

        if ! cat "$tmpf" > "$f"; then
            rm -f "$tmpf" 2>/dev/null || true
            echo -e "${RED}Error: failed writing duplicate-pruned file '$f'.${RESET}" >&2
            return 2
        fi
        rm -f "$tmpf" 2>/dev/null || true
    done

    echo -e "  ${GREEN}${BOLD}✔  Removed overridden duplicate definitions:${RESET} ${WHITE}${removed_count}${RESET}"
    echo -e "  ${GREEN}${BOLD}✔  Wrote duplicate-removal backup:${RESET} ${BLUE}${backup_file}${RESET}"
    echo
    return 0
}

# Collect effective runtime values from `sysctl -a`.
collect_runtime_sysctl_values() {
    local -n _runtime="$1"

    if ! command -v sysctl >/dev/null 2>&1; then
        echo -e "${RED}Error: 'sysctl' command not found for --check-azure-live.${RESET}" >&2
        return 2
    fi

    local line key val
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_./-]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="$(normalize_val "$val")"
        _runtime["$key"]="$val"
    done < <(sysctl -a 2>/dev/null)

    return 0
}

# --------------------------------------------------------------------------- #
# Report: Azure recommendation compliance                                      #
# --------------------------------------------------------------------------- #
report_azure_check() {
    local -n _ke="$1"
    local ok=0 mismatch=0 missing=0
    local prev_cat=""
    AZURE_MISSING_KEYS=()
    AZURE_NONCOMPLIANT_KEYS=()

    echo -e "${CYAN}${BOLD}┌─ Azure recommendation check ────────────────────────────────────┐${RESET}"
    echo -e "  ${DIM}Source: ale-network-performance${RESET}"
    echo

    while IFS= read -r key; do
        local rec_val="${AZURE_RECOMMENDED[$key]}"
        local cat="${AZURE_CATEGORY[$key]:-other}"

        # Print category header when it changes
        if [[ "$cat" != "$prev_cat" ]]; then
            [[ -n "$prev_cat" ]] && echo
            echo -e "  ${MAGENTA}${BOLD}[ ${cat} ]${RESET}"
            prev_cat="$cat"
        fi

        if [[ ! -v _ke[$key] ]]; then
            # Parameter not found in any config file
            printf "    ${RED}%-48s${RESET}  ${RED}${BOLD}MISSING${RESET}   recommended = ${WHITE}%s${RESET}\n" \
                "$key" "$rec_val"
            AZURE_MISSING_KEYS+=("$key")
            AZURE_NONCOMPLIANT_KEYS+=("$key")
            ((missing++)) || true
        else
            local raw="${_ke[$key]}"
            local effective
            effective=$(printf '%s\n' "$raw" | tail -n1)
            local actual_val="${effective#*=}"
            local loc="${effective%%=*}"
            local file_part="${loc%:*}"
            local line_part="${loc##*:}"

            local norm_actual norm_rec
            norm_actual=$(normalize_val "$actual_val")
            norm_rec=$(normalize_val "$rec_val")

            if [[ "$norm_actual" == "$norm_rec" ]]; then
                printf "    ${GREEN}%-48s${RESET}  ${GREEN}${BOLD}OK${RESET}        value = ${GREEN}%s${RESET}  ${DIM}%s:%s${RESET}\n" \
                    "$key" "$actual_val" "$file_part" "$line_part"
                ((ok++)) || true
            else
                printf "    ${YELLOW}%-48s${RESET}  ${YELLOW}${BOLD}MISMATCH${RESET}  actual = ${YELLOW}%s${RESET}  recommended = ${WHITE}%s${RESET}  ${DIM}%s:%s${RESET}\n" \
                    "$key" "$actual_val" "$rec_val" "$file_part" "$line_part"
                AZURE_NONCOMPLIANT_KEYS+=("$key")
                ((mismatch++)) || true
            fi
        fi
    done < <(printf '%s\n' "${!AZURE_RECOMMENDED[@]}" | sort)

    local total=$(( ok + mismatch + missing ))
    echo
    echo -e "  ${BOLD}Results  —  ${GREEN}OK: ${ok}${RESET}  ${YELLOW}${BOLD}MISMATCH: ${mismatch}${RESET}  ${RED}${BOLD}MISSING: ${missing}${RESET}  ${DIM}(${total} checked)${RESET}"
    echo

    return $(( (mismatch + missing) > 0 ? 1 : 0 ))
}

# --------------------------------------------------------------------------- #
# Report: Azure recommendation compliance against live runtime values          #
# --------------------------------------------------------------------------- #
report_azure_live_check() {
    local -n _rt="$1"
    local ok=0 mismatch=0 missing=0
    local prev_cat=""
    AZURE_LIVE_DIFF_KEYS=()
    AZURE_LIVE_MISSING_KEYS=()

    echo -e "${CYAN}${BOLD}┌─ Azure recommendation check (live sysctl -a) ──────────────────┐${RESET}"
    echo -e "  ${DIM}Source: ale-network-performance${RESET}"
    echo

    while IFS= read -r key; do
        local rec_val="${AZURE_RECOMMENDED[$key]}"
        local cat="${AZURE_CATEGORY[$key]:-other}"

        if [[ "$cat" != "$prev_cat" ]]; then
            [[ -n "$prev_cat" ]] && echo
            echo -e "  ${MAGENTA}${BOLD}[ ${cat} ]${RESET}"
            prev_cat="$cat"
        fi

        if [[ ! -v _rt[$key] ]]; then
            printf "    ${RED}%-48s${RESET}  ${RED}${BOLD}MISSING${RESET}   recommended = ${WHITE}%s${RESET}\n" \
                "$key" "$rec_val"
            AZURE_LIVE_MISSING_KEYS+=("$key")
            ((missing++)) || true
        else
            local actual_val="${_rt[$key]}"
            local norm_actual norm_rec
            norm_actual="$(normalize_val "$actual_val")"
            norm_rec="$(normalize_val "$rec_val")"

            if [[ "$norm_actual" == "$norm_rec" ]]; then
                printf "    ${GREEN}%-48s${RESET}  ${GREEN}${BOLD}OK${RESET}        value = ${GREEN}%s${RESET}\n" \
                    "$key" "$actual_val"
                ((ok++)) || true
            else
                printf "    ${YELLOW}%-48s${RESET}  ${YELLOW}${BOLD}MISMATCH${RESET}  actual = ${YELLOW}%s${RESET}  recommended = ${WHITE}%s${RESET}\n" \
                    "$key" "$actual_val" "$rec_val"
                AZURE_LIVE_DIFF_KEYS+=("$key")
                ((mismatch++)) || true
            fi
        fi
    done < <(printf '%s\n' "${!AZURE_RECOMMENDED[@]}" | sort)

    local total=$(( ok + mismatch + missing ))
    echo
    echo -e "  ${BOLD}Results  —  ${GREEN}OK: ${ok}${RESET}  ${YELLOW}${BOLD}MISMATCH: ${mismatch}${RESET}  ${RED}${BOLD}MISSING: ${missing}${RESET}  ${DIM}(${total} checked)${RESET}"
    echo

    return $(( (mismatch + missing) > 0 ? 1 : 0 ))
}

# --------------------------------------------------------------------------- #
# Write rollback backup file with current runtime values                      #
# --------------------------------------------------------------------------- #
write_rollback_backup_file() {
    local out_file="$1"
    local key_array_name="$2"
    local runtime_name="$3"
    local reason="$4"
    local -n _keys="$key_array_name"
    local -n _rt="$runtime_name"

    if [[ ${#_keys[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✔  No changed keys for rollback backup (${reason}).${RESET}"
        echo
        return 0
    fi

    local out_dir
    out_dir="$(dirname "$out_file")"
    if [[ ! -d "$out_dir" ]]; then
        echo -e "${RED}Error: backup directory '$out_dir' does not exist.${RESET}" >&2
        return 2
    fi

    local tmp_file="${out_file}.tmp.$$"
    {
        echo "# Rollback backup generated by sysctl-check.sh"
        echo "# Date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# Reason: ${reason}"
        echo "# Values below are current runtime values (sysctl -a)."
        echo

        local key wrote=0
        for key in "${_keys[@]}"; do
            if [[ -v _rt["$key"] ]]; then
                printf '%s = %s\n' "$key" "${_rt[$key]}"
                ((wrote++)) || true
            else
                printf '# %s is not present in current runtime sysctl output\n' "$key"
            fi
        done

        if (( wrote == 0 )); then
            echo "# No runtime values were available for changed keys."
        fi
    } > "$tmp_file" || {
        rm -f "$tmp_file" 2>/dev/null || true
        echo -e "${RED}Error: failed to write temporary backup file '$tmp_file'.${RESET}" >&2
        return 2
    }

    if ! mv "$tmp_file" "$out_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        echo -e "${RED}Error: failed to write rollback backup '$out_file'.${RESET}" >&2
        return 2
    fi

    echo -e "  ${GREEN}${BOLD}✔  Wrote rollback backup:${RESET} ${BLUE}${out_file}${RESET}"
    echo -e "  ${DIM}Keys captured: ${#_keys[@]}${RESET}"
    echo
    return 0
}

# --------------------------------------------------------------------------- #
# Write file with missing Azure recommendations                               #
# --------------------------------------------------------------------------- #
write_missing_azure_file() {
    local out_file="$1"
    local out_dir
    out_dir="$(dirname "$out_file")"

    if [[ ${#AZURE_NONCOMPLIANT_KEYS[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✔  No missing/mismatched Azure recommendations. No file written.${RESET}"
        echo
        return 0
    fi

    if [[ ! -d "$out_dir" ]]; then
        echo -e "${RED}Error: output directory '$out_dir' does not exist.${RESET}" >&2
        return 2
    fi

    local tmp_file="${out_file}.tmp.$$"
    {
        echo "# Generated by sysctl-check.sh --write-missing-azure"
        echo "# Date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# Contains Azure-recommended keys that were missing or mismatched"
        echo "# in the scanned configuration set at generation time."
        echo
        local key
        for key in "${AZURE_NONCOMPLIANT_KEYS[@]}"; do
            printf '%s = %s\n' "$key" "${AZURE_RECOMMENDED[$key]}"
        done
    } > "$tmp_file" || {
        rm -f "$tmp_file" 2>/dev/null || true
        echo -e "${RED}Error: failed to write temporary output file '$tmp_file'.${RESET}" >&2
        return 2
    }

    if ! mv "$tmp_file" "$out_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        echo -e "${RED}Error: failed to write '$out_file' (try sudo or choose a writable path).${RESET}" >&2
        return 2
    fi

    echo -e "  ${GREEN}${BOLD}✔  Wrote missing Azure recommendations:${RESET} ${BLUE}${out_file}${RESET}"
    echo -e "  ${DIM}Entries written: ${#AZURE_NONCOMPLIANT_KEYS[@]}${RESET}"
    echo
    return 0
}

# --------------------------------------------------------------------------- #
# Main                                                                         #
# --------------------------------------------------------------------------- #
usage() {
        cat <<'EOF'
Usage: sysctl-check.sh [OPTIONS] [PATH]

Arguments:
    PATH               Directory to scan (shorthand for --dir).

Options:
    -d, --dir <path>   Scan all *.conf files found under <path> (sorted by
                                         kernel load order) instead of the default system paths.
    -A, --check-azure  Compare config-effective values against Microsoft's Azure
                                         network tuning recommendations.
    -L, --check-azure-live
                                         Compare live runtime values from 'sysctl -a' against
                                         Azure recommendations.
    -W, --write-missing-azure
                                         Write missing/mismatched Azure recommendations to:
                                         /etc/sysctl.d/99-azure-missing-recommendations.conf
                                         (implies --check-azure).
    --write-missing-azure-file <path>
                                         Same as --write-missing-azure, but write to <path>.
    --write-missing-azure-backup-file <path>
                                         Write rollback backup for keys changed by
                                         --write-missing-azure (current runtime values).
                                         Default: <output-without-.conf>.<UTC timestamp>.backup
    --write-azure-live-backup-file <path>
                                         Write rollback backup for keys that differ in
                                         --check-azure-live. Default:
                                         ./sysctl-azure-live-rollback.<UTC timestamp>.backup
    --write-duplicate-backup-file <path>
                                         Backup file for lines removed by duplicate
                                         pruning during -W. Default:
                                         ./sysctl-duplicate-pruned.<UTC timestamp>.backup
    --all              Print the full effective parameter list in addition to
                                         the duplicate report. Implied when --dir / PATH is used.
    -h, --help         Show this help.

Default system paths (load order):
    Active files from /etc/sysctl.d, /run/sysctl.d,
    /usr/local/lib/sysctl.d, /usr/lib/sysctl.d
    (same basename in multiple dirs: higher-priority dir wins)
    /etc/sysctl.conf (last)

Exit codes:
      0  Clean (no duplicates and, if --check-azure, fully compliant)
      1  Issues found (duplicates or compliance failures)
      2  Usage or runtime/write error (bad args, missing path, sysctl unavailable,
          or file write failure)
EOF
}

TARGET_DIR=""
SHOW_ALL=false
CHECK_AZURE=false
CHECK_AZURE_LIVE=false
WRITE_MISSING_AZURE=false
AZURE_MISSING_OUT_FILE="/etc/sysctl.d/99-azure-missing-recommendations.conf"
AZURE_MISSING_OUT_FILE_EXPLICIT=false
AZURE_MISSING_BACKUP_OUT_FILE=""
AZURE_LIVE_BACKUP_OUT_FILE=""
DUPLICATE_BACKUP_OUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            [[ -z "${2:-}" ]] && { echo "Error: --dir requires a path argument." >&2; exit 2; }
            TARGET_DIR="$2"
            SHOW_ALL=true   # rundown is always shown in dir mode
            shift 2
            ;;
        -A|--check-azure) CHECK_AZURE=true; shift ;;
        -L|--check-azure-live) CHECK_AZURE_LIVE=true; shift ;;
        -W|--write-missing-azure)
            WRITE_MISSING_AZURE=true
            CHECK_AZURE=true
            shift
            ;;
        --write-missing-azure-file)
            [[ -z "${2:-}" ]] && { echo "Error: --write-missing-azure-file requires a path argument." >&2; exit 2; }
            AZURE_MISSING_OUT_FILE="$2"
            AZURE_MISSING_OUT_FILE_EXPLICIT=true
            WRITE_MISSING_AZURE=true
            CHECK_AZURE=true
            shift 2
            ;;
        --write-missing-azure-backup-file)
            [[ -z "${2:-}" ]] && { echo "Error: --write-missing-azure-backup-file requires a path argument." >&2; exit 2; }
            AZURE_MISSING_BACKUP_OUT_FILE="$2"
            shift 2
            ;;
        --write-azure-live-backup-file)
            [[ -z "${2:-}" ]] && { echo "Error: --write-azure-live-backup-file requires a path argument." >&2; exit 2; }
            AZURE_LIVE_BACKUP_OUT_FILE="$2"
            shift 2
            ;;
        --write-duplicate-backup-file)
            [[ -z "${2:-}" ]] && { echo "Error: --write-duplicate-backup-file requires a path argument." >&2; exit 2; }
            DUPLICATE_BACKUP_OUT_FILE="$2"
            shift 2
            ;;
        --all) SHOW_ALL=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo -e "${RED}Unknown option: $1${RESET}" >&2; usage >&2; exit 2 ;;
        *)
            # Accept a bare path as the target directory
            [[ -n "$TARGET_DIR" ]] && { echo -e "${RED}Error: unexpected argument '$1'${RESET}" >&2; usage >&2; exit 2; }
            TARGET_DIR="$1"
            SHOW_ALL=true
            shift
            ;;
    esac
done

if [[ -n "$TARGET_DIR" && "$AZURE_MISSING_OUT_FILE_EXPLICIT" == false ]]; then
    # In --dir mode, default output should stay inside the target tree.
    if [[ -d "${TARGET_DIR%/}/etc/sysctl.d" ]]; then
        AZURE_MISSING_OUT_FILE="${TARGET_DIR%/}/etc/sysctl.d/99-azure-missing-recommendations.conf"
    else
        AZURE_MISSING_OUT_FILE="${TARGET_DIR%/}/sysctl.d/99-azure-missing-recommendations.conf"
    fi
fi

echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║          sysctl configuration checker                        ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo

declare -a files=()

if [[ -n "$TARGET_DIR" ]]; then
    [[ -d "$TARGET_DIR" ]] || { echo -e "${RED}Error: '$TARGET_DIR' is not a directory.${RESET}" >&2; exit 2; }
    echo -e "  Mode : ${BOLD}directory scan${RESET}"
    echo -e "  Path : ${BLUE}${TARGET_DIR}${RESET}"
    mapfile -t files < <(collect_dir_files "$TARGET_DIR")
else
    echo -e "  Mode : ${BOLD}system paths${RESET}"
    mapfile -t files < <(collect_system_files)
fi

# Drop any accidental blank entries from collector output.
if [[ ${#files[@]} -gt 0 ]]; then
    mapfile -t files < <(printf '%s\n' "${files[@]}" | sed '/^[[:space:]]*$/d')
fi

declare -A key_entries=()

if [[ ${#files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No sysctl config files found.${RESET}"
    echo
else
    echo
    echo -e "${CYAN}${BOLD}┌─ Files scanned (load order) ──────────────────────────────────┐${RESET}"
    local_idx=1
    for f in "${files[@]}"; do
        printf "  ${DIM}%2d.${RESET}  ${BLUE}%s${RESET}\n" "$local_idx" "$f"
        ((local_idx++)) || true
    done
    echo

    accumulate files key_entries
fi

dup_exit=0
if [[ ${#files[@]} -gt 0 ]]; then
    report_duplicates key_entries || dup_exit=$?
fi

if $SHOW_ALL && [[ ${#files[@]} -gt 0 ]]; then report_all key_entries; fi

azure_exit=0
if $CHECK_AZURE; then
    report_azure_check key_entries || azure_exit=$?
fi

live_exit=0
runtime_collect_exit=0
declare -A runtime_values=()
if $CHECK_AZURE_LIVE || $WRITE_MISSING_AZURE; then
    collect_runtime_sysctl_values runtime_values || runtime_collect_exit=$?
fi

if $CHECK_AZURE_LIVE; then
    if (( runtime_collect_exit == 0 )); then
        report_azure_live_check runtime_values || live_exit=$?
    else
        live_exit=$runtime_collect_exit
    fi
fi

write_exit=0
if $WRITE_MISSING_AZURE; then
    if (( runtime_collect_exit != 0 )); then
        echo -e "${RED}Error: cannot create rollback backup because runtime sysctl values are unavailable.${RESET}" >&2
        write_exit=2
    fi

    write_missing_azure_file "$AZURE_MISSING_OUT_FILE" || write_exit=$?

    if (( write_exit == 0 )); then
        if [[ -z "$AZURE_MISSING_BACKUP_OUT_FILE" ]]; then
            AZURE_MISSING_BACKUP_OUT_FILE="$(build_backup_file_path "$AZURE_MISSING_OUT_FILE")"
        fi
        write_rollback_backup_file "$AZURE_MISSING_BACKUP_OUT_FILE" AZURE_NONCOMPLIANT_KEYS runtime_values "missing/mismatched Azure recommendations written" || write_exit=$?

        if (( write_exit == 0 )); then
            if [[ -z "$DUPLICATE_BACKUP_OUT_FILE" ]]; then
                DUPLICATE_BACKUP_OUT_FILE="$(build_backup_file_path "./sysctl-duplicate-pruned")"
            fi
            prune_duplicate_parameters key_entries "$DUPLICATE_BACKUP_OUT_FILE" "$TARGET_DIR" || write_exit=$?
        fi
    fi
fi

live_backup_exit=0
if $CHECK_AZURE_LIVE && (( live_exit != 2 )); then
    if [[ -z "$AZURE_LIVE_BACKUP_OUT_FILE" ]]; then
        AZURE_LIVE_BACKUP_OUT_FILE="$(build_backup_file_path "./sysctl-azure-live-rollback")"
    fi
    AZURE_LIVE_CHANGED_KEYS=("${AZURE_LIVE_DIFF_KEYS[@]}" "${AZURE_LIVE_MISSING_KEYS[@]}")
    write_rollback_backup_file "$AZURE_LIVE_BACKUP_OUT_FILE" AZURE_LIVE_CHANGED_KEYS runtime_values "live Azure runtime differences" || live_backup_exit=$?
fi

if (( write_exit == 2 || live_exit == 2 || live_backup_exit == 2 )); then
    exit 2
fi

exit $(( dup_exit | azure_exit | live_exit | write_exit | live_backup_exit ))
