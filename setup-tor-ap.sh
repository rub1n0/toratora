#!/usr/bin/env bash
# ToraTora - Raspberry Pi Tor Access Point installer
# Usage: sudo ./setup-tor-ap.sh --ssid "toratora" --psk "YourStrongPass" --country US --subnet 10.10.0.0/24 --channel 6 [--dry-run] [--revert] [--quiet] [--no-color]

set -euo pipefail

SSID="toratora"
PSK=""
COUNTRY="US"
SUBNET="10.10.0.0/24"
CHANNEL="6"
DRY_RUN=0
REVERT=0
QUIET=0
NO_COLOR=0

TOTAL_STEPS=10
CURRENT_STEP=0

if [ -t 1 ]; then
  IS_TTY=1
else
  IS_TTY=0
fi

if [ "$IS_TTY" -eq 1 ] && [ "$NO_COLOR" -eq 0 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' ; GREEN='' ; YELLOW='' ; BLUE='' ; BOLD='' ; RESET=''
fi

log(){ local lvl="$1"; shift; local col="$1"; shift||true; local msg="$*"; [ "$QUIET" -eq 1 ] && [ "$lvl" = INFO ] && return; printf "%b%s%b\n" "$col" "$msg" "$RESET"; }
info(){ log INFO "$BLUE" "$*"; }
success(){ log INFO "$GREEN" "$*"; }
warn(){ log WARN "$YELLOW" "$*"; }
error(){ log ERROR "$RED" "$*"; }

step(){ CURRENT_STEP=$((CURRENT_STEP+1)); [ "$QUIET" -eq 0 ] && printf "%b▶ [%d/%d] %s%b\n" "$BOLD" "$CURRENT_STEP" "$TOTAL_STEPS" "$1" "$RESET"; }

spinner(){ local pid=$1; local spin='-\|/'; local i=0; [ "$QUIET" -eq 1 ] && { wait "$pid"; return; }; while kill -0 "$pid" 2>/dev/null; do printf "\r%s" "${spin:i++%4:1}"; sleep 0.1; done; printf "\r"; wait "$pid"; }
run_cmd(){ "$@" & spinner $!; }

usage(){ cat <<USAGE
Usage: sudo ./setup-tor-ap.sh --ssid "toratora" --psk "YourStrongPass" --country US --subnet 10.10.0.0/24 --channel 6 [--dry-run] [--revert] [--quiet] [--no-color]
USAGE
exit 1; }

parse_args(){ while [[ $# -gt 0 ]]; do case "$1" in --ssid) SSID="$2"; shift 2;; --psk) PSK="$2"; shift 2;; --country) COUNTRY="$2"; shift 2;; --subnet) SUBNET="$2"; shift 2;; --channel) CHANNEL="$2"; shift 2;; --dry-run) DRY_RUN=1; shift;; --revert) REVERT=1; shift;; --quiet) QUIET=1; shift;; --no-color) NO_COLOR=1; shift;; -h|--help) usage;; *) error "Unknown argument: $1"; usage;; esac; done; if [ -z "$PSK" ] && [ "$REVERT" -eq 0 ]; then read -rp "Enter WPA2 passphrase (min 12 chars): " PSK; fi; if [ ${#PSK} -lt 12 ] && [ "$REVERT" -eq 0 ]; then error "Passphrase must be at least 12 characters"; exit 1; fi; }

backup_file(){
  local f="$1"
  [ -f "$f" ] || return

  local backup_dir="/var/backups/toratora"
  mkdir -p "$backup_dir"

  # Use a sanitized filename to store the backup outside of service config dirs
  local base
  base="${f//\//_}"

  # Remove previous backups for this file to avoid accumulation
  rm -f "$backup_dir/${base}.toratora."*.bak 2>/dev/null || true

  local ts
  ts=$(date +%Y%m%d%H%M%S)
  local b="$backup_dir/${base}.toratora.${ts}.bak"
  cp "$f" "$b"
  BACKUPS+=("$f:$b")
}
write_file(){ local p="$1"; local c="$2"; [ "$DRY_RUN" -eq 1 ] && { info "Would write $p"; return; }; backup_file "$p"; printf "%b" "$c" > "$p"; }
append_if_missing(){ local l="$1" f="$2"; [ "$DRY_RUN" -eq 1 ] && { info "Would ensure line in $f: $l"; return; }; grep -qxF "$l" "$f" 2>/dev/null || echo "$l" >> "$f"; }

BACKUPS=()

revert_changes(){
  warn "Reverting configuration..."
  for pair in "${BACKUPS[@]}"; do
    IFS=: read -r orig backup <<< "$pair"
    [ -f "$backup" ] && mv "$backup" "$orig"
  done
  systemctl disable --now hostapd dnsmasq tor nftables 2>/dev/null || true
  success "Revert complete"
}

print_banner(){ [ "$QUIET" -eq 1 ] && return; cat <<'BANNER'
 _____              _____
|_   _|__  _ __ __ |_   _|__  _ __ __ _
  | |/ _ \| '__/ _` || |/ _ \| '__/ _` |
  | | (_) | | | (_| || | (_) | | | (_| |
  |_|\___/|_|  \__,_||_|\___/|_|  \__,_|
      ToraTora - Tor Wi-Fi Access Point installer
BANNER
}

preflight_checks(){
  step "Preflight checks"
  [ "$EUID" -ne 0 ] && { error "Run as root"; exit 1; }
  systemd-detect-virt --quiet && { error "Virtual environment detected"; exit 1; }
  grep -qi 'Raspberry Pi' /proc/device-tree/model || { error "Not a Raspberry Pi"; exit 1; }
  ip link show eth0 >/dev/null 2>&1 || { error "eth0 missing"; exit 1; }
  ip link show wlan0 >/dev/null 2>&1 || { error "wlan0 missing"; exit 1; }
  ip link show eth0 | grep -q "state UP" || { error "eth0 down"; exit 1; }
  curl -s --head https://check.torproject.org >/dev/null || { error "No Internet connectivity on eth0"; exit 1; }
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_RELEASE="$VERSION_CODENAME"
  [ "$OS_RELEASE" = bookworm ] && FIREWALL_TOOL="nftables" || FIREWALL_TOOL="iptables-nft"
  success "Preflight checks passed"
}
install_packages(){ step "Install packages"; local pkgs=(tor hostapd dnsmasq jq); if [ "$FIREWALL_TOOL" = "nftables" ]; then pkgs+=(nftables); else pkgs+=(iptables iptables-persistent netfilter-persistent); fi; if [ "$DRY_RUN" -eq 1 ]; then info "Would install: ${pkgs[*]}"; return; fi; run_cmd apt-get update -y; run_cmd apt-get install -y "${pkgs[@]}"; }

configure_network(){
  step "Configure network"
  if command -v raspi-config >/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "Would set Wi-Fi country to $COUNTRY"
    else
      run_cmd raspi-config nonint do_wifi_country "$COUNTRY"
    fi
  fi
  local sysctl_conf=/etc/sysctl.d/99-tor-ap.conf
  local sysctl_content="net.ipv4.ip_forward=1\nnet.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1"
  write_file "$sysctl_conf" "$sysctl_content"
  [ "$DRY_RUN" -eq 0 ] && run_cmd sysctl -p "$sysctl_conf"
  if [ "$OS_RELEASE" = bookworm ]; then
    local existing
    existing=$(nmcli -t -f UUID,NAME c show 2>/dev/null | awk -F: '$2=="torap-wlan0"{print $1}')
    if [ -n "$existing" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        info "Would remove existing nmcli connection(s) torap-wlan0"
      else
        for uuid in $existing; do
          run_cmd nmcli con delete "$uuid"
        done
      fi
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      info "Would create nmcli connection torap-wlan0"
    else
      run_cmd nmcli con add type wifi ifname wlan0 con-name torap-wlan0 autoconnect yes ssid "$SSID"
      run_cmd nmcli con modify torap-wlan0 802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel "$CHANNEL" ipv4.method manual ipv4.addresses "10.10.0.1/24" ipv4.gateway "" ipv4.dhcp-hostname "" ipv6.method ignore
      run_cmd nmcli con modify torap-wlan0 wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK"
    fi
  else
    append_if_missing "interface wlan0" /etc/dhcpcd.conf
    append_if_missing "static ip_address=10.10.0.1/24" /etc/dhcpcd.conf
    append_if_missing "nohook wpa_supplicant" /etc/dhcpcd.conf
  fi
  success "Network configured"
}

configure_hostapd(){ step "Configure hostapd"; local conf=/etc/hostapd/hostapd.conf; local content="interface=wlan0\nssid=$SSID\ncountry_code=$COUNTRY\nhw_mode=g\nchannel=$CHANNEL\nieee80211n=1\nwmm_enabled=1\nwpa=2\nwpa_key_mgmt=WPA-PSK\nrsn_pairwise=CCMP\nwpa_passphrase=$PSK"; write_file "$conf" "$content"; append_if_missing "DAEMON_CONF=\"$conf\"" /etc/default/hostapd; success "hostapd configured"; }

configure_dnsmasq(){ step "Configure dnsmasq"; local conf=/etc/dnsmasq.d/tor-ap.conf; local content="interface=wlan0\nbind-interfaces\ndhcp-range=10.10.0.50,10.10.0.200,255.255.255.0,12h\ndhcp-option=option:router,10.10.0.1\nport=0"; write_file "$conf" "$content"; success "dnsmasq configured"; }

configure_tor(){ step "Configure Tor"; local conf=/etc/tor/torrc; local content="Log notice syslog\nUser debian-tor\nDataDirectory /var/lib/tor\nAutomapHostsOnResolve 1\nVirtualAddrNetworkIPv4 10.192.0.0/10\nTransPort 9040\nDNSPort 9053\nAvoidDiskWrites 1"; write_file "$conf" "$content"; success "Tor configured"; }

configure_firewall(){
  step "Configure firewall"
  if [ "$FIREWALL_TOOL" = nftables ]; then
    local conf=/etc/nftables.conf
    local content
    read -r -d '' content <<'EOF' || true
table inet torap {
  chain input {
    type filter hook input priority 0;
    ct state established,related accept
    iif lo accept
    iifname "wlan0" udp dport {67,68} accept
    iifname "wlan0" tcp dport 9040 accept
    iifname "wlan0" udp dport 9053 accept
    counter drop
  }
  chain prerouting {
    type nat hook prerouting priority -100;
    iifname "wlan0" meta skuid != debian-tor meta l4proto tcp redirect to :9040
    iifname "wlan0" udp dport 53 redirect to :9053
  }
  chain output {
    type filter hook output priority 0;
    ct state established,related accept
    meta skuid debian-tor accept
    accept
  }
}
EOF
    write_file "$conf" "$content"
    [ "$DRY_RUN" -eq 0 ] && { run_cmd systemctl enable nftables; run_cmd nft -f "$conf"; }
  else
    local rules=/etc/iptables/rules.v4
    local content
    read -r -d '' content <<'EOF' || true
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -i wlan0 -p tcp -m owner ! --uid-owner debian-tor -j REDIRECT --to-ports 9040
-A PREROUTING -i wlan0 -p udp --dport 53 -j REDIRECT --to-ports 9053
COMMIT
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -i wlan0 -p udp --dport 67:68 -j ACCEPT
-A INPUT -i wlan0 -p tcp --dport 9040 -j ACCEPT
-A INPUT -i wlan0 -p udp --dport 9053 -j ACCEPT
-A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m owner --uid-owner debian-tor -j ACCEPT
-A OUTPUT -j ACCEPT
COMMIT
EOF
    write_file "$rules" "$content"
    [ "$DRY_RUN" -eq 0 ] && { run_cmd systemctl enable netfilter-persistent; run_cmd netfilter-persistent save; }
  fi
  success "Firewall configured"
}

enable_services(){ step "Enable services"; [ "$DRY_RUN" -eq 1 ] && { info "Would enable services"; return; }; if [ "$FIREWALL_TOOL" = nftables ]; then run_cmd systemctl enable nftables; run_cmd systemctl start nftables; else run_cmd systemctl enable netfilter-persistent; run_cmd systemctl start netfilter-persistent; fi; run_cmd systemctl enable dnsmasq; run_cmd systemctl enable tor; run_cmd systemctl enable hostapd; run_cmd systemctl start dnsmasq; run_cmd systemctl start tor; run_cmd systemctl start hostapd; success "Services enabled"; }

summary(){ cat <<EOF

═════════════════════════════════════════════════════════════
  ✅ Setup Complete                                          
═════════════════════════════════════════════════════════════
 SSID: $SSID
 Subnet: $SUBNET
 Firewall: $FIREWALL_TOOL
 Services: hostapd, dnsmasq, tor
 Verify: torsocks curl https://check.torproject.org/api/ip
═════════════════════════════════════════════════════════════
Use only on networks you control and in accordance with local laws.
EOF
}

main(){ parse_args "$@"; print_banner; if [ "$REVERT" -eq 1 ]; then revert_changes; exit 0; fi; preflight_checks; install_packages; configure_network; configure_hostapd; configure_dnsmasq; configure_tor; configure_firewall; enable_services; summary; }

main "$@"
