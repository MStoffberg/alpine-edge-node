#!/usr/bin/env bash
# Optional host-only firewall. DO NOT use as a router firewall.
# Safe with NetBird's own nftables tables: never runs "flush ruleset".
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'Run as root/doas.' >&2; exit 1; }
command -v nft >/dev/null || { echo 'Install nftables first (bootstrap.sh).' >&2; exit 1; }
LAN_IF="$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1);exit}}')"
[ -n "$LAN_IF" ] || { echo 'No default LAN interface detected.' >&2; exit 1; }
LAN_CIDR="$(ip -4 route show dev "$LAN_IF" scope link | awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// {print $1;exit}')"
[ -n "$LAN_CIDR" ] || { echo 'Could not find LAN subnet.' >&2; exit 1; }
printf '%s\n' "$LAN_IF" | grep -Eq '^[A-Za-z0-9_.-]+$' || exit 1
printf '%s\n' "$LAN_CIDR" | grep -Eq '^[0-9.]+/[0-9]{1,2}$' || exit 1
printf '\nLocal interface: %s, subnet %s\n' "$LAN_IF" "$LAN_CIDR"
printf 'Host firewall allows LAN/NetBird SSH, AdGuard web UI, DNS.\n'
printf 'It does NOT block forwarded NetBird-to-NVR traffic; NetBird manages resource policies.\n'
printf 'Do NOT enable unless you have tested key-based SSH and have console access.\n'
read -r -p 'Type ENABLE: ' answer
[ "$answer" = ENABLE ] || exit 0
mkdir -p /etc/edge-node
cat > /etc/edge-node/firewall.nft <<RULES
table inet edge_input {
  chain input {
    type filter hook input priority -5; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp accept
    meta l4proto ipv6-icmp accept
    iifname "$LAN_IF" udp sport 67 udp dport 68 accept
    iifname "$LAN_IF" ip saddr $LAN_CIDR tcp dport { 22, 53, 80, 3000 } accept
    iifname "$LAN_IF" ip saddr $LAN_CIDR udp dport 53 accept
    iifname "wt0" tcp dport { 22, 53, 80, 3000 } accept
    iifname "wt0" udp dport 53 accept
  }
}
RULES
nft -c -f /etc/edge-node/firewall.nft ||
  { echo 'Firewall validation failed; nothing activated.' >&2; exit 1; }
cat > /etc/init.d/edge-firewall <<'SERVICE'
#!/sbin/openrc-run
description="Private edge host firewall (only table inet edge_input)"
depend() { need net; before netbird; }
start() {
  ebegin "Installing edge host firewall"
  nft delete table inet edge_input 2>/dev/null || true
  nft -f /etc/edge-node/firewall.nft
  eend $?
}
stop() {
  ebegin "Removing edge host firewall"
  nft delete table inet edge_input 2>/dev/null || true
  eend 0
}
SERVICE
chmod 755 /etc/init.d/edge-firewall
rc-service edge-firewall stop >/dev/null 2>&1 || true
rc-service edge-firewall start || exit 1
rc-update add edge-firewall default
printf '\nFirewall enabled, and will be restored on reboot.\n'
printf 'Recovery at local console: rc-service edge-firewall stop; rc-update del edge-firewall default\n'
