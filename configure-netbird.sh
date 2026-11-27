#!/usr/bin/env bash
# Install NetBird Cloud client on Alpine Linux, without embedding credentials.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo 'Alpine Linux required.' >&2; exit 1; }
if [ ! -e /etc/init.d/netbird ]; then
  echo 'Installing NetBird from the Alpine Community repository.'
  apk update
  if ! apk add netbird netbird-openrc; then
    echo 'Enable the Community repository for your SAME Alpine stable release, then retry.' >&2
    echo 'Do not mix stable and edge package repositories.' >&2
    exit 1
  fi
fi
mkdir -p /etc/sysctl.d
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/91-edge-netbird.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
rc-update add netbird default >/dev/null 2>&1 || true
rc-service netbird start
cat <<'STEPS'

NetBird daemon installed and enabled on reboot.
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
