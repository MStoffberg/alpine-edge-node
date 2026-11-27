#!/usr/bin/env bash
# Alpine t510 system disk post-install. Review before running as root.
set -Eeuo pipefail
umask 077
info() { printf '\n[edge] %s\n' "$*"; }
fail() { printf '[edge ERROR] %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail 'Run as root.'
[ -f /etc/alpine-release ] || fail 'Alpine Linux required.'
command -v rc-update >/dev/null || fail 'OpenRC required.'
[ "$(uname -m)" = x86_64 ] || fail 'Expected x86_64 on HP t510.'
[ "$(df -Pk / | awk 'END {print $4}')" -gt 450000 ] || fail 'Less than 450MB free on /.'

# Optional LOCAL settings file (chmod 600), never checked into GitHub.
if [ -n "${EDGE_CONFIG:-}" ]; then
  [ -r "$EDGE_CONFIG" ] || fail 'EDGE_CONFIG unreadable.'
  # shellcheck disable=SC1090
  . "$EDGE_CONFIG"
fi
ADMIN_USER="${ADMIN_USER:-edgeadmin}"
HOSTNAME_SET="${HOSTNAME_SET:-house1-edge}"
if [ -t 0 ]; then
  read -r -p "Admin username [$ADMIN_USER]: " answer
  [ -z "$answer" ] || ADMIN_USER="$answer"
  read -r -p "Hostname [$HOSTNAME_SET]: " answer
  [ -z "$answer" ] || HOSTNAME_SET="$answer"
fi
printf '%s\n' "$ADMIN_USER" | grep -Eq '^[a-z_][a-z0-9_-]{0,30}$' || fail 'Invalid admin name.'
[ "$ADMIN_USER" != root ] || fail 'Use a non-root admin name.'
printf '%s\n' "$HOSTNAME_SET" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' || fail 'Invalid hostname.'
if [ -z "${ADMIN_SSH_PUBLIC_KEY:-}" ]; then
  [ -t 0 ] || fail 'Set ADMIN_SSH_PUBLIC_KEY in local EDGE_CONFIG.'
  printf 'Paste your SSH PUBLIC key (ssh-ed25519 ...), then Enter:\n'
  IFS= read -r ADMIN_SSH_PUBLIC_KEY
fi
if [ -t 0 ]; then
  printf 'This will upgrade packages and install SSH admin + AdGuard.\n'
  printf 'It will NOT disable root/password SSH or activate the firewall.\n'
  read -r -p 'Continue? [y/N] ' answer
  case "$answer" in y|Y) ;; *) exit 0;; esac
fi

info 'Upgrading Alpine and installing packages'
apk update
apk upgrade
apk add bash curl ca-certificates openssh doas jq iproute2 chrony nftables \
  libcap-setcap bind-tools
update-ca-certificates
printf '%s\n' "$ADMIN_SSH_PUBLIC_KEY" | ssh-keygen -lf - >/dev/null ||
  fail 'Invalid SSH public key.'

info "Creating $ADMIN_USER and installing SSH key"
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  adduser -D -s /bin/ash "$ADMIN_USER"
  printf 'Set a local password for doas/console recovery:\n'
  passwd "$ADMIN_USER"
fi
addgroup "$ADMIN_USER" wheel 2>/dev/null || true
mkdir -p "/home/$ADMIN_USER/.ssh" /etc/doas.d
printf '%s\n' "$ADMIN_SSH_PUBLIC_KEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
chmod 700 "/home/$ADMIN_USER/.ssh"
chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
printf 'permit :wheel\n' > /etc/doas.d/edge.conf
chmod 600 /etc/doas.d/edge.conf
hostname "$HOSTNAME_SET"
printf '%s\n' "$HOSTNAME_SET" > /etc/hostname
rc-update add sshd default >/dev/null 2>&1 || true
rc-service sshd start >/dev/null 2>&1 || true
rc-update add chronyd default >/dev/null 2>&1 || true
rc-service chronyd start >/dev/null 2>&1 || true

info 'Downloading official AdGuard Home binary with published SHA-256 check'
if [ ! -x /opt/adguardhome/AdGuardHome ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 90 \
    https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest -o "$tmp/release.json"
  url="$(jq -er '.assets[] | select(.name=="AdGuardHome_linux_amd64.tar.gz") | .browser_download_url' "$tmp/release.json")" ||
    fail 'AdGuard amd64 asset missing.'
  digest="$(jq -er '.assets[] | select(.name=="AdGuardHome_linux_amd64.tar.gz") | .digest' "$tmp/release.json")" ||
    fail 'AdGuard SHA-256 digest missing.'
  printf '%s\n' "$digest" | grep -Eq '^sha256:[a-fA-F0-9]{64}$' ||
    fail 'AdGuard digest invalid; refusing unverified download.'
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$tmp/adguard.tgz"
  printf '%s  %s\n' "$(printf '%s' "$digest" | cut -d: -f2)" "$tmp/adguard.tgz" |
    sha256sum -c - || fail 'AdGuard checksum failed.'
  mkdir -p /opt/adguardhome
  tar -xzf "$tmp/adguard.tgz" -C /opt/adguardhome --strip-components=1
  test -x /opt/adguardhome/AdGuardHome || fail 'AdGuard binary missing.'
  chown -R root:root /opt/adguardhome
  chmod 755 /opt/adguardhome/AdGuardHome
  rm -rf "$tmp"
  trap - EXIT
else
  info 'Existing AdGuard binary found; leaving it and its configuration intact.'
fi
# Alpine BusyBox adduser -S does not guarantee a same-named group.
# Explicitly create the group, including when repairing a partial installation.
if ! grep -q '^adguard:' /etc/group; then addgroup -S adguard; fi
if ! id adguard >/dev/null 2>&1; then
  adduser -S -D -H -G adguard -s /sbin/nologin adguard
else
  addgroup adguard adguard 2>/dev/null || true
fi
mkdir -p /etc/adguardhome /var/lib/adguard
chown -R adguard:adguard /etc/adguardhome /var/lib/adguard
chmod 700 /etc/adguardhome /var/lib/adguard
setcap 'cap_net_bind_service=+ep' /opt/adguardhome/AdGuardHome ||
  fail 'Cannot grant non-root binding of DNS port 53.'
cat > /etc/init.d/adguardhome <<'INIT'
#!/sbin/openrc-run
name="AdGuard Home"
command="/opt/adguardhome/AdGuardHome"
command_args="-c /etc/adguardhome/AdGuardHome.yaml -w /var/lib/adguard"
command_user="adguard:adguard"
command_background="yes"
pidfile="/run/adguardhome.pid"
depend() { need net; }
INIT
chmod 755 /etc/init.d/adguardhome
rc-update add adguardhome default >/dev/null 2>&1 || true
rc-service adguardhome status >/dev/null 2>&1 ||
  rc-service adguardhome start || fail 'AdGuard failed to start.'

info 'Adding low-write health checks and host hardening'
mkdir -p /etc/sysctl.d /usr/local/sbin /etc/periodic/15min
cat > /etc/sysctl.d/90-edge-node.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.tcp_syncookies=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
kernel.dmesg_restrict=1
SYSCTL
sysctl -p /etc/sysctl.d/90-edge-node.conf >/dev/null || true
cat > /usr/local/sbin/edge-health <<'HEALTH'
#!/bin/sh
set -u
verbose=0
[ "${1:-}" = "--verbose" ] && verbose=1
report() { logger -t edge-health "$*"; [ "$verbose" -eq 0 ] || printf '%s\n' "$*"; }
pct="$(df -P / | awk 'END {gsub(/%/,"",$5);print $5}')"
[ "$pct" -lt 90 ] || report "WARNING root disk $pct% full"
for f in /sys/class/thermal/thermal_zone*/temp; do
  [ -r "$f" ] || continue
  t="$(cat "$f" 2>/dev/null || echo 0)"
  case "$t" in *[!0-9]*|'') continue;; esac
  [ "$t" -lt 85000 ] || report "WARNING temperature $((t/1000))C at $f"
done
for svc in sshd adguardhome; do
  rc-service "$svc" status >/dev/null 2>&1 && continue
  report "WARNING $svc down; restarting"
  rc-service "$svc" start >/dev/null 2>&1 || report "ERROR cannot restart $svc"
done
if command -v netbird >/dev/null 2>&1 && ! rc-service netbird status >/dev/null 2>&1; then
  report "WARNING netbird stopped; restarting"
  rc-service netbird start >/dev/null 2>&1 || report "ERROR cannot restart netbird"
fi
if [ "$verbose" -eq 1 ]; then
  df -h /
  free -h
  ip -brief addr
  command -v netbird >/dev/null 2>&1 && netbird status || true
fi
HEALTH
chmod 755 /usr/local/sbin/edge-health
printf '#!/bin/sh\n/usr/local/sbin/edge-health\n' > /etc/periodic/15min/edge-health
chmod 755 /etc/periodic/15min/edge-health
rc-update add crond default >/dev/null 2>&1 || true
rc-service crond start >/dev/null 2>&1 || true
if [ -f /etc/conf.d/syslog ]; then
  if grep -q '^SYSLOGD_OPTS=' /etc/conf.d/syslog; then
    sed -i 's/^SYSLOGD_OPTS=.*/SYSLOGD_OPTS="-s 200 -b 2"/' /etc/conf.d/syslog
  else
    printf '\nSYSLOGD_OPTS="-s 200 -b 2"\n' >> /etc/conf.d/syslog
  fi
  rc-service syslog restart >/dev/null 2>&1 || true
fi
lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
info 'Bootstrap complete. Existing SSH remains available until you explicitly finalize it.'
printf 'AdGuard wizard: http://%s:3000\n' "$lan_ip"
printf 'Next: configure-netbird.sh; test SSH key in a NEW session; finalize-ssh.sh; optional enable-firewall.sh.\n'
printf 'Test AdGuard DNS before setting the router DHCP DNS to this machine.\n'
