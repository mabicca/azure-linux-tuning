#!/usr/bin/env bash
set -euo pipefail

# ANSI color codes
COLOR_BLUE="\033[34m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_CYAN="\033[36m"
COLOR_RED="\033[31m"
COLOR_RESET="\033[0m"

# =============================================================================
# mana-validate.sh - Validate MANA driver presence and activity in Azure Linux VM
# =============================================================================
# This script runs inside an Azure Linux VM to determine whether the Microsoft
# Azure Network Adapter (MANA) driver is present and active, or if the VM is
# using the NetVSC (hv_netvsc) fallback path.
#
# Usage:
#   ./mana-validate.sh                    - Output to stdout
#   ./mana-validate.sh --log              - Output to /var/log/mana-validate.log
#   As custom script extension: Automatically logs to /var/log/mana-validate.log
#   or via SSH: ssh user@host 'bash -s' < mana-validate.sh
# =============================================================================

# Determine output destination
LOG_FILE="/var/log/mana-validate.log"
USE_LOG_FILE=0

# Check if running as custom script extension or --log flag
if [ "${1:-}" = "--log" ] || [ -n "${AZURE_CUSTOM_SCRIPT_EXTENSION:-}" ]; then
  USE_LOG_FILE=1
fi

# Redirect all output to log file if needed
if [ $USE_LOG_FILE -eq 1 ]; then
  # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"
  
  # Redirect stdout and stderr to log file
  exec > >(tee -a "$LOG_FILE") 2>&1
  
  echo ""
  echo "========================================================================"
  echo "New validation run started at $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  echo "========================================================================"
fi

echo "=========================================="
echo -e "${COLOR_CYAN}Azure Linux MANA Driver Validation${COLOR_RESET}"
echo "=========================================="
echo -e "Timestamp: ${COLOR_BLUE}$(date -u +"%Y-%m-%d %H:%M:%S UTC")${COLOR_RESET}"
if [ $USE_LOG_FILE -eq 1 ]; then
  echo "Log file:  $LOG_FILE"
fi
echo ""

# --- OS and Kernel Information ---
echo "=========================================="
echo -e "${COLOR_CYAN}1. OS and Kernel Information${COLOR_RESET}"
echo "=========================================="

if [ -f /etc/os-release ]; then
  echo "--- /etc/os-release ---"
  cat /etc/os-release
  echo ""
else
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} /etc/os-release not found"
  echo ""
fi

echo "--- kernel version ---"
KERNEL_VERSION=$(uname -r)
echo -e "Kernel: ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET}"
echo -e "Full uname: ${COLOR_BLUE}$(uname -a)${COLOR_RESET}"
echo ""

# Extract major.minor version for comparison
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)
KERNEL_NUMERIC=$(printf "%d%02d" "$KERNEL_MAJOR" "$KERNEL_MINOR")

# --- PCI Device Check ---
echo "=========================================="
echo -e "${COLOR_CYAN}2. PCI Device Check (lspci)${COLOR_RESET}"
echo "=========================================="

AN_ENABLED=0
VF_DEVICE=""

if command -v lspci &> /dev/null; then
  echo "--- lspci (ethernet) ---"
  lspci | grep -i ethernet || echo "No Ethernet devices found via lspci grep"
  echo ""
  
  # Check for Microsoft Virtual Function device (indicates AN is enabled)
  if lspci | grep -qi "Microsoft.*Virtual Function"; then
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}  Accelerated Networking: ${COLOR_GREEN}ENABLED${COLOR_RESET} (VF device present)"
    AN_ENABLED=1
    VF_DEVICE=$(lspci | grep -i "Microsoft.*Virtual Function" | head -1)
    echo -e "      Device: ${COLOR_CYAN}$VF_DEVICE${COLOR_RESET}"
  else
    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} Accelerated Networking: ${COLOR_RED}DISABLED${COLOR_RESET} (no VF device found)"
    echo "       VM is on synthetic NetVSC path"
  fi
  echo ""
  
  echo "--- lspci (full) ---"
  lspci 2>/dev/null || echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} lspci command failed"
  echo ""
else
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} lspci not found — skipping PCI check"
  echo "       Install: apt/dnf install pciutils"
  echo ""
fi

# --- Kernel Module Check ---
echo "=========================================="
echo -e "${COLOR_CYAN}3. Kernel Module Check${COLOR_RESET}"
echo "=========================================="

echo "--- lsmod ---"
if command -v lsmod &> /dev/null; then
  echo "MANA modules:"
  lsmod | grep -i mana || echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} No MANA modules loaded"
  echo ""

  echo "hv_netvsc module:"
  lsmod | grep -i hv_netvsc || echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} hv_netvsc not loaded"
  echo ""
else
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} lsmod not found — skipping module check"
  echo ""
fi

# --- Driver File Check ---
echo "=========================================="
echo -e "${COLOR_CYAN}4. MANA Driver File Presence${COLOR_RESET}"
echo "=========================================="

MODULES_DIR="/lib/modules/$KERNEL_VERSION"
MANA_FOUND=0

echo "Searching for mana*.ko in $MODULES_DIR..."
if [ -d "$MODULES_DIR" ]; then
  MANA_FILES=$(find "$MODULES_DIR" -name "mana*.ko" -o -name "mana*.ko.xz" -o -name "mana*.ko.zst" 2>/dev/null || true)
  if [ -n "$MANA_FILES" ]; then
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}  MANA driver files found:"
    echo "$MANA_FILES"
    MANA_FOUND=1
  else
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} No mana*.ko files found in $MODULES_DIR"
  fi
else
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} Modules directory $MODULES_DIR not found"
fi
echo ""

echo "Checking modules.builtin for built-in MANA driver..."
if [ -f "$MODULES_DIR/modules.builtin" ]; then
  if grep -qi mana "$MODULES_DIR/modules.builtin"; then
    echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}  MANA driver built into kernel (modules.builtin)"
    MANA_FOUND=1
  else
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} MANA driver not in modules.builtin"
  fi
else
  echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} modules.builtin not found"
fi
echo ""

# --- Network Interface Information ---
echo "=========================================="
echo "5. Network Interface Information"
echo "=========================================="

echo "--- ip link ---"
ip -br link
echo ""

echo "--- ip addr ---"
ip -br addr
echo ""

# Define interface list once — reused across all ethtool and classification sections
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true)

# --- Ethtool Driver Information ---
echo "=========================================="
echo "6. Driver Information (ethtool)"
echo "=========================================="

if command -v ethtool &> /dev/null; then
  for iface in $INTERFACES; do
    echo -e "--- ethtool -i ${COLOR_CYAN}$iface${COLOR_RESET} ---"
    ethtool -i "$iface" 2>/dev/null || echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ethtool -i failed for $iface"
    echo ""
  done
else
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ethtool not found — skipping driver check"
  echo "       Install: apt/dnf install ethtool"
  echo ""
fi

# --- NIC Ring Buffer Information (ethtool -g) ---
echo "=========================================="
echo -e "${COLOR_CYAN}7. NIC Ring Buffer Information (ethtool -g)${COLOR_RESET}"
echo "=========================================="
# Note: MANA and some synthetic interfaces do not support ring buffer queries
# via ethtool. 'Operation not supported' is expected for those drivers and is
# recorded here for documentation purposes, not treated as a failure.

# Always initialise so the summary check is safe regardless of ethtool availability
RING_BUFFER_RESULTS=()

if command -v ethtool &> /dev/null; then
  for iface in $INTERFACES; do
    DRIVER=$(ethtool -i "$iface" 2>/dev/null | grep "^driver:" | awk '{print $2}' || true)
    echo -e "--- ethtool -g ${COLOR_CYAN}$iface${COLOR_RESET} (driver: ${COLOR_CYAN}${DRIVER:-unknown}${COLOR_RESET}) ---"
    ETHTOOL_G_OUTPUT=$(ethtool -g "$iface" 2>&1)
    ETHTOOL_G_EXIT=$?
    if [ $ETHTOOL_G_EXIT -eq 0 ]; then
      echo "$ETHTOOL_G_OUTPUT"
      RING_BUFFER_RESULTS+=("$iface:${DRIVER:-unknown}:ok")
    else
      echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} ethtool -g exit $ETHTOOL_G_EXIT for $iface"
      echo "       Output: $ETHTOOL_G_OUTPUT"
      case "$DRIVER" in
        mana)
          echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} Expected: MANA does not support ring buffer queries via ethtool"
          RING_BUFFER_RESULTS+=("$iface:mana:not-supported (expected)")
          ;;
        hv_netvsc)
          echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} Expected: hv_netvsc synthetic path may not support ring buffer queries"
          RING_BUFFER_RESULTS+=("$iface:hv_netvsc:not-supported (expected)")
          ;;
        *)
          echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} Unexpected: driver '$DRIVER' — investigate if ring buffer tuning is needed"
          RING_BUFFER_RESULTS+=("$iface:${DRIVER:-unknown}:failed (unexpected)")
          ;;
      esac
    fi
    echo ""
  done
else
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ethtool not found — skipping ring buffer check"
  echo "       Install: apt/dnf install ethtool"
  echo ""
fi

# --- Kernel Messages (dmesg) ---
echo "=========================================="
echo -e "${COLOR_CYAN}8. Kernel Messages (dmesg)${COLOR_RESET}"
echo "=========================================="

if command -v dmesg &> /dev/null; then
  echo "--- dmesg (mana/hv_netvsc, last 200 lines) ---"
  dmesg | tail -n 200 | grep -iE "mana|hv_netvsc" || echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} No mana/hv_netvsc messages in recent dmesg"
  echo ""
else
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} dmesg not available"
  echo ""
fi

# --- Final Classification ---
echo "=========================================="
echo -e "${COLOR_CYAN}9. Final Classification${COLOR_RESET}"
echo "=========================================="

# Classification logic
CLASSIFICATION="Inconclusive"
DRIVER_ACTIVE=""
MANA_CAPABLE="No"
MANA_CAPABILITY_REASON=""

# Check if MANA driver is loaded
MANA_LOADED=0
if command -v lsmod &> /dev/null; then
  if lsmod | grep -q "^mana"; then
    MANA_LOADED=1
    DRIVER_ACTIVE="mana"
  fi
fi

# Check ethtool driver info
if command -v ethtool &> /dev/null; then
  for iface in $INTERFACES; do
    DRIVER=$(ethtool -i "$iface" 2>/dev/null | grep "^driver:" | awk '{print $2}' || true)
    if [ "$DRIVER" = "mana" ]; then
      DRIVER_ACTIVE="mana"
      break
    elif [ "$DRIVER" = "hv_netvsc" ]; then
      DRIVER_ACTIVE="hv_netvsc"
    fi
  done
fi

# Check dmesg for MANA activity
MANA_DMESG=0
if command -v dmesg &> /dev/null; then
  if dmesg | grep -iq "mana.*bound\|mana.*registered\|mana.*link"; then
    MANA_DMESG=1
  fi
fi

# === MANA CAPABILITY ASSESSMENT (independent of AN status) ===
# Priority order:
#   1. Driver active on an interface   → definitive proof, regardless of kernel version
#   2. Driver module loaded (lsmod)    → definitive proof
#   3. Driver file present on disk     → present, may need AN enabled to activate
#   4. Kernel version heuristic only   → fallback when no driver evidence exists at all
#
# Note: distros like RHEL 9 ship kernel 5.14.x with MANA backported, so the
# upstream 5.15 inclusion date is not a reliable gate for backport-based distros.

if [ "$DRIVER_ACTIVE" = "mana" ] || [ $MANA_LOADED -eq 1 ]; then
  # Driver is provably present and working
  MANA_CAPABLE="Yes"
  if [ "$KERNEL_NUMERIC" -ge 602 ]; then
    MANA_CAPABILITY_REASON="MANA driver active on kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} (Ethernet + RDMA/DPDK capable)"
  else
    MANA_CAPABILITY_REASON="MANA driver active on kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} (Ethernet capable; may include backport)"
  fi
elif [ $MANA_FOUND -eq 1 ]; then
  # Driver file exists but not yet active (AN may be disabled)
  MANA_CAPABLE="Yes"
  if [ "$KERNEL_NUMERIC" -ge 602 ]; then
    MANA_CAPABILITY_REASON="MANA driver found on kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} (Ethernet + RDMA/DPDK capable)"
  else
    MANA_CAPABILITY_REASON="MANA driver found on kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} (Ethernet capable; may include backport)"
  fi
elif [ "$KERNEL_NUMERIC" -ge 515 ]; then
  # No driver evidence but kernel version suggests it should be available
  MANA_CAPABLE="Partial"
  MANA_CAPABILITY_REASON="Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} >= 5.15 but MANA driver not found (may need module installation)"
else
  # No driver evidence and kernel predates upstream inclusion
  MANA_CAPABLE="No"
  MANA_CAPABILITY_REASON="Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} < 5.15 upstream baseline and no MANA driver found"
fi

# === MANA ACTIVE STATUS (requires AN enabled) ===
if [ "$DRIVER_ACTIVE" = "mana" ] || [ $MANA_LOADED -eq 1 ] || [ $MANA_DMESG -eq 1 ]; then
  CLASSIFICATION="MANA driver ACTIVE"
  # If MANA driver is running, AN must be enabled (override lspci VF detection)
  AN_ENABLED=1
elif [ $MANA_FOUND -eq 0 ] && [ "$DRIVER_ACTIVE" = "hv_netvsc" ]; then
  CLASSIFICATION="NetVSC fallback (no MANA driver present)"
elif [ $MANA_FOUND -eq 1 ] && [ "$DRIVER_ACTIVE" = "hv_netvsc" ] && [ $AN_ENABLED -eq 0 ]; then
  CLASSIFICATION="MANA driver present but NOT ACTIVE (Accelerated Networking disabled)"
elif [ $MANA_FOUND -eq 1 ] && [ "$DRIVER_ACTIVE" = "hv_netvsc" ] && [ $AN_ENABLED -eq 1 ]; then
  CLASSIFICATION="MANA driver present but hv_netvsc active (possible VF binding issue)"
else
  CLASSIFICATION="Inconclusive (missing tools or conflicting evidence)"
fi

echo -e "=== ${COLOR_CYAN}MANA Capability Assessment${COLOR_RESET} ==="
echo -e "MANA Capable:        ${COLOR_BLUE}$MANA_CAPABLE${COLOR_RESET}"
echo -e "Reason:              $MANA_CAPABILITY_REASON"
echo ""
echo -e "=== ${COLOR_CYAN}Current Status${COLOR_RESET} ==="
echo -e "AN Enabled:          $([ $AN_ENABLED -eq 1 ] && echo "${COLOR_GREEN}Yes${COLOR_RESET}" || echo "${COLOR_YELLOW}No${COLOR_RESET}")"
echo -e "Active Driver:       ${COLOR_CYAN}${DRIVER_ACTIVE:-Unknown}${COLOR_RESET}"
echo -e "Classification:      ${COLOR_BLUE}$CLASSIFICATION${COLOR_RESET}"
echo ""

# --- Kernel Version Context ---
echo "--- kernel version context ---"
if [ "$KERNEL_NUMERIC" -lt 515 ] && [ $MANA_FOUND -eq 0 ] && [ "$DRIVER_ACTIVE" != "mana" ]; then
  echo -e "Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} is below the 5.15 upstream baseline for MANA."
  echo "No backported MANA driver was detected on this system."
  echo "MANA Ethernet support was merged upstream in 5.15; RDMA/DPDK in 6.2."
elif [ "$KERNEL_NUMERIC" -lt 515 ]; then
  echo -e "Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} is below 5.15 upstream baseline but MANA driver is present."
  echo "This distro likely ships a backported MANA driver (e.g. RHEL 9 / CentOS Stream 9)."
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} Backported drivers may not include all features available in later upstream kernels."
  echo "       Features potentially limited or absent: RDMA/DPDK (6.2+), XDP improvements,"
  echo "       advanced queue management, and newer ethtool statistics support."
elif [ "$KERNEL_NUMERIC" -ge 602 ]; then
  echo -e "Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} >= 6.2: includes MANA Ethernet, InfiniBand/RDMA, and DPDK support."
else
  echo -e "Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} is between 5.15 and 6.2: includes MANA Ethernet support."
  echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} RDMA/DPDK features require kernel 6.2 or later."
fi
echo ""

# --- Summary ---
echo "=========================================="
echo -e "${COLOR_CYAN}Summary${COLOR_RESET}"
echo "=========================================="
echo -e "Kernel:              ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET}"
echo -e "MANA Capable:        ${COLOR_BLUE}$MANA_CAPABLE${COLOR_RESET}"
echo -e "MANA Driver:         $([ $MANA_FOUND -eq 1 ] && echo "${COLOR_GREEN}Found${COLOR_RESET}" || echo "${COLOR_YELLOW}Not found${COLOR_RESET}")"
echo -e "AN Enabled:          $([ $AN_ENABLED -eq 1 ] && echo "${COLOR_GREEN}Yes (VF device present)${COLOR_RESET}" || echo "${COLOR_YELLOW}No (synthetic NetVSC)${COLOR_RESET}")"
echo -e "Active Driver:       ${COLOR_CYAN}${DRIVER_ACTIVE:-Unknown}${COLOR_RESET}"
echo -e "Status:              ${COLOR_BLUE}$CLASSIFICATION${COLOR_RESET}"
echo ""

echo -e "Ring Buffer (ethtool -g):"
if [ "${#RING_BUFFER_RESULTS[@]}" -eq 0 ]; then
  echo "  ethtool not available — skipped"
else
  for entry in "${RING_BUFFER_RESULTS[@]}"; do
    iface_name=${entry%%:*}
    rest=${entry#*:}
    drv=${rest%%:*}
    status=${rest#*:}
    echo -e "  ${COLOR_CYAN}${iface_name}${COLOR_RESET}           driver=${COLOR_CYAN}${drv}${COLOR_RESET}          ${status}"
  done
fi
echo ""

if [ "$MANA_CAPABLE" = "Yes" ] && [ $AN_ENABLED -eq 0 ] && [ "$DRIVER_ACTIVE" != "mana" ]; then
  echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} OS is MANA-capable but Accelerated Networking is disabled."
  echo "       To enable, deallocate the VM then run:"
  echo "       az network nic update -g <RG> -n <NIC> --accelerated-networking true"
  echo "       Then restart the VM."
elif [ "$MANA_CAPABLE" = "No" ]; then
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} predates upstream MANA support and no driver was found."
  echo "       MANA requires kernel 5.15+ (Ethernet) or 6.2+ (RDMA/DPDK), or a distro backport."
  echo "       Upgrade the kernel or use a supported distribution."
elif [ "$MANA_CAPABLE" = "Partial" ]; then
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} Kernel supports MANA but driver modules not found."
  echo "       Install MANA modules or use a distribution with built-in support."
fi

if [ "$KERNEL_NUMERIC" -lt 515 ] && [ "$MANA_CAPABLE" = "Yes" ]; then
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} is below the 5.15 upstream baseline."
  echo "       The MANA driver appears to be a distro backport. Some features available"
  echo "       in later upstream kernels may be absent or limited:"
  echo "         - RDMA / DPDK support (upstream 6.2+)"
  echo "         - XDP and advanced queue management improvements"
  echo "         - Newer ethtool statistics and ring buffer query support"
  echo "       Check with your distro for the specific feature set included in this backport."
elif [ "$KERNEL_NUMERIC" -lt 602 ] && [ "$MANA_CAPABLE" = "Yes" ]; then
  echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} Kernel ${COLOR_BLUE}$KERNEL_VERSION${COLOR_RESET} does not include MANA RDMA/DPDK support (requires 6.2+)."
fi
echo ""
echo -e "${COLOR_GREEN}Validation complete.${COLOR_RESET}"
echo "=========================================="

# Exit code based on result
EXIT_CODE=0
if [ "$CLASSIFICATION" = "MANA driver ACTIVE" ]; then
  EXIT_CODE=0  # Success - MANA is active
elif [ "$MANA_CAPABLE" = "Yes" ] && [ $AN_ENABLED -eq 0 ]; then
  EXIT_CODE=10  # MANA capable but AN disabled
elif [ "$MANA_CAPABLE" = "No" ]; then
  EXIT_CODE=20  # Not MANA capable (old kernel)
elif [[ "$CLASSIFICATION" == *"NetVSC fallback"* ]]; then
  EXIT_CODE=30  # Using NetVSC fallback
elif [[ "$CLASSIFICATION" == *"VF binding issue"* ]]; then
  EXIT_CODE=40  # MANA present but VF binding issue
else
  EXIT_CODE=50  # Inconclusive
fi

if [ $USE_LOG_FILE -eq 1 ]; then
  echo ""
  echo "========================================================================"
  echo "Validation complete. Results saved to: $LOG_FILE"
  echo "Exit code: $EXIT_CODE"
  echo "  0  = MANA active"
  echo "  10 = MANA capable but AN disabled"
  echo "  20 = Not MANA capable (old kernel)"
  echo "  30 = Using NetVSC fallback"
  echo "  40 = MANA present but VF binding issue"
  echo "  50 = Inconclusive"
  echo "========================================================================"
fi

exit $EXIT_CODE
