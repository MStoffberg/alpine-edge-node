#!/usr/bin/env bash
# Install NetBird Cloud client on Alpine Linux, without embedding credentials.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo 'Alpine Linux required.' >&2; exit 1; }
if [ ! -e /etc/init.d/netbird ]; then
  echo 'Installing NetBird using the matching Alpine Community repository.'
  repo_file=/etc/apk/repositories
  branch="v$(cut -d. -f1,2 /etc/alpine-release)"
  main_repo="$(awk -v b="$branch" '$0 ~ "^https?://.*/" b "/main$" {print; exit}' "$repo_file")"
  if [ -z "$main_repo" ]; then
    echo "No enabled $branch/main repository found. Inspect $repo_file." >&2
    exit 1
  fi
  community_repo="${main_repo%/main}/community"
  if ! grep -Fxq "$community_repo" "$repo_file"; then
    cp -p "$repo_file" "$repo_file.edge-backup.$(date +%Y%m%d%H%M%S)"
    printf '%s\n' "$community_repo" >> "$repo_file"
    printf 'Enabled %s\n' "$community_repo"
  fi
  apk update
  if ! apk add netbird netbird-openrc; then
    echo "NetBird package installation failed. Verify $repo_file and apk policy netbird." >&2
    echo 'Never mix Alpine stable with edge repositories.' >&2
    exit 1
  fi
fi
mkdir -p /etc/sysctl.d
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/91-edge-netbird.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
rc-update add netbird default >/dev/null 2>&1 || true
rc-service netbird start
cat <<'STEPS'

NetBird daemon installed but not enrolled; service enabled on reboot.
Enroll in FREE managed Cloud:

  netbird up
  netbird status -d

Open https://app.netbird.io to verify this peer.

In NetBird -> Networks create the NVR LAN IP (/32) as a resource.
Use THIS t510 as Routing Peer, enable Masquerade, and grant only
the House 3 viewer group/peers access to that resource.

Optionally advertise the t510 LAN IP as a separate /32 resource
for House 3's AdGuard sync. Never publish NVR ports to the Internet,
and do not set up an exit node or advertise 0.0.0.0/0.

No credentials or setup keys belong in the public repository.
STEPS
