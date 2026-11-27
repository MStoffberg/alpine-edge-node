# Alpine Edge Node (HP t510)

A small Alpine Linux **post-install kit** for the three-house CCTV project. Each HP t510 runs **AdGuard Home + NetBird Cloud**; existing Hikvision NVRs continue recording to their **own local HDDs**. House 3 connects to the NVRs for live view and playback over NetBird.

## Architecture

```text
House 1: cameras -> local Hikvision NVR/HDD -- LAN -- HP t510 (AdGuard + NetBird)
House 2: cameras -> local NVR/HDD ---------- LAN -- HP t510 (AdGuard + NetBird)
House 3: local NVR/HDD + viewer/HA + NetBird peer
                            \-- encrypted NetBird P2P --/
```

Use different LAN subnets at each house. Use NetBird Cloud's **Networks / Resources** dashboard to advertise the remote NVR **LAN IP /32** through each house's t510 as routing peer, with **Masquerade enabled** and access restricted to House 3's viewer peer/group. No internet-facing NVR ports. The t510 does **not** become a router for all internet traffic.

## Important safety notes

- Alpine Linux **x86_64, OpenRC, installed to internal storage in sys/disk mode**, not running as a live/diskless USB system.
- Keep a screen/keyboard or physical recovery access while changing SSH and firewall settings.
- The installer does not partition, format, disable DHCP on the router, modify network interfaces, or forward public ports.
- Supply your own **SSH PUBLIC key** (never upload any private key, NetBird setup key, AdGuard password or VPN state).
- Review scripts before running as root. The first install does **not** disable root/password SSH; explicitly run `finalize-ssh.sh` after a working second key-based SSH session.
- Only enable the optional local nftables firewall after verifying access. It creates its own table and **does not flush NetBird-managed firewall rules**. A wrongly configured firewall can still cut off remote access.
- 8 GB flash: disable persistent AdGuard query logging / use short retention; no NVR recording or swap on this box. UPS recommended.
- Never expose port 53, 3000 or SSH on the public internet.

## Quick start

On Alpine as root, with your current internet/DNS still working:

```sh
apk add bash curl ca-certificates
curl -fsSLo /root/edge-bootstrap.sh https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/master/bootstrap.sh
less /root/edge-bootstrap.sh  # or cat to inspect
bash /root/edge-bootstrap.sh
```

Prompts: administrator username, hostname, local SSH **public** key. It upgrades OS packages, creates the admin account, installs AdGuard Home verified by published GitHub SHA-256, sets up OpenRC services, basic low-write logging, chrony, health checks and sysctl hardening.

Then:

```sh
# Obtain the helpers; inspect each before running
curl -fsSLo /root/configure-netbird.sh https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/master/configure-netbird.sh
curl -fsSLo /root/finalize-ssh.sh https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/master/finalize-ssh.sh
curl -fsSLo /root/enable-firewall.sh https://raw.githubusercontent.com/MStoffberg/alpine-edge-node/master/enable-firewall.sh

bash /root/configure-netbird.sh
netbird up
netbird status -d
```

`netbird up` requires interactive authentication into **your NetBird Cloud account**. Nothing in this repository contains setup keys. For NetBird cloud management, visit https://app.netbird.io/. No VPS is needed.

Complete AdGuard first-run setup at `http://<edge-LAN-IP>:3000`. Set DNS to port 53, the web UI to 3000, and a strong local admin password. Test `nslookup example.com <edge-LAN-IP>` before pointing your router's DHCP DNS to the edge node. Leave DHCP on your existing router.

**Test SSH in a second terminal:** `ssh -i ~/.ssh/id_ed25519 edgeadmin@<edge-LAN-IP>`. Then run `bash /root/finalize-ssh.sh edgeadmin` from console or with `doas`. Optionally run `bash /root/enable-firewall.sh` afterward, with recovery access.

## AdGuard sync

Run [adguardhome-sync](https://github.com/bakito/adguardhome-sync) **at House 3** and target each house's AdGuard UI over VPN. To access the LAN address of the edge node remotely, advertise that IP as a NetBird network resource and allow the correct dashboard/sync peer. Do not publish credentials or sync configuration in this repo.

## Maintenance

```sh
apk update && apk upgrade
rc-service adguardhome status
rc-service netbird status
netbird status -d
/usr/local/sbin/edge-health --verbose
df -h /
```

After a reboot verify SSH, AdGuard DNS, NetBird P2P/relay status and playback from House 3. The old VIA CPU may limit VPN throughput; measure before committing to continuous multi-camera remote viewing.

References: [Alpine OpenRC](https://docs.alpinelinux.org/user-handbook/0.1a/Working/openrc.html), [NetBird Alpine install](https://docs.netbird.io/get-started/install/linux), [NetBird network resources](https://docs.netbird.io/manage/networks), [AdGuard Home](https://adguard-dns.io/kb/adguard-home/getting-started/).


## Troubleshooting partial installations

If `bootstrap.sh` previously exited with `chown: unknown user/group adguard:adguard`, download and rerun the **latest** `bootstrap.sh` from `master`. The updated script explicitly creates the `adguard` group and recovers existing accounts and binaries. It does not format the disk or disable SSH.

If NetBird previously failed with `netbird (no such package)`, download and rerun the **latest** `configure-netbird.sh`. It enables the `community` repository for the **same Alpine stable version already in use** (for example `v3.24/community`) and installs `netbird` and `netbird-openrc` from Alpine's APK repositories.

Verify:

```sh
getent group adguard || grep '^adguard:' /etc/group
rc-service adguardhome status
rc-service netbird status
netbird status -d
```

If `rc-service adguardhome status` is stopped, inspect `/var/log/messages` (or syslog) and `rc-service adguardhome start`. The AdGuard wizard is available on the edge node's LAN IP port 3000 once it is running.

**Security:** Run `finalize-ssh.sh` only after validating a second SSH login with the public key; it deliberately does not run automatically. The optional host firewall can affect connectivity, so confirm console access first.

### AdGuard `setcap`: "Invalid file for capability operation"

Some filesystems, mount configurations or links don't support Linux file capabilities. The bootstrap now attempts to grant `CAP_NET_BIND_SERVICE` to the resolved executable; if that fails, it **asks permission** to apply the alternative `net.ipv4.ip_unprivileged_port_start=53` setting, which permits all local users to bind ports **53–1023**, not only AdGuard. This is a host-wide security tradeoff, but AdGuard itself continues running under the unprivileged `adguard` account, not root. The setting persists in `/etc/sysctl.d/91-adguard-unprivileged-ports.conf`, enabled through the OpenRC `sysctl` boot service.

To rerun after a partial failure, download the latest bootstrap, choose the **existing** administrator username and hostname, and paste the same SSH *public* key. The script preserves AdGuard configuration and does not overwrite router settings.

### Alpine does not install `sudo` by default

When your prompt ends with `#`, you are already root and run commands directly (for example `apk update`). From your normal `keiki` account, use `doas apk update`: the bootstrap installs `doas` and grants the configured admin the `wheel` group. Verify from the non-root account with `doas id`. You may explicitly install `sudo` with `apk add sudo` as root if you prefer, but `doas` uses less space on this 8GB edge device.

### AdGuard `executable is not a regular file`

Older bootstrap versions used `-x /opt/adguardhome/AdGuardHome` to detect the program. A directory also satisfies `-x`, so a partially extracted archive could be mistaken for a valid executable. The current bootstrap validates a real ELF executable, downloads and checks the official release checksum, then installs only the binary from the archive. If an invalid target already exists, it is **moved into a timestamped `/opt/adguardhome/AdGuardHome.invalid.*` backup**; it is not deleted. It does not touch `/etc/adguardhome` or `/var/lib/adguard`.

To inspect the system without making changes:

```sh
ls -ld /opt/adguardhome /opt/adguardhome/AdGuardHome
find /opt/adguardhome -maxdepth 4 -name AdGuardHome -print
```

After fetching the updated script, rerun with the **existing** admin username and public key. Do not delete any directory manually.
