#!/usr/bin/env bash
# Run ONLY after testing a separate key-based SSH session.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'Run as root/doas.' >&2; exit 1; }
user="${1:?Usage: bash finalize-ssh.sh edgeadmin}"
if [ "$user" = root ] || ! id "$user" >/dev/null 2>&1; then
  echo 'Unknown/non-admin user.' >&2
  exit 1
fi
printf '%s\n' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,30}$' || exit 1
user_home="$(awk -F: -v user="$user" '$1 == user {print $6; exit}' /etc/passwd)"
if [ -z "$user_home" ] || [ ! -s "$user_home/.ssh/authorized_keys" ]; then
  echo 'Missing authorized_keys.' >&2
  exit 1
fi
[ -f /etc/ssh/sshd_config ] || { echo 'Missing sshd_config.' >&2; exit 1; }
printf 'Keep old SSH/console access. Confirm key login works in a SECOND session.\n'
read -r -p 'Type TESTED to continue: ' answer
[ "$answer" = TESTED ] || exit 1
config=/etc/ssh/sshd_config
if grep -q '^# edge-node managed SSH settings$' "$config"; then
  echo 'Already hardened; no changes.'
  exit 0
fi
backup="$config.edge-backup.$(date +%Y%m%d%H%M%S)"
cp -p "$config" "$backup"
new="$(mktemp)"
trap 'rm -f "$new"' EXIT
cat > "$new" <<SETTINGS
# edge-node managed SSH settings
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $user
X11Forwarding no
AllowTcpForwarding no
PermitTunnel no

SETTINGS
cat "$config" >> "$new"
sshd -t -f "$new" || { echo 'New SSH config invalid, original retained.' >&2; exit 1; }
cat "$new" > "$config"
if ! sshd -t; then
  cp -p "$backup" "$config"
  echo 'SSH config invalid; restored backup.' >&2
  exit 1
fi
if ! rc-service sshd restart; then
  cp -p "$backup" "$config"
  rc-service sshd restart || true
  echo 'SSH restart failed; backup restored.' >&2
  exit 1
fi
echo "SSH now allows only key-based $user. Local root console remains usable."
