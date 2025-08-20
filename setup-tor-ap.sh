#!/usr/bin/env bash
# Raspberry Pi Tor Access Point setup script
# Configures a Raspberry Pi running Raspberry Pi OS Bookworm with NetworkManager
# to operate as a Wi-Fi access point whose clients are transparently routed
# through Tor.

set -Eeuo pipefail
IFS=$'\n\t'

# Colors for techno-thriller console output
GREEN=$'\e[32m'
RED=$'\e[31m'
BLUE=$'\e[34m'
NC=$'\e[0m'

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
        echo "UNKNOWN PARAM: $1" >&2
        exit 1
      fi
      ;;
  esac
done

if (( ! UNINSTALL )) && [[ -z $PSK ]]; then
  echo "USAGE: $0 [--dry-run] [--uninstall] <psk>" >&2
  exit 1
fi

run_cmd() {
  printf '%b>>> %s%b\n' "$BLUE" "$*" "$NC"
  if ((DRY_RUN)); then
    return 0
  fi
  if ! eval "$@"; then
    printf '%b!!! Command failed: %s%b\n' "$RED" "$*" "$NC" >&2
    return 1
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    printf '%bACCESS DENIED:%b root privileges required\n' "$RED" "$NC" >&2
    exit 1
  fi
}

check_bookworm() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ ${VERSION_CODENAME:-} != "bookworm" ]]; then
      printf '%bINCOMPATIBLE OS:%b Raspberry Pi OS Bookworm required\n' "$RED" "$NC" >&2
      exit 1
    fi
  else
    printf '%bSYSTEM FILE MISSING:%b /etc/os-release\n' "$RED" "$NC" >&2
    exit 1
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
    echo "SENSOR FAILURE: interface $AP_IFACE offline" >&2
    exit 1
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
    echo "Broadcasting QR frequency:"; qrencode -t ansiutf8 "WIFI:S:${SSID};T:WPA;P:${PSK};;" || true
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
    echo "Unable to archive firewall rules to /etc/iptables/rules.v4" >&2
    return 1
  fi
  if [[ -f /etc/iptables.ipv4.nat ]]; then
    if ! run_cmd "iptables-save > /etc/iptables.ipv4.nat"; then
      echo "Unable to archive firewall rules to /etc/iptables.ipv4.nat" >&2
      return 1
    fi
  fi
  run_cmd "iptables -t nat -L -n -v"
}

iptables_rule() {
  local rule=$1
    echo "Deploying firewall rule: $rule"
  if iptables ${rule/-A/-C} 2>/dev/null; then
      echo " - rule already in place"
  else
    if ! run_cmd "iptables $rule"; then
        echo " - failed to deploy rule: $rule" >&2
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
      echo "ALERT: Tor service inactive; stripping Tor NAT rules."
    remove_tor_iptables
  fi
}

summary() {
  echo -e "\n=== Mission Summary ==="
  echo "SSID: $SSID"
  echo "Access Point IP: $AP_GATEWAY"
  systemctl is-active --quiet tor && tor_status="active" || tor_status="inactive"
  echo "Tor service: $tor_status"
  echo "iptables NAT table:"; iptables -t nat -L -n -v | sed -n '1,120p'
}

verify_all() {
  local ok=1
  echo "Diagnostics:"
  nmcli -t -f NAME,DEVICE,STATE connection show --active | \
    grep -Fxq "tor-ap:${AP_IFACE}:activated" && \
    echo " - Hotspot link active" || { echo " - Hotspot link inactive"; ok=0; }
  iptables -t nat -C PREROUTING -i "${AP_IFACE}" -p tcp --dport 22 -j REDIRECT --to-ports 22 2>/dev/null && \
    echo " - SSH redirect engaged" || { echo " - SSH redirect missing"; ok=0; }
  iptables -t nat -C PREROUTING -i "${AP_IFACE}" -p udp --dport 53 -j REDIRECT --to-ports "${TOR_DNS_PORT}" 2>/dev/null && \
    echo " - DNS redirect engaged" || { echo " - DNS redirect missing"; ok=0; }
  iptables -t nat -C PREROUTING -i "${AP_IFACE}" -p tcp --syn -j REDIRECT --to-ports "${TOR_TRANS_PORT}" 2>/dev/null && \
    echo " - TCP redirect engaged" || { echo " - TCP redirect missing"; ok=0; }
  systemctl is-active --quiet tor && \
    echo " - Tor service active" || { echo " - Tor service inactive"; ok=0; }
  sysctl -n net.ipv4.ip_forward | grep -Fxq 1 && \
    echo " - IP forwarding engaged" || { echo " - IP forwarding offline"; ok=0; }
  if ((ok)); then
    echo "Systems check: all green."
  else
    echo "Diagnostics report: anomalies detected." >&2
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
  echo "Uninstall protocol complete"
}

iptables_unrule() {
  local rule=$1
  iptables ${rule/-D/-C} 2>/dev/null && run_cmd "iptables $rule" || true
}

main() {
  require_root
  check_bookworm
  printf '%b>> Initiating Toratora deployment...%b\n' "$GREEN" "$NC"
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
