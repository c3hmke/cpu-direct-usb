#!/usr/bin/env bash
set -u
shopt -s extglob

# =============================================================================
# USB Latency Analyzer (Linux)
#
# Purpose:
#   Help identify which physical USB ports are closest to the CPU / least complex
#   path by tracing each USB input device to:
#     device -> hubs (if any) -> USB host controller -> PCI function
#
# Interpretation:
#   0 chips = CPU-integrated / CPU-attached controller
#   1 chip  = chipset/PCH or PCIe add-in USB controller
#   2+ chips = one or more hubs between device and controller
#
# Notes:
#   - This is best-effort topology analysis using sysfs + PCI IDs.
#   - On Linux, "low latency" is influenced by more than topology:
#     polling rate, xHCI scheduling, MSI/MSI-X, autosuspend, firmware, etc.
#   - USB4/TB docks/hubs can obscure the real path.
# =============================================================================

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[38;2;108;108;108m"
WHITE="${ESC}[97m"
MINT="${ESC}[38;2;0;255;135m"
ORANGE="${ESC}[38;2;255;179;71m"
CORAL="${ESC}[38;2;255;107;107m"
SKY="${ESC}[38;2;135;206;235m"
BORDER="${ESC}[38;2;74;74;74m"

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

short_name() {
  local s="$1" max="${2:-42}"
  s="${s#Razer }"
  s="${s#Logitech }"
  s="${s#SteelSeries }"
  s="${s#Corsair }"
  s="${s#HyperX }"
  if ((${#s} > max)); then
    printf '%s...' "${s:0:max-3}"
  else
    printf '%s' "$s"
  fi
}

progress() {
  local pct="$1"
  local msg="$2"
  local width=25
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar_f bar_e
  printf -v bar_f '%*s' "$filled" ''
  printf -v bar_e '%*s' "$empty" ''
  bar_f=${bar_f// /▓}
  bar_e=${bar_e// /░}
  printf '\r  %b%s%b%s%b %b%s%b' \
    "${MINT}" "$bar_f" \
    "${DIM}" "$bar_e" \
    "${RESET}" \
    "${DIM}" "$msg" "${RESET}"
}

clear_status_line() {
  printf '\r%*s\r' 100 ''
}

read_file() {
  local f="$1"
  [[ -r "$f" ]] || return 1
  <"$f" tr -d '\0'
}

realp() {
  readlink -f -- "$1" 2>/dev/null || return 1
}

# -----------------------------------------------------------------------------
# Controller database
# -----------------------------------------------------------------------------
# value format: TYPE|CHIPCOUNT|NAME|PLATFORM|USB
declare -A CTRL_DB
declare -A VENDOR_FALLBACK

db_add() {
  local key="$1" type="$2" chip="$3" name="$4" platform="$5" usb="$6"
  CTRL_DB["${key,,}"]="$type|$chip|$name|$platform|$usb"
}

# Fallback vendor labels
VENDOR_FALLBACK["1b21"]="ASMedia"
VENDOR_FALLBACK["1106"]="VIA"
VENDOR_FALLBACK["1b73"]="Fresco Logic"
VENDOR_FALLBACK["1912"]="Renesas"
VENDOR_FALLBACK["1b6f"]="Etron"
VENDOR_FALLBACK["104c"]="Texas Instruments"

# Intel CPU integrated / CPU attached (chip 0)
db_add "8086:8a13" "CPU" 0 "Ice Lake Thunderbolt 3 USB Controller" "Ice Lake (10th Gen)" "USB 3.2/TB3"
db_add "8086:9a13" "CPU" 0 "Tiger Lake-LP Thunderbolt 4 USB Controller" "Tiger Lake (11th Gen)" "USB4/TB4"
db_add "8086:9a17" "CPU" 0 "Tiger Lake-H Thunderbolt 4 USB Controller" "Tiger Lake-H (11th Gen)" "USB4/TB4"
db_add "8086:461e" "CPU" 0 "Alder Lake-P Thunderbolt 4 USB Controller" "Alder Lake (12th Gen)" "USB4/TB4"
db_add "8086:464e" "CPU" 0 "Alder Lake-N Processor USB 3.2 xHCI Controller" "Alder Lake-N" "USB 3.2"
db_add "8086:a71e" "CPU" 0 "Raptor Lake-P Thunderbolt 4 USB Controller" "Raptor Lake (13th Gen)" "USB4/TB4"
db_add "8086:7ec0" "CPU" 0 "Meteor Lake-P Thunderbolt 4 USB Controller" "Meteor Lake (Core Ultra)" "USB4/TB4"
db_add "8086:a831" "CPU" 0 "Lunar Lake-M Thunderbolt 4 USB Controller" "Lunar Lake" "USB4/TB4"

# Intel PCH / chipset (chip 1)
db_add "8086:7f6e" "CHIPSET" 1 "800 Series PCH USB 3.1 xHCI HC" "800 Series PCH" "USB 3.1"
db_add "8086:7a60" "CHIPSET" 1 "Raptor Lake USB 3.2 Gen 2x2 XHCI Host Controller" "700 Series PCH" "USB 3.2 Gen 2x2"
db_add "8086:7ae0" "CHIPSET" 1 "Alder Lake-S PCH USB 3.2 Gen 2x2 XHCI Controller" "600 Series PCH (Desktop)" "USB 3.2 Gen 2x2"
db_add "8086:51ed" "CHIPSET" 1 "Alder Lake PCH USB 3.2 xHCI Host Controller" "600 Series PCH" "USB 3.2"
db_add "8086:54ed" "CHIPSET" 1 "Alder Lake-N PCH USB 3.2 Gen 2x1 xHCI Host Controller" "Alder Lake-N PCH" "USB 3.2 Gen 2"
db_add "8086:7e7d" "CHIPSET" 1 "Meteor Lake-P USB 3.2 Gen 2x1 xHCI Host Controller" "Meteor Lake PCH" "USB 3.2 Gen 2"
db_add "8086:777d" "CHIPSET" 1 "Arrow Lake USB 3.2 xHCI Controller" "Arrow Lake" "USB 3.2"
db_add "8086:a87d" "CHIPSET" 1 "Lunar Lake-M USB 3.2 Gen 2x1 xHCI Host Controller" "Lunar Lake PCH" "USB 3.2 Gen 2"
db_add "8086:a0ed" "CHIPSET" 1 "Tiger Lake-LP USB 3.2 Gen 2x1 xHCI Host Controller" "500 Series PCH" "USB 3.2 Gen 2"
db_add "8086:43ed" "CHIPSET" 1 "Tiger Lake-H USB 3.2 Gen 2x1 xHCI Host Controller" "500 Series PCH-H" "USB 3.2 Gen 2"
db_add "8086:a3af" "CHIPSET" 1 "Comet Lake PCH-V USB Controller" "400 Series PCH" "USB 3.1"
db_add "8086:02ed" "CHIPSET" 1 "Comet Lake PCH-LP USB 3.1 xHCI Host Controller" "400 Series PCH-LP" "USB 3.1"
db_add "8086:06ed" "CHIPSET" 1 "Comet Lake USB 3.1 xHCI Host Controller" "400 Series PCH" "USB 3.1"
db_add "8086:a36d" "CHIPSET" 1 "Cannon Lake PCH USB 3.1 xHCI Host Controller" "300 Series PCH" "USB 3.1"
db_add "8086:9ded" "CHIPSET" 1 "Cannon Point-LP USB 3.1 xHCI Controller" "300 Series PCH-LP" "USB 3.1"
db_add "8086:a2af" "CHIPSET" 1 "200 Series/Z370 Chipset Family USB 3.0 xHCI Controller" "200 Series PCH" "USB 3.0"
db_add "8086:a12f" "CHIPSET" 1 "100 Series/C230 Series Chipset Family USB 3.0 xHCI Controller" "100 Series PCH" "USB 3.0"
db_add "8086:9d2f" "CHIPSET" 1 "Sunrise Point-LP USB 3.0 xHCI Controller" "100 Series PCH-LP" "USB 3.0"
db_add "8086:8cb1" "CHIPSET" 1 "9 Series Chipset Family USB xHCI Controller" "9 Series PCH" "USB 3.0"
db_add "8086:9cb1" "CHIPSET" 1 "Wildcat Point-LP USB xHCI Controller" "9 Series PCH-LP" "USB 3.0"
db_add "8086:8c31" "CHIPSET" 1 "8 Series/C220 Series Chipset Family USB xHCI" "8 Series PCH" "USB 3.0"
db_add "8086:9c31" "CHIPSET" 1 "8 Series USB xHCI HC" "8 Series PCH-LP" "USB 3.0"
db_add "8086:1e31" "CHIPSET" 1 "7 Series/C210 Series Chipset Family USB xHCI Host Controller" "7 Series PCH" "USB 3.0"
db_add "8086:8d31" "CHIPSET" 1 "C610/X99 series chipset USB xHCI Host Controller" "X99/C610 (HEDT/Server)" "USB 3.0"
db_add "8086:a1af" "CHIPSET" 1 "C620 Series Chipset Family USB 3.0 xHCI Controller" "C620 (Server)" "USB 3.0"

# Intel Thunderbolt (CPU attached, chip 0)
db_add "8086:5782" "TB" 0 "JHL9580 Thunderbolt 5 USB Controller" "Barlow Ridge Host 80G" "USB4/TB5"
db_add "8086:5785" "TB" 0 "JHL9540 Thunderbolt 4 USB Controller" "Barlow Ridge Host 40G" "USB4/TB4"
db_add "8086:5787" "TB" 0 "JHL9480 Thunderbolt 5 USB Controller" "Barlow Ridge Hub 80G" "USB4/TB5"
db_add "8086:57a5" "TB" 0 "JHL9440 Thunderbolt 4 USB Controller" "Barlow Ridge Hub 40G" "USB4/TB4"
db_add "8086:1138" "TB" 0 "Thunderbolt 4 USB Controller [Maple Ridge 4C]" "Maple Ridge 4C" "USB4/TB4"
db_add "8086:1135" "TB" 0 "Thunderbolt 4 USB Controller [Maple Ridge 2C]" "Maple Ridge 2C" "USB4/TB4"
db_add "8086:0b27" "TB" 0 "Thunderbolt 4 USB Controller [Goshen Ridge]" "Goshen Ridge" "USB4/TB4"
db_add "8086:15e9" "TB" 0 "JHL7540 Thunderbolt 3 USB Controller [Titan Ridge 2C]" "Titan Ridge 2C" "USB 3.1/TB3"
db_add "8086:15ec" "TB" 0 "JHL7540 Thunderbolt 3 USB Controller [Titan Ridge 4C]" "Titan Ridge 4C" "USB 3.1/TB3"
db_add "8086:15f0" "TB" 0 "JHL7440 Thunderbolt 3 USB Controller [Titan Ridge DD]" "Titan Ridge DD" "USB 3.1/TB3"
db_add "8086:15b5" "TB" 0 "DSL6340 USB 3.1 Controller [Alpine Ridge 2C]" "Alpine Ridge 2C" "USB 3.1/TB3"
db_add "8086:15b6" "TB" 0 "DSL6540 USB 3.1 Controller [Alpine Ridge 4C]" "Alpine Ridge 4C" "USB 3.1/TB3"
db_add "8086:15c1" "TB" 0 "JHL6240 Thunderbolt 3 USB 3.1 Controller [Alpine Ridge LP]" "Alpine Ridge LP" "USB 3.1/TB3"
db_add "8086:15d4" "TB" 0 "JHL6540 Thunderbolt 3 USB Controller [Alpine Ridge 4C]" "Alpine Ridge 4C C-step" "USB 3.1/TB3"
db_add "8086:15db" "TB" 0 "JHL6340 Thunderbolt 3 USB 3.1 Controller [Alpine Ridge 2C]" "Alpine Ridge 2C C-step" "USB 3.1/TB3"

# AMD CPU integrated (chip 0)
db_add "1022:15b6" "CPU" 0 "Raphael/Granite Ridge USB 3.1 xHCI" "Ryzen 7000/9000 Desktop (AM5)" "USB 3.1"
db_add "1022:15b7" "CPU" 0 "Raphael/Granite Ridge USB 3.1 xHCI" "Ryzen 7000/9000 Desktop (AM5)" "USB 3.1"
db_add "1022:15b8" "CPU" 0 "Raphael/Granite Ridge USB 2.0 xHCI" "Ryzen 7000/9000 Desktop (AM5)" "USB 2.0"
db_add "1022:1587" "CPU" 0 "Strix Halo USB 3.1 xHCI" "Strix Halo (Zen 5)" "USB 3.1"
db_add "1022:1588" "CPU" 0 "Strix Halo USB 3.1 xHCI" "Strix Halo (Zen 5)" "USB 3.1"
db_add "1022:1589" "CPU" 0 "Strix Halo USB 3.1 xHCI" "Strix Halo (Zen 5)" "USB 3.1"
db_add "1022:158b" "CPU" 0 "Strix Halo USB 3.1 xHCI" "Strix Halo (Zen 5)" "USB 3.1"
db_add "1022:158d" "CPU" 0 "Strix Halo USB4 Host Router" "Strix Halo (Zen 5)" "USB4"
db_add "1022:158e" "CPU" 0 "Strix Halo USB4 Host Router" "Strix Halo (Zen 5)" "USB4"
db_add "1022:161a" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:161b" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:161c" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:161d" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:161e" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:161f" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:15d6" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:15d7" "CPU" 0 "Rembrandt USB4 XHCI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4"
db_add "1022:162e" "CPU" 0 "Rembrandt USB4/Thunderbolt NHI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4/TB"
db_add "1022:162f" "CPU" 0 "Rembrandt USB4/Thunderbolt NHI controller" "Ryzen 6000 Mobile (Zen 3+)" "USB4/TB"
db_add "1022:15c4" "CPU" 0 "Phoenix USB4/Thunderbolt NHI controller" "Ryzen 7040 Mobile (Zen 4)" "USB4/TB"
db_add "1022:15c5" "CPU" 0 "Phoenix USB4/Thunderbolt NHI controller" "Ryzen 7040 Mobile (Zen 4)" "USB4/TB"
db_add "1022:1668" "CPU" 0 "Pink Sardine USB4/Thunderbolt NHI controller" "Pink Sardine" "USB4/TB"
db_add "1022:1669" "CPU" 0 "Pink Sardine USB4/Thunderbolt NHI controller" "Pink Sardine" "USB4/TB"
db_add "1022:1639" "CPU" 0 "Renoir/Cezanne USB 3.1" "Ryzen 4000/5000 APU (Zen 2/3)" "USB 3.1"
db_add "1022:15e0" "CPU" 0 "Raven USB 3.1" "Ryzen 2000 APU (Zen)" "USB 3.1"
db_add "1022:15e1" "CPU" 0 "Raven USB 3.1" "Ryzen 2000 APU (Zen)" "USB 3.1"
db_add "1022:15e5" "CPU" 0 "Raven2 USB 3.1" "Ryzen 3000 APU (Zen+)" "USB 3.1"
db_add "1022:149c" "CPU" 0 "Matisse USB 3.0 Host Controller" "Ryzen 3000/5000 Desktop (Zen 2/3)" "USB 3.0"
db_add "1022:148c" "CPU" 0 "Starship USB 3.0 Host Controller" "EPYC Rome / Threadripper 3rd Gen" "USB 3.0"
db_add "1022:145f" "CPU" 0 "Zeppelin USB 3.0 xHCI Compliant Host Controller" "Ryzen 1000 (Zen)" "USB 3.0"
db_add "1022:145c" "CPU" 0 "Family 17h USB 3.0 Host Controller" "Ryzen 1000 (Zen)" "USB 3.0"
db_add "1022:162c" "CPU" 0 "VanGogh USB2" "Steam Deck (Van Gogh)" "USB 2.0"
db_add "1022:163a" "CPU" 0 "VanGogh USB0" "Steam Deck (Van Gogh)" "USB 3.1"
db_add "1022:163b" "CPU" 0 "VanGogh USB1" "Steam Deck (Van Gogh)" "USB 3.1"
db_add "1022:15d4" "CPU" 0 "FireFlight USB 3.1" "FireFlight" "USB 3.1"
db_add "1022:15d5" "CPU" 0 "FireFlight USB 3.1" "FireFlight" "USB 3.1"
db_add "1022:13ed" "CPU" 0 "Ariel USB 3.1 Type C (Gen2 + DP Alt)" "Ariel" "USB 3.1 Gen 2"
db_add "1022:13ee" "CPU" 0 "Ariel USB 3.1 Type A (Gen2 x 2 ports)" "Ariel" "USB 3.1 Gen 2"
db_add "1022:1557" "CPU" 0 "Turin USB 3.1 xHCI" "EPYC Turin" "USB 3.1"

# AMD chipset (chip 1)
db_add "1022:43fc" "CHIPSET" 1 "800 Series Chipset USB 3.x XHCI Controller" "X870/B850 (AM5)" "USB 3.2"
db_add "1022:43fd" "CHIPSET" 1 "800 Series Chipset USB 3.x XHCI Controller" "X870/B850 (AM5)" "USB 3.2"
db_add "1022:43f7" "CHIPSET" 1 "600 Series Chipset USB 3.2 Controller" "X670/B650 (AM5)" "USB 3.2"
db_add "1022:43ee" "CHIPSET" 1 "500 Series Chipset USB 3.1 XHCI Controller" "X570/B550 (AM4)" "USB 3.1"
db_add "1022:43ec" "CHIPSET" 1 "A520 Series Chipset USB 3.1 XHCI Controller" "A520 (AM4)" "USB 3.1"
db_add "1022:43d5" "CHIPSET" 1 "400 Series Chipset USB 3.1 xHCI Compliant Host Controller" "X470/B450 (AM4)" "USB 3.1"
db_add "1022:43b9" "CHIPSET" 1 "X370 Series Chipset USB 3.1 xHCI Controller" "X370 (AM4)" "USB 3.1"
db_add "1022:43ba" "CHIPSET" 1 "X399 Series Chipset USB 3.1 xHCI Controller" "X399 (Threadripper)" "USB 3.1"
db_add "1022:43bb" "CHIPSET" 1 "300 Series Chipset USB 3.1 xHCI Controller" "B350 (AM4)" "USB 3.1"
db_add "1022:43bc" "CHIPSET" 1 "A320 USB 3.1 XHCI Host Controller" "A320 (AM4)" "USB 3.1"
db_add "1022:7814" "CHIPSET" 1 "FCH USB XHCI Controller" "Legacy FCH" "USB 3.0"
db_add "1022:7812" "CHIPSET" 1 "FCH USB XHCI Controller" "Legacy FCH" "USB 3.0"

# Third-party add-in controllers (chip 1)
db_add "1b21:1042" "ADDON" 1 "ASM1042 SuperSpeed USB Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1b21:1142" "ADDON" 1 "ASM1042A USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1b21:1242" "ADDON" 1 "ASM1142 USB 3.1 Host Controller" "PCIe Add-in" "USB 3.1 Gen 2"
db_add "1b21:1343" "ADDON" 1 "ASM1143 USB 3.1 Host Controller" "PCIe Add-in" "USB 3.1 Gen 2"
db_add "1b21:2142" "ADDON" 1 "ASM2142/ASM3142 USB 3.1 Host Controller" "PCIe Add-in" "USB 3.1 Gen 2"
db_add "1b21:3042" "ADDON" 1 "ASM3042 USB 3.2 Gen 1 xHCI Controller" "PCIe Add-in" "USB 3.2 Gen 1"
db_add "1b21:3142" "ADDON" 1 "ASM3142 USB 3.2 Gen 2x1 xHCI Controller" "PCIe Add-in" "USB 3.2 Gen 2"
db_add "1b21:3242" "ADDON" 1 "ASM3242 USB 3.2 Host Controller" "PCIe Add-in" "USB 3.2 Gen 2x2"
db_add "1b21:2425" "ADDON" 1 "ASM4242 USB4 / Thunderbolt 3 Host Router" "PCIe Add-in" "USB4/TB3"
db_add "1b21:2426" "ADDON" 1 "ASM4242 USB 3.2 xHCI Controller" "PCIe Add-in" "USB 3.2"
db_add "1106:3483" "ADDON" 1 "VL805/806 xHCI USB 3.0 Controller" "PCIe Add-in" "USB 3.0"
db_add "1106:3432" "ADDON" 1 "VL800/801 xHCI USB 3.0 Controller" "PCIe Add-in" "USB 3.0"
db_add "1b73:1000" "ADDON" 1 "FL1000G USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1b73:1009" "ADDON" 1 "FL1009 USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1b73:1100" "ADDON" 1 "FL1100 USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1b73:1400" "ADDON" 1 "FL1400 USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1b6f:7023" "ADDON" 1 "EJ168 USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1b6f:7052" "ADDON" 1 "EJ188/EJ198 USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1912:0014" "ADDON" 1 "uPD720201 USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"
db_add "1912:0015" "ADDON" 1 "uPD720202 USB 3.0 Host Controller" "PCIe Add-in" "USB 3.0"

get_controller_info() {
  local vid="${1,,}" did="${2,,}" key="${1,,}:${2,,}"

  if [[ -n "${CTRL_DB[$key]:-}" ]]; then
    printf '%s\n' "${CTRL_DB[$key]}"
    return
  fi

  if [[ "$vid" == "8086" ]]; then
    printf '%s\n' "CHIPSET|1|Intel USB Controller|Unknown PCH (DID:$did)|USB 3.x"
    return
  fi

  if [[ "$vid" == "1022" ]]; then
    printf '%s\n' "CHIPSET|1|AMD USB Controller|Unknown Chipset (DID:$did)|USB 3.x"
    return
  fi

  if [[ -n "${VENDOR_FALLBACK[$vid]:-}" ]]; then
    printf '%s\n' "ADDON|1|${VENDOR_FALLBACK[$vid]} Controller|PCIe Add-in|USB 3.x"
    return
  fi

  printf '%s\n' "UNKNOWN|1|Unknown Controller|VID:$vid DID:$did|?"
}

# -----------------------------------------------------------------------------
# Sysfs / PCI helpers
# -----------------------------------------------------------------------------
pci_vid_did() {
  local bdf="$1"
  local base="/sys/bus/pci/devices/$bdf"
  [[ -d "$base" ]] || return 1
  local vid did
  vid="$(read_file "$base/vendor" 2>/dev/null || true)"
  did="$(read_file "$base/device" 2>/dev/null || true)"
  vid="${vid#0x}"
  did="${did#0x}"
  [[ -n "$vid" && -n "$did" ]] || return 1
  printf '%s %s\n' "${vid,,}" "${did,,}"
}

pci_name() {
  local bdf="$1"
  if have lspci; then
    lspci -Dnn -s "$bdf" 2>/dev/null | sed -E 's/^[^ ]+ +//' || true
  fi
}

pci_driver() {
  local bdf="$1"
  local d="/sys/bus/pci/devices/$bdf/driver"
  [[ -L "$d" ]] || return 0
  basename "$(realp "$d")"
}

pci_msi_status() {
  local bdf="$1"
  local d="/sys/bus/pci/devices/$bdf/msi_irqs"
  if [[ -d "$d" ]]; then
    local c
    c=$(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if (( c > 0 )); then
      printf 'MSI/MSI-X'
      return
    fi
  fi
  printf 'Legacy/Unknown'
}

pci_power_state() {
  local bdf="$1"
  local base="/sys/bus/pci/devices/$bdf/power"
  local control runtime
  control="$(read_file "$base/control" 2>/dev/null || true)"
  runtime="$(read_file "$base/runtime_status" 2>/dev/null || true)"
  printf '%s|%s\n' "${control:-unknown}" "${runtime:-unknown}"
}

find_pci_ancestor() {
  local path
  path="$(realp "$1")" || return 1

  while [[ "$path" != "/" && -n "$path" ]]; do
    local base
    base="$(basename "$path")"
    if [[ "$base" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[[:digit:]]$ ]]; then
      printf '%s\n' "$base"
      return 0
    fi
    path="$(dirname "$path")"
  done

  return 1
}

find_usb_device_ancestor() {
  local path
  path="$(realp "$1")" || return 1

  while [[ "$path" != "/" && -n "$path" ]]; do
    if [[ -r "$path/idVendor" && -r "$path/idProduct" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
    path="$(dirname "$path")"
  done

  return 1
}

count_hubs_between_device_and_root() {
  local usbdev="$1"
  local path
  path="$(realp "$usbdev")" || return 1

  local count=0
  local names=()

  while [[ "$path" != "/" && -n "$path" ]]; do
    local base
    base="$(basename "$path")"

    # stop at root hub node (usbX)
    if [[ "$base" =~ ^usb[0-9]+$ ]]; then
      break
    fi

    if [[ -r "$path/bDeviceClass" ]]; then
      local cls prod
      cls="$(read_file "$path/bDeviceClass" 2>/dev/null || true)"
      prod="$(read_file "$path/product" 2>/dev/null || true)"
      if [[ "${cls,,}" == "09" ]]; then
        ((count++))
        names+=("${prod:-USB Hub}")
      fi
    fi

    path="$(dirname "$path")"
  done

  printf '%s|' "$count"
  if ((${#names[@]})); then
    local IFS=' -> '
    printf '%s\n' "${names[*]}"
  else
    printf '\n'
  fi
}

usb_busport_path() {
  local usbdev="$1"
  basename "$usbdev"
}

usb_speed() {
  local usbdev="$1"
  read_file "$usbdev/speed" 2>/dev/null || true
}

usb_name() {
  local usbdev="$1"
  local prod man
  prod="$(read_file "$usbdev/product" 2>/dev/null || true)"
  man="$(read_file "$usbdev/manufacturer" 2>/dev/null || true)"
  if [[ -n "$prod" && -n "$man" && "$prod" != "$man" ]]; then
    printf '%s %s\n' "$man" "$prod"
  elif [[ -n "$prod" ]]; then
    printf '%s\n' "$prod"
  else
    printf '%s\n' "$(basename "$usbdev")"
  fi
}

usb_vid_pid() {
  local usbdev="$1"
  local vid pid
  vid="$(read_file "$usbdev/idVendor" 2>/dev/null || true)"
  pid="$(read_file "$usbdev/idProduct" 2>/dev/null || true)"
  printf '%s %s\n' "${vid^^}" "${pid^^}"
}

usb_power_info() {
  local usbdev="$1"
  local base="$usbdev/power"
  local control autosuspend runtime
  control="$(read_file "$base/control" 2>/dev/null || true)"
  autosuspend="$(read_file "$base/autosuspend_delay_ms" 2>/dev/null || true)"
  runtime="$(read_file "$base/runtime_status" 2>/dev/null || true)"
  printf '%s|%s|%s\n' "${control:-unknown}" "${autosuspend:-unknown}" "${runtime:-unknown}"
}

system_usb_autosuspend() {
  local p="/sys/module/usbcore/parameters/autosuspend"
  if [[ -r "$p" ]]; then
    local v
    v="$(read_file "$p")"
    if [[ "$v" == "-1" ]]; then
      printf 'disabled'
    else
      printf '%s ms' "$v"
    fi
  else
    printf 'unknown'
  fi
}

# -----------------------------------------------------------------------------
# Data stores
# -----------------------------------------------------------------------------
# Controller row:
# BDF|VID|DID|TYPE|CHIP|NAME|PLATFORM|USB|MSI|PWRCTRL|PWRSTATE|DRIVER
declare -A CONTROLLERS

# Device row:
# USBDEV|NAME|SHORT|VID|PID|CHIPCOUNT|HUBCOUNT|HUBNAMES|CTRLBDF|CTRLNAME|CTRLTYPE|PORTPATH|SPEED
declare -A DEVICES

HAS_CHIP0=0
HAS_CHIP1=0
declare -a OPTIMIZATIONS=()

controller_add_if_missing() {
  local bdf="$1"
  [[ -n "$bdf" ]] || return

  if [[ -n "${CONTROLLERS[$bdf]:-}" ]]; then
    return
  fi

  local vid did info type chip name platform usb msi pwr driver
  read -r vid did < <(pci_vid_did "$bdf" 2>/dev/null || echo "???? ????")
  IFS='|' read -r type chip name platform usb < <(get_controller_info "$vid" "$did")
  msi="$(pci_msi_status "$bdf")"
  pwr="$(pci_power_state "$bdf")"
  driver="$(pci_driver "$bdf")"

  CONTROLLERS["$bdf"]="$bdf|$vid|$did|$type|$chip|$name|$platform|$usb|$msi|$pwr|$driver"

  if [[ "$chip" == "0" ]]; then
    HAS_CHIP0=1
  else
    HAS_CHIP1=1
  fi

  IFS='|' read -r pwrctrl pwrstate <<< "$pwr"
  if [[ "$pwrctrl" == "auto" ]]; then
    OPTIMIZATIONS+=("PCI_RUNTIME_PM|$bdf|$name|Set PCI runtime PM to on")
  fi
}

device_add() {
  local usbdev="$1"
  [[ -n "$usbdev" ]] || return

  # Dedup by physical USB device path
  local key
  key="$(realp "$usbdev" 2>/dev/null || true)"
  [[ -n "$key" ]] || return
  [[ -n "${DEVICES[$key]:-}" ]] && return

  local bdf
  bdf="$(find_pci_ancestor "$usbdev" 2>/dev/null || true)"
  [[ -n "$bdf" ]] || return

  controller_add_if_missing "$bdf"

  local name short vid pid hub_info hubcount hubnames portpath speed
  name="$(usb_name "$usbdev")"
  short="$(short_name "$name")"
  read -r vid pid < <(usb_vid_pid "$usbdev")
  IFS='|' read -r hubcount hubnames < <(count_hubs_between_device_and_root "$usbdev")
  portpath="$(usb_busport_path "$usbdev")"
  speed="$(usb_speed "$usbdev")"

  local ctrl_row
  ctrl_row="${CONTROLLERS[$bdf]}"
  local _bdf cvid cdid ctype cchip cname cplatform cusb cmsi cpwr cdriver
  IFS='|' read -r _bdf cvid cdid ctype cchip cname cplatform cusb cmsi cpwr cdriver <<< "$ctrl_row"

  local chipcount=$(( cchip + hubcount ))

  DEVICES["$key"]="$usbdev|$name|$short|$vid|$pid|$chipcount|$hubcount|$hubnames|$bdf|$cname|$ctype|$portpath|$speed"

  local pwr
  pwr="$(usb_power_info "$usbdev")"
  IFS='|' read -r uctrl _uauto _uruntime <<< "$pwr"
  if [[ "$uctrl" == "auto" ]]; then
    OPTIMIZATIONS+=("USB_AUTOSUSPEND|$usbdev|$name|Set USB runtime PM to on")
  fi
}

# -----------------------------------------------------------------------------
# Input device collection
# -----------------------------------------------------------------------------
collect_input_devices() {
  local -a events=()
  local ev

  for ev in /sys/class/input/event*; do
    [[ -e "$ev" ]] || continue
    events+=("$ev")
  done

  local total="${#events[@]}"
  (( total > 0 )) || return

  local i=0
  for ev in "${events[@]}"; do
    ((i++))
    local pct=$(( 30 + (i * 65 / total) ))
    if (( i % 2 == 0 )); then
      progress "$pct" "Tracing input device $i of $total..."
    fi

    local devpath usbdev
    devpath="$(realp "$ev/device" 2>/dev/null || true)"
    [[ -n "$devpath" ]] || continue

    usbdev="$(find_usb_device_ancestor "$devpath" 2>/dev/null || true)"
    [[ -n "$usbdev" ]] || continue

    # Ignore root hubs themselves
    if [[ "$(basename "$usbdev")" =~ ^usb[0-9]+$ ]]; then
      continue
    fi

    # Ignore interfaces; only want full USB device nodes
    if [[ ! -r "$usbdev/idVendor" || ! -r "$usbdev/idProduct" ]]; then
      continue
    fi

    device_add "$usbdev"
  done
}

# -----------------------------------------------------------------------------
# Display
# -----------------------------------------------------------------------------
show_tree() {
  echo
  echo -e "  ${DIM}Count chips between your device and CPU. More chips = more latency.${RESET}"
  echo
  echo -e "  ${MINT}${BOLD}0 CHIPS${RESET}  device ${MINT}---${RESET} [CPU]"
  echo -e "  ${ORANGE}${BOLD}1 CHIP${RESET}   device -${ORANGE}[CHIPSET]${RESET}- [CPU]"
  echo -e "  ${CORAL}${BOLD}2 CHIPS${RESET}  device -${CORAL}[HUB]${RESET}-[CHIPSET]- [CPU]"
  echo
  echo -e "  ${DIM}=============================================================${RESET}"
  echo

  local -a chip0 chip1 chip2
  local k row chip name
  for k in "${!DEVICES[@]}"; do
    row="${DEVICES[$k]}"
    IFS='|' read -r _usb name _short _vid _pid chip _hubcount _hubnames _bdf _cname _ctype _portpath _speed <<< "$row"
    if (( chip == 0 )); then
      chip0+=("$name")
    elif (( chip == 1 )); then
      chip1+=("$name")
    else
      chip2+=("$name")
    fi
  done

  if ((${#DEVICES[@]} == 0)); then
    echo -e "  ${DIM}No USB input devices detected${RESET}"
  else
    if (( HAS_CHIP0 == 0 )); then
      echo -e "  ${ORANGE}! This system appears to have no direct CPU USB for the detected devices${RESET}"
      echo -e "  ${DIM}  1 chip is probably your best option here${RESET}"
      echo
    fi

    local i count
    if ((${#chip0[@]})); then
      echo -e "  ${MINT}0 chips${RESET} ${DIM}- direct to CPU${RESET}"
      count=${#chip0[@]}
      for ((i=0; i<count; i++)); do
        local branch="|-"
        (( i == count - 1 )) && branch="'-"
        echo -e "    ${DIM}${branch}${RESET} ${MINT}${chip0[$i]}${RESET}"
      done
      echo
    fi

    if ((${#chip1[@]})); then
      echo -e "  ${ORANGE}1 chip${RESET} ${DIM}- through chipset / add-in${RESET}"
      count=${#chip1[@]}
      for ((i=0; i<count; i++)); do
        local branch="|-"
        (( i == count - 1 )) && branch="'-"
        echo -e "    ${DIM}${branch}${RESET} ${ORANGE}${chip1[$i]}${RESET}"
      done
      echo
    fi

    if ((${#chip2[@]})); then
      echo -e "  ${CORAL}2+ chips${RESET} ${DIM}- through hub(s)${RESET}"
      count=${#chip2[@]}
      for ((i=0; i<count; i++)); do
        local branch="|-"
        (( i == count - 1 )) && branch="'-"
        echo -e "    ${DIM}${branch}${RESET} ${CORAL}${chip2[$i]}${RESET}"
      done
      echo
    fi
  fi

  echo -e "  ${DIM}=============================================================${RESET}"
  echo
  echo -e "  ${DIM}Move the device to another port, then rerun the script.${RESET}"
  echo
}

show_full_analysis() {
  echo -e "  ${WHITE}${BOLD}CONTROLLERS${RESET}"
  echo -e "  ${BORDER}---------------------------------------------------------------------${RESET}"

  local -a sorted_ctrls
  mapfile -t sorted_ctrls < <(
    for bdf in "${!CONTROLLERS[@]}"; do
      IFS='|' read -r _bdf _vid _did _type chip _name _platform _usb _msi _pwr _driver <<< "${CONTROLLERS[$bdf]}"
      printf '%s\t%s\n' "$chip" "$bdf"
    done | sort -n | awk '{print $2}'
  )

  local bdf row vid did type chip name platform usb msi pwr driver pwrctrl pwrstate
  for bdf in "${sorted_ctrls[@]}"; do
    row="${CONTROLLERS[$bdf]}"
    IFS='|' read -r _bdf vid did type chip name platform usb msi pwr driver <<< "$row"
    IFS='|' read -r pwrctrl pwrstate <<< "$pwr"

    local chipColor chipLabel
    case "$chip" in
      0) chipColor="$MINT";   chipLabel="CHIP 0 - CPU ATTACHED" ;;
      1) chipColor="$ORANGE"; chipLabel="CHIP 1 - CHIPSET / ADD-IN" ;;
      *) chipColor="$CORAL";  chipLabel="CHIP $chip" ;;
    esac

    echo
    echo -e "  ${chipColor}${chipLabel}${RESET}"
    echo "      $name"
    echo -e "      ${DIM}BDF:$bdf VID:$vid DID:$did | $platform | $usb${RESET}"
    echo -e "      IRQ: ${WHITE}${msi}${RESET}"
    echo -e "      ${DIM}PCI runtime PM: control=${pwrctrl:-unknown}, status=${pwrstate:-unknown}${RESET}"
    [[ -n "$driver" ]] && echo -e "      ${DIM}Driver: $driver${RESET}"

    local -a attached=()
    local dk drow dname dchip dhubcount
    for dk in "${!DEVICES[@]}"; do
      drow="${DEVICES[$dk]}"
      IFS='|' read -r _usb dname _short _vid _pid dchip dhubcount _hubnames dbdf _cname _ctype _portpath _speed <<< "$drow"
      if [[ "$dbdf" == "$bdf" ]]; then
        attached+=("$dname|$dhubcount")
      fi
    done

    if ((${#attached[@]})); then
      echo -e "      ${DIM}Devices:${RESET}"
      local i count=${#attached[@]}
      for ((i=0; i<count; i++)); do
        local branch="|-"
        (( i == count - 1 )) && branch="'-"
        IFS='|' read -r dname dhubcount <<< "${attached[$i]}"
        if (( dhubcount > 0 )); then
          echo -e "        ${DIM}${branch}${RESET} $dname ${CORAL}(+${dhubcount} hub)${RESET}"
        else
          echo -e "        ${DIM}${branch}${RESET} $dname"
        fi
      done
    fi
  done

  echo
  echo -e "  ${WHITE}${BOLD}INPUT DEVICES${RESET}"
  echo -e "  ${BORDER}---------------------------------------------------------------------${RESET}"

  local -a sorted_devs
  mapfile -t sorted_devs < <(
    for k in "${!DEVICES[@]}"; do
      IFS='|' read -r _usb _name _short _vid _pid chip _hubcount _hubnames _bdf _cname _ctype _portpath _speed <<< "${DEVICES[$k]}"
      printf '%s\t%s\n' "$chip" "$k"
    done | sort -n | awk '{print $2}'
  )

  local k row name short vid pid chipcount hubcount hubnames ctrlbdf ctrlname ctrltype portpath speed
  for k in "${sorted_devs[@]}"; do
    row="${DEVICES[$k]}"
    IFS='|' read -r _usb name short vid pid chipcount hubcount hubnames ctrlbdf ctrlname ctrltype portpath speed <<< "$row"

    local chipColor chipLabel
    case "$chipcount" in
      0) chipColor="$MINT";   chipLabel="CHIP 0 - CPU" ;;
      1) chipColor="$ORANGE"; chipLabel="CHIP 1 - CHIPSET / ADD-IN" ;;
      2) chipColor="$CORAL";  chipLabel="CHIP 2 - HUB" ;;
      *) chipColor="$CORAL";  chipLabel="CHIP $chipcount - HUB" ;;
    esac

    echo
    echo -e "  ${WHITE}$name${RESET}"
    echo -e "      ${DIM}VID:$vid PID:$pid | USB path:$portpath | Speed:${speed:-?} Mb/s${RESET}"
    echo -e "      ${chipColor}${chipLabel}${RESET}"
    echo -e "      ${DIM}Controller: $ctrlname ($ctrlbdf)${RESET}"
    if [[ -n "$hubnames" ]]; then
      echo -e "      ${DIM}Hubs: $hubnames${RESET}"
    fi
  done

  echo
  echo -e "  ${WHITE}${BOLD}SYSTEM USB POWER${RESET}"
  echo -e "  ${BORDER}---------------------------------------------------------------------${RESET}"
  echo -e "  ${DIM}usbcore.autosuspend: $(system_usb_autosuspend)${RESET}"

  echo
  echo -e "  ${BORDER}=====================================================================${RESET}"
  echo
}

apply_optimization() {
  local kind="$1" target="$2" name="$3"

  if (( EUID != 0 )); then
    echo
    echo -e "  ${ORANGE}! Run as root to apply changes${RESET}"
    echo
    return
  fi

  echo
  case "$kind" in
    USB_AUTOSUSPEND)
      if [[ -w "$target/power/control" ]]; then
        echo on > "$target/power/control"
        echo -e "  ${MINT}[OK]${RESET} Disabled USB autosuspend for $name"
      else
        echo -e "  ${CORAL}[FAIL]${RESET} Cannot write $target/power/control"
      fi
      ;;
    PCI_RUNTIME_PM)
      if [[ -w "/sys/bus/pci/devices/$target/power/control" ]]; then
        echo on > "/sys/bus/pci/devices/$target/power/control"
        echo -e "  ${MINT}[OK]${RESET} Disabled PCI runtime PM for $name"
      else
        echo -e "  ${CORAL}[FAIL]${RESET} Cannot write /sys/bus/pci/devices/$target/power/control"
      fi
      ;;
    GLOBAL_AUTOSUSPEND)
      if [[ -w /sys/module/usbcore/parameters/autosuspend ]]; then
        echo -1 > /sys/module/usbcore/parameters/autosuspend
        echo -e "  ${MINT}[OK]${RESET} Disabled global USB autosuspend"
        echo -e "  ${DIM}(temporary until reboot unless persisted via kernel cmdline/modprobe config)${RESET}"
      else
        echo -e "  ${CORAL}[FAIL]${RESET} Cannot write /sys/module/usbcore/parameters/autosuspend"
      fi
      ;;
  esac
  echo
}

show_optimizations() {
  local global_auto
  global_auto="$(system_usb_autosuspend)"
  if [[ "$global_auto" != "disabled" ]]; then
    OPTIMIZATIONS+=("GLOBAL_AUTOSUSPEND|global|Linux usbcore|Disable global USB autosuspend")
  fi

  # Deduplicate
  local -A seen
  local -a uniq=()
  local x
  for x in "${OPTIMIZATIONS[@]}"; do
    [[ -n "${seen[$x]:-}" ]] && continue
    seen["$x"]=1
    uniq+=("$x")
  done
  OPTIMIZATIONS=("${uniq[@]}")

  ((${#OPTIMIZATIONS[@]})) || return

  echo -e "  ${WHITE}${BOLD}OPTIMIZATIONS AVAILABLE${RESET}"
  echo -e "  ${BORDER}---------------------------------------------------------------------${RESET}"
  echo

  if (( EUID != 0 )); then
    echo -e "  ${ORANGE}! To apply optimizations: run as root${RESET}"
    echo
    local i=0 count=${#OPTIMIZATIONS[@]}
    local kind target name desc branch
    for x in "${OPTIMIZATIONS[@]}"; do
      ((i++))
      branch="|-"
      (( i == count )) && branch="'-"
      IFS='|' read -r kind target name desc <<< "$x"
      echo -e "  ${DIM}${branch}${RESET} $desc on ${DIM}$name${RESET}"
    done
    echo
    return
  fi

  local idx=1 kind target name desc
  for x in "${OPTIMIZATIONS[@]}"; do
    IFS='|' read -r kind target name desc <<< "$x"
    echo -e "  ${SKY}[$idx]${RESET} $desc"
    echo -e "      ${DIM}$name${RESET}"
    echo
    ((idx++))
  done

  read -r -p "  Enter number to apply, or press Enter to skip: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local n=$((choice - 1))
    if (( n >= 0 && n < ${#OPTIMIZATIONS[@]} )); then
      IFS='|' read -r kind target name desc <<< "${OPTIMIZATIONS[$n]}"
      apply_optimization "$kind" "$target" "$name"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
clear

echo
echo -e "  ${SKY}${BOLD}USB LATENCY ANALYZER (LINUX)${RESET}"
echo -e "  ${DIM}=====================================================================${RESET}"
echo

if ! have lspci; then
  echo -e "  ${CORAL}pciutils is required.${RESET}"
  echo "  Install it, then rerun:"
  echo "    Debian/Ubuntu: sudo apt install pciutils"
  echo "    Fedora:        sudo dnf install pciutils"
  echo "    Arch:          sudo pacman -S pciutils"
  exit 1
fi

progress 5 "Checking USB power settings..."
sleep 0.05

progress 15 "Scanning USB controllers..."
# Prime controllers from USB root hubs if present
for root in /sys/bus/usb/devices/usb*; do
  [[ -e "$root" ]] || continue
  bdf="$(find_pci_ancestor "$root" 2>/dev/null || true)"
  [[ -n "$bdf" ]] && controller_add_if_missing "$bdf"
done

progress 30 "Finding input devices..."
collect_input_devices

clear_status_line
echo -e "  ${MINT}[OK]${RESET} ${DIM}Ready${RESET}"
sleep 0.1

show_tree
show_full_analysis
show_optimizations