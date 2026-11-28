#!/usr/bin/env bash
# One-command Alpine/OpenRC edge-node provisioner.
set -Eeuo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: bash provision.sh --hostname NAME --admin-user USER \
  --repo-commit SHA (--ssh-key-url URL | --ssh-public-key KEY) [options]

Options:
  --hostname NAME       Edge-node hostname, such as loki or freya.
  --admin-user USER     Existing non-root administrator account.
  --ssh-key-url URL     HTTPS URL containing one or more public SSH keys.
  --ssh-public-key KEY  A public SSH key supplied directly.
  --enable-firewall     Enable the isolated edge_input nftables table.
  --repo-commit SHA     Exact 40-character Git commit to download.
  --help                Show this text without requiring root.

The installer never enrolls NetBird, embeds setup keys, or hardens SSH in the
same session that installs a key. Prove a separate key login, then run the
commit-pinned finalize-ssh.sh as a distinct operation.
USAGE
}

hostname_set=
admin_user=
ssh_key_url=
ssh_public_key=
enable_firewall=0
repo_commit=

while (($#)); do
  case "$1" in
    --hostname) hostname_set=${2:?missing hostname}; shift 2 ;;
    --admin-user) admin_user=${2:?missing admin user}; shift 2 ;;
    --ssh-key-url) ssh_key_url=${2:?missing key URL}; shift 2 ;;
    --ssh-public-key) ssh_public_key=${2:?missing public key}; shift 2 ;;
    --enable-firewall) enable_firewall=1; shift ;;
    --repo-commit) repo_commit=${2:?missing commit}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $hostname_set =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || { printf 'Invalid or missing --hostname\n' >&2; exit 2; }
[[ $admin_user =~ ^[a-z_][a-z0-9_-]{0,30}$ && $admin_user != root ]] || { printf 'Invalid or missing --admin-user\n' >&2; exit 2; }
if [[ -n $ssh_key_url && -n $ssh_public_key ]] || [[ -z $ssh_key_url && -z $ssh_public_key ]]; then
  printf 'Choose exactly one of --ssh-key-url or --ssh-public-key\n' >&2
  exit 2
fi
[[ $repo_commit =~ ^[a-f0-9]{40}$ ]] || { printf 'Invalid or missing --repo-commit\n' >&2; exit 2; }
[[ $(id -u) -eq 0 ]] || { printf 'Run as root/doas.\n' >&2; exit 1; }
[[ -f /etc/alpine-release ]] || { printf 'Alpine Linux required.\n' >&2; exit 1; }
command -v curl >/dev/null || { printf 'Install curl first: apk add curl ca-certificates bash\n' >&2; exit 1; }
id "$admin_user" >/dev/null 2>&1 || { printf 'Administrator account must already exist: %s\n' "$admin_user" >&2; exit 1; }

if [[ -n $ssh_key_url ]]; then
  [[ $ssh_key_url == https://* ]] || { printf 'SSH key URL must use HTTPS.\n' >&2; exit 2; }
  ssh_public_key=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$ssh_key_url")
fi
[[ -n $ssh_public_key ]] || { printf 'No SSH public keys received.\n' >&2; exit 1; }

base="https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/$repo_commit"
work=/root/edge-node-provisioner
mkdir -p "$work/lib"
chmod 700 "$work"
for file in bootstrap.sh configure-netbird.sh enable-firewall.sh; do
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$base/$file" -o "$work/$file"
done
curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$base/lib/edge-lib.sh" -o "$work/lib/edge-lib.sh"
chmod 700 "$work"/*.sh "$work/lib/edge-lib.sh"
for file in "$work"/*.sh "$work/lib/edge-lib.sh"; do bash -n "$file"; done

ADMIN_USER="$admin_user" HOSTNAME_SET="$hostname_set" ADMIN_SSH_PUBLIC_KEY="$ssh_public_key" \
  EDGE_LIB="$work/lib/edge-lib.sh" bash "$work/bootstrap.sh"
bash "$work/configure-netbird.sh"

if ((enable_firewall)); then
  printf 'ENABLE\n' | bash "$work/enable-firewall.sh"
fi
printf '\nProvisioning converged for %s.\n' "$hostname_set"
printf 'NetBird is installed but not enrolled; run: netbird up\n'
printf 'SSH is not hardened by this run; prove a separate key login before finalizing it.\n'
printf 'Re-run this same command safely after updates.\n'
