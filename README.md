# Alpine Edge Node

Idempotent Alpine/OpenRC provisioning for the low-resource edge nodes in the three-house CCTV network. Each node provides local AdGuard Home DNS and a NetBird routing peer; NVRs continue recording locally.

## Security contract

- Repository provisioning scripts are pinned to one exact 40-character Git commit; AdGuard artifacts are separately authenticated with their official SHA-256 digest.
- Existing authorized keys and AdGuard configuration/data are preserved.
- AdGuard releases require the official SHA-256 digest and an ELF executable.
- AdGuard runs as its own account with only `CAP_NET_BIND_SERVICE`.
- The temporary root-required first-run API binds only to `127.0.0.1`; the persistent service then runs as `adguard`.
- NetBird is installed but never enrolled with a key embedded in Git or shell history.
- The firewall owns only `table inet edge_input`; it never clears NetBird tables or adds a forward hook.
- Provisioning never disables password/root SSH in the same session that installs keys.

The scripts do not partition disks, change interface configuration, become a DHCP server, expose NVR ports, or advertise a NetBird exit route.

## Prerequisites

- Persistent Alpine x86_64 with OpenRC and at least 450 MB free on `/`
- Existing non-root administrator, normally `keiki`, with console/recovery access
- Different LAN subnets at each house
- A reviewed commit SHA from this repository

## Phase 1: one-line provisioning

Replace `<REVIEWED_COMMIT>` with the reviewed 40-character commit. Run as root from the Alpine console.

### Loki

```sh
COMMIT=<REVIEWED_COMMIT>; apk add --no-cache bash curl ca-certificates && curl -fsSL "https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/$COMMIT/provision.sh" | bash -s -- --repo-commit "$COMMIT" --hostname loki --admin-user keiki --ssh-key-url https://github.com/MStoffberg.keys --enable-firewall
```

### Freya

```sh
COMMIT=<REVIEWED_COMMIT>; apk add --no-cache bash curl ca-certificates && curl -fsSL "https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/$COMMIT/provision.sh" | bash -s -- --repo-commit "$COMMIT" --hostname freya --admin-user keiki --ssh-key-url https://github.com/MStoffberg.keys --enable-firewall
```

The command is rerunnable. It configures the OS, SSH keys, AdGuard, NetBird service, health checks, and firewall, but deliberately leaves current SSH recovery methods enabled.

## Phase 2: external verification and SSH hardening

From another computer, prove key login and DNS first:

```sh
ssh -i ~/.ssh/<matching-key> keiki@<edge-ip>
nslookup example.com <edge-ip>
```

Only after that succeeds, download `finalize-ssh.sh` from the **same commit**, inspect it, and run it locally through `doas` or the physical console:

```sh
COMMIT=<REVIEWED_COMMIT>
curl -fsSLo /tmp/finalize-ssh.sh "https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/$COMMIT/finalize-ssh.sh"
bash -n /tmp/finalize-ssh.sh
doas bash /tmp/finalize-ssh.sh keiki
```

Type `TESTED` only when the separate key session remains open. The script validates sshd configuration, keeps a backup, and rolls back if restart fails.

## First-run credentials

A new AdGuard installation receives a generated password that is never printed. It is temporarily stored in the root-only file:

```text
/root/edge-node-secrets/adguard-bootstrap-password
```

Move it to Vaultwarden, verify authenticated API access, then delete the temporary file. Existing installations keep their current credentials and configuration.

NetBird enrollment is separate:

```sh
netbird up
netbird status -d
```

In NetBird Cloud, advertise only the NVR IP as a `/32` resource through the house edge node. Grant only House 3 viewers and never advertise `0.0.0.0/0`.

## Acceptance checks

```sh
rc-service adguardhome status
rc-service netbird status
/usr/local/sbin/edge-health --verbose
ss -lntup
nft list table inet edge_input
netbird status -d
sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|allowusers)'
```

After hardening, expected SSH state is: root/password/keyboard-interactive authentication disabled, public-key authentication enabled, and only the configured administrator allowed.

Reboot and repeat SSH, DNS, service, firewall, and NetBird checks before treating the node as power-loss resilient.

## CCTV and Hestoria

Keep DHCP on each house router and high-resolution recording on each local NVR. Run `adguardhome-sync` at House 3 over NetBird. Use substreams for multi-camera remote views.

The family-facing multisite CCTV dashboard belongs in Hestoria. Hikvision remote playback may initially continue through iVMS-4200; Hestoria should provide the unified family workflow rather than duplicate NVR recording.

## Development

```sh
bash tests/contract.sh
shellcheck -x bootstrap.sh configure-netbird.sh finalize-ssh.sh enable-firewall.sh provision.sh lib/edge-lib.sh tests/contract.sh
git diff --check
```

GitHub Actions runs the same gates.
