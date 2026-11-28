#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
ok() { printf 'ok - %s\n' "$1"; pass=$((pass+1)); }
not_ok() { printf 'not ok - %s\n' "$1"; fail=$((fail+1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }

scripts=(bootstrap.sh configure-netbird.sh finalize-ssh.sh enable-firewall.sh provision.sh lib/edge-lib.sh)
for script in "${scripts[@]}"; do
  check "$script has valid Bash syntax" bash -n "$script"
done

# shellcheck disable=SC2016
check 'provision help works without root' bash -c 'out=$(bash provision.sh --help); grep -q -- "--hostname" <<<"$out" && grep -q -- "--ssh-key-url" <<<"$out" && grep -q -- "--repo-commit" <<<"$out"'
check 'provision rejects an unknown option' bash -c '! bash provision.sh --definitely-invalid >/dev/null 2>&1'
check 'broad privileged-port fallback is absent' bash -c '! grep -E "ip_unprivileged_port_start" -- *.sh'
check 'scripts never flush the complete nftables ruleset' bash -c '! grep -E "^[[:space:]]*nft[[:space:]]+flush[[:space:]]+ruleset" -- *.sh'
check 'scripts contain no NetBird setup key' bash -c '! grep -E "setup-key[[:space:]]+[A-Za-z0-9]" -- *.sh'
check 'no script overwrites authorized_keys' bash -c '! grep -E ">[[:space:]]*\"?[^[:space:]]*authorized_keys" -- *.sh'
check 'NetBird unenrolled state is explicit' grep -q 'installed but not enrolled' configure-netbird.sh
check 'firewall uses an isolated table' grep -q 'table inet edge_input' enable-firewall.sh
check 'firewall never creates a forward hook' bash -c '! grep -E "hook[[:space:]]+forward" enable-firewall.sh'
check 'provision never performs same-session SSH hardening' bash -c '! grep -Eq "bash .*finalize-ssh|TESTED" provision.sh && ! grep -q -- "--harden-ssh" provision.sh'
check 'provision requires an immutable commit' grep -q '\^\[a-f0-9\]{40}\$' provision.sh
check 'checksum validation remains mandatory' grep -q 'sha256sum -c' bootstrap.sh
check 'ELF validation remains mandatory' grep -q '7f454c46' bootstrap.sh
check 'AdGuard first-run setup is automated' grep -q '/control/install/configure' bootstrap.sh
check 'AdGuard bootstrap password is root-only' bash -c 'grep -q "/root/edge-node-secrets/adguard-bootstrap-password" bootstrap.sh && grep -q "chmod 600.*adguard_secret_file" bootstrap.sh'
check 'AdGuard bootstrap web API is loopback-only' grep -q -- '--web-addr 127.0.0.1:3000' bootstrap.sh
check 'AdGuard root-only first launch is documented' grep -q 'requires administrator privileges for its first launch' bootstrap.sh
# shellcheck disable=SC2016
check 'AdGuard bootstrap cleanup matches the executable' grep -q -- '--exec "$adguard_binary" --retry' bootstrap.sh
check 'AdGuard bootstrap preserves pidfile on cleanup failure' bash -c '! grep -q "start-stop-daemon.*|| true" bootstrap.sh && grep -q "Cannot stop tracked AdGuard bootstrap" bootstrap.sh'
# shellcheck disable=SC2016
check 'AdGuard stale bootstrap recovery precedes config detection' bash -c 'recover=$(grep -n "stop_adguard_bootstrap || fail" bootstrap.sh | head -1 | cut -d: -f1); detect=$(grep -n "if \[ ! -s /etc/adguardhome/AdGuardHome.yaml" bootstrap.sh | head -1 | cut -d: -f1); [[ -n $recover && -n $detect && $recover -lt $detect ]]'
check 'AdGuard ownership repair follows first-run block' grep -q 'edge-bootstrap-complete' bootstrap.sh
check 'AdGuard runtime UID uses procfs' grep -q '/proc/.*/status' bootstrap.sh
check 'AdGuard program directory is traversable' grep -q 'chmod 755 /opt/adguardhome' bootstrap.sh
check 'firewall does not abandon partial existing state' bash -c '! grep -q "already active; refusing" enable-firewall.sh'
check 'firewall reload avoids stop/start SSH gap' bash -c '! grep -q "^rc-service edge-firewall stop" enable-firewall.sh && grep -q "rc-service edge-firewall reload" enable-firewall.sh'
check 'firewall replacement is one nft transaction file' bash -c 'grep -q "mktemp /run/edge-firewall" enable-firewall.sh && grep -q "nft -f.*transaction" enable-firewall.sh && ! grep -q "| nft -f -" enable-firewall.sh'
# shellcheck disable=SC2016
check 'firewall validates the replacement transaction' grep -q 'nft -c -f "$transaction"' enable-firewall.sh
# shellcheck disable=SC2016
check 'firewall transaction permissions fail closed' grep -q 'chmod 600 "$transaction" ||' enable-firewall.sh
# shellcheck disable=SC2016
check 'firewall boot registration follows successful activation' bash -c 'apply=$(grep -n "rc-service edge-firewall reload" enable-firewall.sh | tail -1 | cut -d: -f1); register=$(grep -n "rc-update add edge-firewall" enable-firewall.sh | tail -1 | cut -d: -f1); [[ -n $apply && -n $register && $register -gt $apply ]]'
check 'route lookup avoids pipefail SIGPIPE' bash -c '! grep -q "ip -4 route get.*awk.*exit" bootstrap.sh'

# Real append/dedupe behavior against a temporary root fixture.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/custom-home/.ssh"
printf '%s\n' 'ssh-ed25519 AAAAexisting existing@host' > "$tmp/custom-home/.ssh/authorized_keys"
# shellcheck source=lib/edge-lib.sh
source lib/edge-lib.sh
new_key='ssh-ed25519 AAAAnew nora@hela'
append_authorized_key "$tmp/custom-home" keiki keiki "$new_key"
append_authorized_key "$tmp/custom-home" keiki keiki "$new_key"
multiline_keys=$'ssh-ed25519 AAAAsecond second@host\nssh-rsa AAAAthird third@host'
append_authorized_keys "$tmp/custom-home" keiki keiki "$multiline_keys"
check 'authorized key append preserves existing entry' grep -Fxq 'ssh-ed25519 AAAAexisting existing@host' "$tmp/custom-home/.ssh/authorized_keys"
# shellcheck disable=SC2016
check 'authorized key append deduplicates new entry' bash -c '[[ $(grep -Fxc "$1" "$2") -eq 1 ]]' _ "$new_key" "$tmp/custom-home/.ssh/authorized_keys"
# shellcheck disable=SC2016
check 'authorized key list installs each key in a nonstandard home' bash -c 'grep -Fxq "ssh-ed25519 AAAAsecond second@host" "$1" && grep -Fxq "ssh-rsa AAAAthird third@host" "$1"' _ "$tmp/custom-home/.ssh/authorized_keys"

printf '\n%d passed; %d failed\n' "$pass" "$fail"
(( fail == 0 ))
