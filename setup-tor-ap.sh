#!/usr/bin/env bash
# Raspberry Pi Tor Access Point setup script
# Configures a Raspberry Pi running Raspberry Pi OS Bookworm with NetworkManager
# to operate as a Wi-Fi access point whose clients are transparently routed
# through Tor.

set -Eeuo pipefail
IFS=$'\n\t'

#===========================
# Retro console formatting
GREEN="\e[32m"
RED="\e[31m"
AMBER="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
BLINK="\e[5m"
RESET="\e[0m"

timestamp() { date "+%H:%M:%S"; }

divider() { printf "${CYAN}▓▒░$(printf '%0.s─' {1..60})░▒▓${RESET}\n"; }

info() { printf "${GREEN}${BOLD}[%s] SYS/4829.CTRL:%s${RESET}\n" "$(timestamp)" " $*"; }
warn() { printf "${AMBER}${BOLD}[%s] SYS/4829.STAT:%s${RESET}\n" "$(timestamp)" " $*"; }
alert() { printf "${RED}${BOLD}${BLINK}[%s] SYS/4829.ALERT:%s !!!${RESET}\n" "$(timestamp)" " $*" >&2; }

banner() {
  echo -e "${GREEN}${BOLD}"
  cat <<'EOF'
 ████████╗ ██████╗ ██████╗  █████╗ ████████╗ ██████╗ ██████╗  █████╗ 
 ╚══██╔══╝██╔═══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗██╔══██╗
    ██║   ██║   ██║██████╔╝███████║   ██║   ██║   ██║██████╔╝███████║
    ██║   ██║   ██║██╔══██╗██╔══██║   ██║   ██║   ██║██╔══██╗██╔══██║
    ██║   ╚██████╔╝██║  ██║██║  ██║   ██║   ╚██████╔╝██║  ██║██║  ██║
    ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
EOF
  echo -e "${RESET}${AMBER}${BOLD}>>> INITIALIZING SECURE NODE LINK <<<${RESET}"
  divider
}

#===========================
# Configuration (override via environment except SSID)
AP_IFACE=${AP_IFACE:-wlan0}
WAN_IFACE=${WAN_IFACE:-eth0}
AP_SUBNET=${AP_SUBNET:-192.168.220.0/24}
AP_GATEWAY=${AP_GATEWAY:-192.168.220.1}
SSID=toratora
TOR_TRANS_PORT=${TOR_TRANS_PORT:-9040}
TOR_DNS_PORT=${TOR_DNS_PORT:-53}
#===========================

DRY_RUN=0
UNINSTALL=0
PSK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    *)
      if [[ -z $PSK ]]; then
        PSK=$1
        shift
      else
        alert "Unknown option: $1"; exit 1
      fi
      ;;
  esac
done

if (( ! UNINSTALL )) && [[ -z $PSK ]]; then
  alert "Usage: $0 [--dry-run] [--uninstall] <psk>"; exit 1
fi

spinner() {
  local pid=$1
  local spin='|/-\\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${CYAN}${BOLD}[DECRYPTING %s]${RESET}" "${spin:i++%${#spin}:1}"
    sleep 0.1
  done
  printf "\r\033[K"
}

run_cmd() {
  warn "+ $* [BEEP]"
  if ((DRY_RUN)); then
    warn "[DRY-RUN] Command skipped"; return 0
  fi
  eval "$@" &
  local cmd_pid=$!
  spinner $cmd_pid &
  local spin_pid=$!
  wait $cmd_pid
  local status=$?
  kill $spin_pid 2>/dev/null; wait $spin_pid 2>/dev/null
  if ((status)); then
    alert "Command failed: $*"
    return 1
  fi
  info "[CONNECTION ESTABLISHED]"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    alert "This script must be run as root"; exit 1
  fi
}

check_bookworm() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ ${VERSION_CODENAME:-} != "bookworm" ]]; then
      alert "This script supports Raspberry Pi OS Bookworm only"; exit 1
    fi
  else
    alert "/etc/os-release not found"; exit 1
  fi
}

ensure_packages() {
  local packages=(tor iptables iptables-persistent qrencode network-manager)
  local IFS=' '
  run_cmd "apt-get update"
  run_cmd "apt-get -y upgrade"
  run_cmd "apt-get -y install ${packages[*]}"
}

ensure_sysctl() {
  local file=/etc/sysctl.d/99-tor-ap.conf
  if [[ ! -f $file ]]; then
    run_cmd "echo 'net.ipv4.ip_forward=1' > $file"
  else
    grep -Fqx 'net.ipv4.ip_forward=1' "$file" || run_cmd "echo 'net.ipv4.ip_forward=1' >> $file"
  fi
  run_cmd "sysctl --system"
}

ensure_hotspot() {
  if ! ip link show "$AP_IFACE" &>/dev/null; then
    alert "Interface $AP_IFACE not found"; exit 1
  fi
  local con_name="tor-ap"
  if ! nmcli -t -f NAME connection show | grep -Fxq "$con_name"; then
    run_cmd "nmcli dev wifi hotspot ifname '$AP_IFACE' con-name '$con_name' ssid '$SSID' password '$PSK'"
  else
    run_cmd "nmcli connection modify '$con_name' 802-11-wireless.ssid '$SSID' 802-11-wireless-security.psk '$PSK'"
  fi
  run_cmd "nmcli connection modify '$con_name' ipv4.addresses '$AP_GATEWAY/24' ipv4.method shared ipv4.gateway '$AP_GATEWAY'"
  run_cmd "nmcli connection up '$con_name'"
  if command -v qrencode &>/dev/null; then
    info "Hotspot QR code:"; qrencode -t ansiutf8 "WIFI:S:${SSID};T:WPA;P:${PSK};;" || true
  fi
}

ensure_torrc() {
  local torrc=/etc/tor/torrc
  if [[ ! -f ${torrc}.bak ]]; then
    run_cmd "cp '$torrc' '${torrc}.bak'"
  fi
  run_cmd "sed -i '/^TransListenAddress/d;/^DNSListenAddress/d' '$torrc'"
  ensure_line "$torrc" "Log notice file /var/log/tor/notices.log"
  ensure_line "$torrc" "VirtualAddrNetwork 10.192.0.0/10"
  ensure_line "$torrc" "AutomapHostsSuffixes .onion,.exit"
  ensure_line "$torrc" "AutomapHostsOnResolve 1"
  ensure_line "$torrc" "TransPort ${AP_GATEWAY}:${TOR_TRANS_PORT}"
  ensure_line "$torrc" "DNSPort ${AP_GATEWAY}:${TOR_DNS_PORT}"
  run_cmd "install -m 0644 -o debian-tor -g debian-tor /dev/null /var/log/tor/notices.log"
}

ensure_line() {
  local file=$1
  local line=$2
  grep -Fqx "$line" "$file" || run_cmd "echo '$line' >> '$file'"
}

ensure_iptables() {
  iptables_rule "-t nat -A PREROUTING -i ${AP_IFACE} -p tcp --dport 22 -j REDIRECT --to-ports 22"
  iptables_rule "-t nat -A PREROUTING -i ${AP_IFACE} -p udp --dport 53 -j REDIRECT --to-ports ${TOR_DNS_PORT}"
  iptables_rule "-t nat -A PREROUTING -i ${AP_IFACE} -p tcp --syn -j REDIRECT --to-ports ${TOR_TRANS_PORT}"
  if ! run_cmd "iptables-save > /etc/iptables/rules.v4"; then
    alert "Failed to save iptables rules to /etc/iptables/rules.v4"
    return 1
  fi
  if [[ -f /etc/iptables.ipv4.nat ]]; then
    if ! run_cmd "iptables-save > /etc/iptables.ipv4.nat"; then
      alert "Failed to save iptables rules to /etc/iptables.ipv4.nat"
      return 1
    fi
  fi
  run_cmd "iptables -t nat -L -n -v"
}

iptables_rule() {
  local rule=$1
  warn "Configuring iptables rule: $rule"
  if iptables ${rule/-A/-C} 2>/dev/null; then
    info " - Rule already exists"
  else
    if ! run_cmd "iptables $rule"; then
      alert " - Failed to apply rule: $rule"
      return 1
    fi
  fi
}

remove_tor_iptables() {
  iptables_unrule "-t nat -D PREROUTING -i ${AP_IFACE} -p tcp --dport 22 -j REDIRECT --to-ports 22"
  iptables_unrule "-t nat -D PREROUTING -i ${AP_IFACE} -p udp --dport 53 -j REDIRECT --to-ports ${TOR_DNS_PORT}"
  iptables_unrule "-t nat -D PREROUTING -i ${AP_IFACE} -p tcp --syn -j REDIRECT --to-ports ${TOR_TRANS_PORT}"
  run_cmd "iptables-save > /etc/iptables/rules.v4"
  [[ -f /etc/iptables.ipv4.nat ]] && run_cmd "iptables-save > /etc/iptables.ipv4.nat"
}

start_services() {
  run_cmd "systemctl enable --now tor"
  for i in {1..30}; do
    if ip addr show "$AP_IFACE" | grep -q "$AP_GATEWAY"; then
      run_cmd "systemctl restart tor"
      break
    fi
    sleep 1
  done
  if ! systemctl is-active --quiet tor; then
    warn "Tor service inactive; removing Tor NAT rules."
    remove_tor_iptables
  fi
}

summary() {
  divider
  info "SSID: $SSID"
  info "Access Point IP: $AP_GATEWAY"
  systemctl is-active --quiet tor && tor_status="active" || tor_status="inactive"
  info "Tor service: $tor_status"
  info "iptables NAT table:"; iptables -t nat -L -n -v | sed -n '1,120p'
}

verify_all() {
  local ok=1
  warn "Verification:"
  nmcli -t -f NAME,DEVICE,STATE connection show --active | \
    grep -Fxq "tor-ap:${AP_IFACE}:activated" && \
    info " - hotspot active" || { alert " - hotspot inactive"; ok=0; }
  iptables -t nat -C PREROUTING -i "${AP_IFACE}" -p tcp --dport 22 -j REDIRECT --to-ports 22 2>/dev/null && \
    info " - SSH redirect present" || { alert " - SSH redirect missing"; ok=0; }
  iptables -t nat -C PREROUTING -i "${AP_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports "${TOR_DNS_PORT}" 2>/dev/null && \
    info " - DNS redirect present" || { alert " - DNS redirect missing"; ok=0; }
  iptables -t nat -C PREROUTING -i "${AP_IFACE}" -p tcp --syn -j REDIRECT --to-ports "${TOR_TRANS_PORT}" 2>/dev/null && \
    info " - TCP redirect present" || { alert " - TCP redirect missing"; ok=0; }
  systemctl is-active --quiet tor && \
    info " - tor service active" || { alert " - tor service inactive"; ok=0; }
  sysctl -n net.ipv4.ip_forward | grep -Fxq 1 && \
    info " - IP forwarding enabled" || { alert " - IP forwarding disabled"; ok=0; }
  if ((ok)); then
    info "All functionality verified."
  else
    alert "One or more checks failed."
    return 1
  fi
}

uninstall() {
  local torrc=/etc/tor/torrc
  run_cmd "systemctl disable --now tor" || true
  run_cmd "nmcli connection delete 'tor-ap'" || true
  run_cmd "sed -i '/Log notice file \/var\/log\/tor\/notices.log/d;/VirtualAddrNetwork 10.192.0.0\/10/d;/AutomapHostsSuffixes .onion,.exit/d;/AutomapHostsOnResolve 1/d;/TransPort ${AP_GATEWAY}:${TOR_TRANS_PORT}/d;/DNSPort ${AP_GATEWAY}:${TOR_DNS_PORT}/d' '$torrc'"
  [[ -f ${torrc}.bak ]] && run_cmd "mv '${torrc}.bak' '$torrc'"
  iptables_unrule "-t nat -D PREROUTING -i ${AP_IFACE} -p tcp --dport 22 -j REDIRECT --to-ports 22"
  iptables_unrule "-t nat -D PREROUTING -i ${AP_IFACE} -p udp --dport 53 -j REDIRECT --to-ports ${TOR_DNS_PORT}"
  iptables_unrule "-t nat -D PREROUTING -i ${AP_IFACE} -p tcp --syn -j REDIRECT --to-ports ${TOR_TRANS_PORT}"
  run_cmd "iptables-save > /etc/iptables/rules.v4"
  [[ -f /etc/iptables.ipv4.nat ]] && run_cmd "iptables-save > /etc/iptables.ipv4.nat"
  run_cmd "rm -f /etc/sysctl.d/99-tor-ap.conf"
  run_cmd "sysctl --system"
  info "Uninstall complete"
}

iptables_unrule() {
  local rule=$1
  iptables ${rule/-D/-C} 2>/dev/null && run_cmd "iptables $rule" || true
}

main() {
  banner
  require_root
  check_bookworm
  if ((UNINSTALL)); then
    uninstall
    return
  fi
  ensure_packages
  ensure_sysctl
  ensure_hotspot
  ensure_torrc
  ensure_iptables
  start_services
  summary
  verify_all
}

main "$@"
