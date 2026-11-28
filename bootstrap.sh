#!/usr/bin/env bash
# Alpine t510 system disk post-install. Review before running as root.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/edge-lib.sh
. "${EDGE_LIB:-$SCRIPT_DIR/lib/edge-lib.sh}"
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
while IFS= read -r key; do
  [ -n "$key" ] || continue
  printf '%s\n' "$key" | ssh-keygen -lf - >/dev/null || fail 'Invalid SSH public key.'
done <<< "$ADMIN_SSH_PUBLIC_KEY"

info "Creating $ADMIN_USER and installing SSH key(s)"
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  adduser -D -s /bin/ash "$ADMIN_USER"
  printf 'Set a local password for doas/console recovery:\n'
  passwd "$ADMIN_USER"
fi
addgroup "$ADMIN_USER" wheel 2>/dev/null || true
admin_home="$(awk -F: -v user="$ADMIN_USER" '$1 == user {print $6; exit}' /etc/passwd)"
if [ -z "$admin_home" ] || [ ! -d "$admin_home" ]; then
  fail 'Administrator home directory is missing.'
fi
admin_group="$(id -gn "$ADMIN_USER")" || fail 'Cannot resolve administrator primary group.'
mkdir -p "$admin_home/.ssh" /etc/doas.d
append_authorized_keys "$admin_home" "$ADMIN_USER" "$admin_group" "$ADMIN_SSH_PUBLIC_KEY"
printf 'permit :wheel\n' > /etc/doas.d/edge.conf
chmod 600 /etc/doas.d/edge.conf
hostname "$HOSTNAME_SET"
printf '%s\n' "$HOSTNAME_SET" > /etc/hostname
rc-update add sshd default >/dev/null 2>&1 || true
rc-service sshd start >/dev/null 2>&1 || true
rc-update add chronyd default >/dev/null 2>&1 || true
rc-service chronyd start >/dev/null 2>&1 || true

info 'Checking AdGuard Home executable (not just its path)'
adguard_target=/opt/adguardhome/AdGuardHome
adguard_binary_valid() {
  [ -f "$1" ] && [ -x "$1" ] || return 1
  binary_magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d '[:space:]')"
  [ "$binary_magic" = 7f454c46 ]
}
if adguard_binary_valid "$adguard_target"; then
  info 'Existing AdGuard executable verified; preserving binary and settings.'
else
  info 'AdGuard binary missing or invalid. Repairing from a checksum-verified release.'
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 90 \
    https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest -o "$tmp/release.json"
  url="$(jq -er '.assets[] | select(.name=="AdGuardHome_linux_amd64.tar.gz") | .browser_download_url' "$tmp/release.json")" ||
    fail 'AdGuard amd64 asset missing.'
  digest="$(jq -er '.assets[] | select(.name=="AdGuardHome_linux_amd64.tar.gz") | .digest' "$tmp/release.json")" ||
    fail 'AdGuard release SHA-256 digest missing.'
  printf '%s\n' "$digest" | grep -Eq '^sha256:[a-fA-F0-9]{64}$' ||
    fail 'AdGuard digest invalid; refusing unverified download.'
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$tmp/adguard.tgz"
  printf '%s  %s\n' "$(printf '%s' "$digest" | cut -d: -f2)" "$tmp/adguard.tgz" |
    sha256sum -c - || fail 'AdGuard checksum failed.'
  mkdir -p "$tmp/unpack"
  tar -xzf "$tmp/adguard.tgz" -C "$tmp/unpack" ||
    fail 'AdGuard archive extraction failed.'
  # Locate the actual executable, even if the archive has nested directories.
  extracted_binary="$(find "$tmp/unpack" -type f -name AdGuardHome -print -quit)"
  [ -n "$extracted_binary" ] || fail 'No AdGuard executable found in verified archive.'
  adguard_binary_valid "$extracted_binary" ||
    fail 'Extracted AdGuard executable is not a valid ELF binary.'
  mkdir -p /opt/adguardhome
  # The old bootstrap sometimes created a *directory* named AdGuardHome.
  # Preserve any existing data instead of deleting or overwriting it.
  if [ -e "$adguard_target" ] || [ -L "$adguard_target" ]; then
    backup="$adguard_target.invalid.$(date +%Y%m%d%H%M%S)"
    [ ! -e "$backup" ] || fail "Backup path already exists: $backup"
    mv "$adguard_target" "$backup" ||
      fail 'Cannot move invalid AdGuard path aside.'
    chmod -R go-rwx "$backup" || true
    info "Preserved invalid AdGuard path at $backup"
  fi
  cp "$extracted_binary" "$adguard_target.new.$$" ||
    fail 'Cannot stage AdGuard binary.'
  chmod 755 "$adguard_target.new.$$"
  chown root:root "$adguard_target.new.$$"
  mv "$adguard_target.new.$$" "$adguard_target" ||
    fail 'Cannot install AdGuard executable.'
  adguard_binary_valid "$adguard_target" ||
    fail 'Installed AdGuard executable did not validate.'
  rm -rf "$tmp"
  trap - EXIT
  info 'Verified AdGuard executable installed successfully.'
fi
chmod 755 /opt/adguardhome
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
# Prefer the narrow CAP_NET_BIND_SERVICE permission. Some small flash
# filesystems and symlinks do not support Linux file capabilities.
adguard_binary="$(readlink -f /opt/adguardhome/AdGuardHome)"
[ -f "$adguard_binary" ] || fail 'AdGuard executable is not a regular file.'
magic="$(head -c 4 "$adguard_binary" | od -An -tx1 | tr -d '[:space:]')"
[ "$magic" = 7f454c46 ] || fail 'AdGuard executable is not an ELF binary; refusing to run it.'
setcap 'cap_net_bind_service=+ep' "$adguard_binary" ||
  fail 'Cannot grant narrow CAP_NET_BIND_SERVICE; refusing a host-wide privileged-port fallback.'
info 'AdGuard received CAP_NET_BIND_SERVICE for DNS port 53.'
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

bootstrap_pidfile=/run/adguardhome-bootstrap.pid
bootstrap_log=/root/edge-node-secrets/adguard-bootstrap.log
stop_adguard_bootstrap() {
  [ -s "$bootstrap_pidfile" ] || return 0
  bootstrap_pid="$(cat "$bootstrap_pidfile")"
  case "$bootstrap_pid" in
    *[!0-9]*|'') return 1 ;;
  esac
  if [ -e "/proc/$bootstrap_pid/exe" ] &&
     [ "$(readlink -f "/proc/$bootstrap_pid/exe")" = "$adguard_binary" ]; then
    start-stop-daemon --stop --pidfile "$bootstrap_pidfile" \
      --exec "$adguard_binary" --retry TERM/10/KILL/5 >/dev/null 2>&1 || return 1
    if [ -e "/proc/$bootstrap_pid/exe" ] &&
       [ "$(readlink -f "/proc/$bootstrap_pid/exe")" = "$adguard_binary" ]; then
      return 1
    fi
  fi
  rm -f "$bootstrap_pidfile"
}
bootstrap_recovered=0
[ ! -s "$bootstrap_pidfile" ] || bootstrap_recovered=1
stop_adguard_bootstrap || fail 'Cannot stop tracked AdGuard bootstrap; pidfile preserved.'
if [ -s /etc/adguardhome/AdGuardHome.yaml ] &&
   ! "$adguard_binary" --check-config -c /etc/adguardhome/AdGuardHome.yaml \
     -w /var/lib/adguard >/dev/null 2>&1; then
  if [ "$bootstrap_recovered" -eq 1 ]; then
    mv /etc/adguardhome/AdGuardHome.yaml \
      "/etc/adguardhome/AdGuardHome.yaml.interrupted.$(date +%Y%m%d%H%M%S)"
  else
    fail 'Existing AdGuard configuration is invalid; preserved for manual recovery.'
  fi
fi

if [ ! -s /etc/adguardhome/AdGuardHome.yaml ]; then
  info 'Configuring AdGuard Home first run without exposing its password'
  mkdir -p /root/edge-node-secrets
  chmod 700 /root/edge-node-secrets
  adguard_secret_file=/root/edge-node-secrets/adguard-bootstrap-password
  adguard_password="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
  printf '%s\n' "$adguard_password" > "$adguard_secret_file"
  chmod 600 "$adguard_secret_file"

  # AdGuard requires administrator privileges for its first launch.  Binding
  # the unauthenticated setup API to loopback prevents any LAN claim race.
  start-stop-daemon --start --background --make-pidfile --pidfile "$bootstrap_pidfile" \
    --stdout "$bootstrap_log" --stderr "$bootstrap_log" --exec "$adguard_binary" -- \
    -c /etc/adguardhome/AdGuardHome.yaml \
    -w /var/lib/adguard --web-addr 127.0.0.1:3000
  cleanup_adguard_bootstrap() {
    if ! stop_adguard_bootstrap; then
      printf '[edge ERROR] Cannot stop tracked AdGuard bootstrap; pidfile preserved.\n' >&2
      return 1
    fi
  }
  trap cleanup_adguard_bootstrap EXIT
  ready=0
  for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:3000/control/install/get_addresses >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || fail 'AdGuard first-run endpoint did not become ready.'
  jq -n --arg password "$adguard_password" '{
    web: {ip:"0.0.0.0", port:3000},
    dns: {ip:"0.0.0.0", port:53},
    username:"admin",
    password:$password
  }' | curl -fsS -H 'Content-Type: application/json' --data-binary @- \
    http://127.0.0.1:3000/control/install/configure >/dev/null ||
      fail 'AdGuard first-run configuration failed.'
  cleanup_adguard_bootstrap
  trap - EXIT
  info "AdGuard admin password stored at $adguard_secret_file (root-only); move it to your vault, then delete it."
fi

chown -R adguard:adguard /etc/adguardhome /var/lib/adguard
chmod 700 /etc/adguardhome /var/lib/adguard
"$adguard_binary" --check-config -c /etc/adguardhome/AdGuardHome.yaml \
  -w /var/lib/adguard >/dev/null 2>&1 || fail 'AdGuard configuration validation failed.'

rc-update add adguardhome default >/dev/null 2>&1 || true
rc-service adguardhome status >/dev/null 2>&1 ||
  rc-service adguardhome start || fail 'AdGuard failed to start.'

adguard_uid="$(id -u adguard)"
for _ in $(seq 1 15); do
  running_pid="$(pidof AdGuardHome 2>/dev/null | awk '{print $1}')"
  running_uid=""
  if [ -n "$running_pid" ] && [ -r "/proc/$running_pid/status" ]; then
    running_uid="$(awk '/^Uid:/ {print $2; exit}' "/proc/$running_pid/status")"
  fi
  [ "$running_uid" = "$adguard_uid" ] && break
  sleep 1
done
[ "${running_uid:-}" = "$adguard_uid" ] || fail 'AdGuard is not running as its service account.'
ss -lntup | grep -Eq '[:.]53[[:space:]]' || fail 'AdGuard is not listening on DNS port 53.'
nslookup example.com 127.0.0.1 >/dev/null 2>&1 || fail 'AdGuard local DNS lookup failed.'
install -o adguard -g adguard -m 600 /dev/null /var/lib/adguard/.edge-bootstrap-complete

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
lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1)}}')"
info 'Bootstrap complete. Existing SSH remains available until you explicitly finalize it.'
printf 'AdGuard wizard: http://%s:3000\n' "$lan_ip"
printf 'Next: configure-netbird.sh; test SSH key in a NEW session; finalize-ssh.sh; optional enable-firewall.sh.\n'
printf 'Test AdGuard DNS before setting the router DHCP DNS to this machine.\n'
