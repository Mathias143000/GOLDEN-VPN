# GOLDEN-VPN

Golden install script for a fresh Ubuntu/Debian VPS.

It deploys:

- primary: AmneziaWG 3.1 on `51820/udp`
- backup №2: Hysteria2 Salamander on `8443/udp`
- TCP/TLS fallback: Trojan XHTTP TLS in `auto` mode on `443/tcp` behind nginx and the domain certificate
- randomized static decoy HTTPS site on `https://DOMAIN/`
- Grafana, Prometheus, and Node Exporter on localhost only

## Requirements

Before running the installer:

- point `A DOMAIN` to the VPS public IPv4
- keep Cloudflare proxy status as DNS only / grey cloud
- run as `root`
- use a Cloudflare token with DNS edit access for the zone
- use an AWG 3.1-capable client (AmneziaVPN `5.0.1.5+`, DefaultVPN `2.0.1.1+`, or a current native AWG client)

AWG 3.1 profiles are not compatible with AWG 2.0 clients. Router clients that do not support AWG 3.1 need Hysteria2/Trojan or a separately retained AWG 2.0 service; a clean Golden install does not create a legacy AWG 2.0 contour.

## Two-Stage Bootstrap Install

Default install is a guided two-stage flow:

1. `bootstrap` asks for required values, saves `/etc/golden-vpn-installer/install.env`, installs only minimal bootstrap dependencies, keeps SSH reachable, schedules one one-shot stage2 timer, and reboots once.
2. `install` runs once after reboot, reads the saved env, installs the full stack, writes reports, and removes the one-shot units after the first attempt.

Run on a fresh VPS as `root`:

```bash
apt-get -o DPkg::Lock::Timeout=1800 update
apt-get -o DPkg::Lock::Timeout=1800 install -y curl ca-certificates

curl -fsSL https://raw.githubusercontent.com/Mathias143000/GOLDEN-VPN/main/install-vpn-stack.sh -o install-vpn-stack.sh
chmod +x install-vpn-stack.sh

./install-vpn-stack.sh
```

The commands above install only the bootstrap download prerequisites. Bootstrap then installs only the minimal boot-safe set: `openssh-server`, `curl`, `wget`, `ca-certificates`, `gnupg`, `iproute2`, `ufw`, and small support tools. Stage2 installs the full package set, including `jq`, `nginx`, `grafana`, `dkms`, monitoring packages, and VPN dependencies, after the reboot and SSH guard.

The installer asks for `DOMAIN`, `EMAIL`, `SERVER_LOCATION`, and `CF_Token`. It also offers an optional `Advanced tuning? [y/N]` block for `AWG_OBFS_PROFILE`, `AWG_MTU`, `DECOY_PROFILE`, and `DECOY_SEED`.

After the reboot, reconnect by SSH. The installer adds a guarded block to `/root/.bashrc`, so an interactive root login automatically shows the colored stage2 progress and recent logs with `vpn-install-status auto`. No command input is required after reboot.

Manual watcher:

```bash
vpn-install-status watch
```

If stage2 fails, it disables the one-shot units so the VPS does not retry on every reboot. The saved env, installer copy, and log remain for manual retry:

```bash
vpn-install-status status
vpn-install-status log 200
bash /root/vpn-stack-resume/install-vpn-stack.sh install
```

## Install From GitHub

Same default two-stage bootstrap flow, shown without explanations:

```bash
apt-get -o DPkg::Lock::Timeout=1800 update
apt-get -o DPkg::Lock::Timeout=1800 install -y curl ca-certificates

curl -fsSL https://raw.githubusercontent.com/Mathias143000/GOLDEN-VPN/main/install-vpn-stack.sh -o install-vpn-stack.sh
chmod +x install-vpn-stack.sh

./install-vpn-stack.sh
```

Installer modes:

```bash
./install-vpn-stack.sh bootstrap
./install-vpn-stack.sh preflight
./install-vpn-stack.sh install
./install-vpn-stack.sh validate
./install-vpn-stack.sh report
./install-vpn-stack.sh render-decoy /tmp/decoy-preview
```

The installer asks for:

```text
DOMAIN
EMAIL
SERVER_LOCATION
CF_Token
```

`EMAIL` must be plain ASCII, for example `teriomta@gmail.com`. Do not paste Cyrillic lookalikes or hidden characters.
`SERVER_LOCATION` must be two ASCII letters, for example `EE`, `NL`, or `DE`.

`CF_Token` input is hidden. If the token cannot read the Cloudflare zone ID automatically, the installer also asks for `CF_Zone_ID`.

For unattended install, export variables before running:

```bash
export DOMAIN="s5.super-lemming.online"
export EMAIL="teriomta@gmail.com"
export SERVER_LOCATION="EE"
export CF_Token="CLOUDFLARE_DNS_TOKEN"
# Optional fallback:
export CF_Zone_ID="CLOUDFLARE_ZONE_ID"
./install-vpn-stack.sh
```

Optional tuning variables:

```bash
export AWG_OBFS_PROFILE="random-balanced"   # dns, quic-lite, video-call, mobile-low-mtu, random-balanced, custom
export AWG_MTU="1320"                       # tested baseline; auto or 1280 fallback are also supported
export AWG_ENDPOINT_PORT="51820"
export AWG_DNS="1.1.1.1, 8.8.8.8"
export AWG_ALLOWED_IPS="0.0.0.0/0, ::/0"
export AWG_KEEPALIVE="25"
# AWG 3.1 defaults already enable header protection, content padding,
# timing ranges and random trailers. Advanced explicit overrides:
export AWG_CONTENT_PADDING_ADDITION="16-96"
export AWG_REKEY_AFTER_TIME="110-130"
export AWG_REKEY_TIMEOUT="4-7"
export AWG_REJECT_AFTER_TIME="170-190"
export AWG_KEEPALIVE_TIMEOUT="8-12"
export AWG_MAX_HANDSHAKE_ATTEMPTS="15-20"
export AWG_RANDOM_TRAILERS="on"
export AWG_DISABLE_COOKIES="off"             # keep DoS cookie protection enabled

export DECOY_PROFILE="random"               # network-monitor, software-status, edge-docs, availability-lab, random
export DECOY_SEED="optional-repeatable-seed"
export DECOY_BRAND="Optional Brand"
export DECOY_REGION="EU-West"
```

If you want to skip bootstrap and run the full install immediately, use explicit stage2 mode:

```bash
export VPN_STACK_NO_AUTO_REBOOT=1
export VPN_STACK_IGNORE_SAVED_ENV=1
./install-vpn-stack.sh install
```

Stage2 status:

```bash
vpn-install-status
vpn-install-status auto
vpn-install-status watch
journalctl -u vpn-stack-resume-install.service -b --no-pager
systemctl list-timers vpn-stack-resume-install.timer --no-pager
cat /var/log/vpn-stack-resume-install.log
cat /var/log/vpn-stack-ssh-guard.log
```

While the resume service is active, do not run `install-vpn-stack.sh` manually. The installer holds a lock at `/run/golden-vpn-install.lock`; a second run exits with a status message instead of competing for `apt`/`dpkg`.

The installer keeps SSH open before enabling UFW: it allows `22/tcp`, the current SSH session port from `SSH_CONNECTION`, and ports reported by `sshd`.

Clean stale one-shot state before a reinstall:

```bash
systemctl disable --now vpn-stack-resume-install.timer vpn-stack-resume-install.service vpn-stack-ssh-guard.service 2>/dev/null || true
rm -f /etc/systemd/system/vpn-stack-resume-install.service /etc/systemd/system/vpn-stack-resume-install.timer /etc/systemd/system/vpn-stack-ssh-guard.service
rm -f /usr/local/sbin/vpn-stack-resume-install.sh /usr/local/sbin/vpn-stack-ssh-guard.sh
rm -f /root/vpn-stack-resume/install-vpn-stack.sh /etc/golden-vpn-installer/install.env
systemctl daemon-reload || true
```

Useful diagnostics:

```bash
journalctl -u vpn-stack-resume-install.service -b --no-pager
systemctl status vpn-stack-resume-install.service --no-pager -l
journalctl -u vpn-stack-ssh-guard.service -b --no-pager
```

Manual fallback after reboot:

```bash
apt-get -o DPkg::Lock::Timeout=1800 update
apt-get -o DPkg::Lock::Timeout=1800 install -y git curl ca-certificates

if [ -d /root/GOLDEN-VPN/.git ]; then
  git -C /root/GOLDEN-VPN pull --ff-only
else
  git clone https://github.com/Mathias143000/GOLDEN-VPN.git /root/GOLDEN-VPN
fi
cd /root/GOLDEN-VPN

export VPN_STACK_NO_AUTO_REBOOT=1
export VPN_STACK_IGNORE_SAVED_ENV=1
./install-vpn-stack.sh install
```

Resume logs:

```bash
vpn-install-status
vpn-install-status watch
journalctl -u vpn-stack-resume-install.service -b --no-pager
systemctl list-timers vpn-stack-resume-install.timer --no-pager
cat /var/log/vpn-stack-ssh-guard.log
cat /var/log/vpn-stack-resume-install.log
```

## Install With Git

```bash
apt-get -o DPkg::Lock::Timeout=1800 update
apt-get -o DPkg::Lock::Timeout=1800 install -y git curl ca-certificates

git clone https://github.com/Mathias143000/GOLDEN-VPN.git
cd GOLDEN-VPN
chmod +x install-vpn-stack.sh

./install-vpn-stack.sh
```

## After Install

Create clients:

```bash
vpn-trojan phone1
vpn-hysteria phone1
vpn-awg phone1
```

Create one Hiddify-style static subscription bundle:

```bash
vpn-sub create phone1
vpn-sub show phone1
```

The subscription helper creates linked Trojan, Hysteria2, and AmneziaWG credentials. It prints a terminal QR code and a private import URL:

```text
https://DOMAIN/s/<token>
```

Subscription URL shape:

```text
Browser portal:  https://DOMAIN/s/<token>
Client import:   https://DOMAIN/s/<token>
Plain payload:   https://DOMAIN/s/<token>/sub.txt
Base64 payload:  https://DOMAIN/s/<token>/sub.base64
AWG download:    https://DOMAIN/s/<token>/awg.conf
AWG preview:     https://DOMAIN/s/<token>/awg
```

Lifecycle:

```bash
vpn-sub list
vpn-sub show phone1
vpn-sub revoke phone1
vpn-sub rotate phone1
```

Private metadata is stored in `/opt/vpn-stack/subscriptions/<token>/meta.json`; nginx-served files are stored in `/var/www/subscriptions/<token>/`. Install reports mention these paths but never include tokens or client secrets.

## Bot Export And Migration

Golden exports typed AmneziaWG, Trojan, and Hysteria2 SQLite bundles. `vpn-seller` preserves the key type and imports generated stock as `available`; an inventory of already configured keys is imported as `issued` and cannot be sold again.

Configure the dedicated Golden issuer bot on the VPN server. Do not reuse the `vpn-seller` token:

```bash
install -d -m 0700 /etc/golden-vpn-installer
install -m 0600 /dev/null /etc/golden-vpn-installer/issuer-bot.env
nano /etc/golden-vpn-installer/issuer-bot.env
```

```bash
GOLDEN_ISSUER_BOT_TOKEN='123456:ISSUER_BOT_TOKEN'
GOLDEN_ISSUER_CHAT_ID='-1001234567890'
```

Export all non-revoked client files with explicit types and send the bundle to the administrative chat:

```bash
vpn-bot-export inventory --type all --plan plan_30 \
  --out /root/vpn-keys/bot-export/active-keys.sqlite --send
```

Telegram inventory delivery is always one complete bundle. `--send` is accepted only with `--type all`; type filters are reserved for local diagnostics and are not sent separately.

Create a new stock batch of one selected type and send it:

```bash
vpn-bot-export batch --type awg --count 20 --prefix stock --plan plan_30 --send
vpn-bot-export batch --type trojan --count 20 --prefix stock --plan plan_30 --send
vpn-bot-export batch --type hysteria --count 20 --prefix stock --plan plan_30 --send
```

`--send` attaches the root-only SQLite file to a message from the bot in the configured admin chat. Telegram does not deliver a bot's own message back to its update handler, so upload or forward that attachment to `/admin_import` to place it in bot inventory. The preview shows counts by type and status before confirmation.

Certificate notifications use the same Telegram settings. A daily timer sends deduplicated warnings at 30, 14, 7, 3, 1, and 0 days before expiry. Successful acme.sh replacement sends a renewal notification.

```bash
vpn-cert-notify test
vpn-cert-notify check --dry-run
systemctl status vpn-cert-notify.timer
```

Responsibility boundary:

```text
Golden issuer bot: create keys, export existing/new keys, report TLS expiry/replacement
vpn-seller: customer identity and key mapping, incident decisions, customer notifications, replacement delivery
```

Golden never contacts customers, assigns replacements to customers, or revokes their old key automatically. The `emergency` command only prepares a root-only mapping bundle that `vpn-seller` applies through `/admin_emergency`.

Create a secret-free server audit on every VPN server:

```bash
vpn-bot-export audit --out /root/vpn-keys/bot-export/server-audit.json
```

Create an import bundle for bot stock:

```bash
vpn-bot-export keys --plan plan_30 --out /root/vpn-keys/bot-export/keys.sqlite
```

Upload `keys.sqlite` to the bot with `/admin_import`. The bundle contains:

```sql
CREATE TABLE keys (
  plan_code TEXT NOT NULL,
  conf_text TEXT NOT NULL,
  external_ref TEXT,
  comment TEXT,
  expires_at TEXT
);
```

Create an emergency replacement bundle from a CSV map:

```bash
mkdir -p /root/vpn-migration
cat >/root/vpn-migration/map.csv <<'CSV'
client_name,old_key_fingerprint,old_conf_path,new_conf_path,plan_code,new_external_ref,new_comment,expires_at
phone1,,/root/old-keys/AWG-EE-phone1.conf,/root/vpn-keys/awg/AWG-US-phone1.conf,plan_30,,,
CSV

vpn-bot-export emergency --map /root/vpn-migration/map.csv --out /root/vpn-keys/bot-export/emergency.sqlite
```

If `old_key_fingerprint` is empty, Golden calculates it from `old_conf_path` using the same normalization rule as the bot. Upload `emergency.sqlite` with `/admin_emergency`.

Useful fingerprint command:

```bash
vpn-bot-export fingerprint /root/vpn-keys/awg/AWG-US-phone1.conf
```

Five-to-three-server migration checklist for the audited deployment:

1. Run `vpn-bot-export audit` on all five servers.
2. Keep the USA server as a required target.
3. Keep France and Estonia; retire Sweden and Netherlands after their users are confirmed on a target. Netherlands has the joint-lowest profile count and the weakest audited service health.
4. Run `upgrade-check` and then the profile-preserving `upgrade` on existing Golden servers before generating any replacement credentials.
5. Generate fresh AWG configs on target servers only for users who are actually being moved; upgrade never replaces existing profiles.
6. Import available target stock into the bot with `/admin_import`.
7. Prepare `emergency.sqlite` mappings from old issued fingerprints to new target configs.
8. Apply the migration or failover through `/admin_emergency`.

Initial client files:

```text
/root/vpn-keys/trojan/TROJAN-EE-main-trojan.txt
/root/vpn-keys/hysteria/HYSTERIA-EE-main-hysteria-client.txt
/root/vpn-keys/awg/AWG-EE-main-awg.conf
```

New client display labels and saved filenames use `TROJAN-<LOCATION>-<name>`, `HYSTERIA-<LOCATION>-<name>`, and `AWG-<LOCATION>-<name>`.
Each client helper prints a terminal QR code, the raw link or config text, and the saved file path.

The decoy site is generated at install time:

```text
/var/www/decoy/index.html
/var/www/decoy/status.html
/var/www/decoy/docs.html
/var/www/decoy/privacy.html
/var/www/decoy/404.html
/var/www/decoy/robots.txt
/var/www/decoy/assets/style.css
```

The decoy generator is embedded in `install-vpn-stack.sh`: it writes static HTML/CSS directly, chooses one of the built-in profiles, records the profile/seed/palette in `/opt/vpn-stack/decoy-manifest.json`, and serves it through nginx on `443/tcp`. It does not clone templates, use external CDN assets, forms, cookies, analytics, backend code, or JavaScript. The installer scans generated public HTML/CSS for forbidden protocol terms before reloading nginx.

Preview a decoy render without touching nginx:

```bash
./install-vpn-stack.sh render-decoy /tmp/decoy-preview
```

Show the numbered helper menu. The same menu is printed automatically on interactive root login after install state is no longer active:

```bash
vpn-help
vpn-help 1 phone1
vpn-help 7
```

Validate and print install reports:

```bash
./install-vpn-stack.sh validate
./install-vpn-stack.sh report
cat /root/vpn-keys/install-report.json
```

Report files:

```text
/root/vpn-keys/install-report.txt
/root/vpn-keys/install-report.json
/opt/vpn-stack/awg-tuning-report.json
/opt/vpn-stack/decoy-manifest.json
```

Open Grafana through SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 root@SERVER_IP
```

Then open:

```text
http://localhost:3000
```

Default Grafana login:

```text
admin / admin
```

## AmneziaWG Diagnostics

```bash
vpn-awg analyze
vpn-awg analyze 20
vpn-awg capture 30
vpn-awg analyze-live 20
vpn-awg profile
vpn-awg explain
vpn-awg list
vpn-awg show phone1
vpn-awg revoke phone1
vpn-awg rotate phone1
```

Captures are saved under:

```text
/var/log/vpn-stack/awg-captures/
```

Golden installs AmneziaWG 3.1 and refuses to continue if the installed tools or kernel module reject the 3.1 runtime fields. Header protection, content padding, timing ranges and random trailers are enabled; cookie replies remain enabled for denial-of-service resistance. `J/S/H/I1-I5` values are randomized from the selected profile. Supported profiles are `dns`, `quic-lite`, `video-call`, `mobile-low-mtu`, `random-balanced`, and `custom`; default is `random-balanced`. The installer writes `/opt/vpn-stack/awg-params.env` and `/opt/vpn-stack/awg-tuning-report.json`. Default MTU is `1320`; `AWG_MTU=auto` performs a server-side PMTU probe with fallback to `1280`, and an explicit value may be set from `1200..1420`. Tcpdump is never run automatically.

## Protocol engine updates

Stable engine updates are checked daily without rebooting the VPS:

```bash
systemctl status vpn-awg-auto-update.timer
systemctl status vpn-core-auto-update.timer
systemctl start vpn-awg-auto-update.service
systemctl start vpn-core-auto-update.service
journalctl -u vpn-awg-auto-update.service --no-pager
journalctl -u vpn-core-auto-update.service --no-pager
```

`vpn-awg-auto-update` updates only official Amnezia PPA packages after saving exact rollback packages and current AWG profiles. It reloads and validates AWG 3.1, and restores the prior packages if activation fails. `vpn-core-auto-update` uses the official stable-channel installers for Xray and Hysteria, saves both binaries first, tests the Xray config, restarts only their custom Golden services, checks the Unix socket and UDP listener, and restores the prior binaries on failure. Each updater retains the five newest successful backup directories. Pre-release Xray builds and incompatible AWG major upgrades are not installed automatically.

The Trojan XHTTP profile uses `mode=auto`, real domain TLS, nginx HTTP/2, the secret XHTTP path, and the Xray Unix socket. Client links do not force a `fp` value; the client may use its own supported TLS implementation. No extra Xray mux or speculative manual `extra` tuning is enabled. The decoy is a multi-page static HTTPS site with local CSS and no external assets, forms, analytics or scripts.

The old daily `vpn-soft-reboot.timer` is removed and disabled. Boot healthcheck remains enabled.

## Disk and log protection

Preflight requires at least 5 GB free on `/` and 5% free inodes before a full install; bootstrap requires 1 GB. The full-install reserve accounts for packages, monitoring data, and creation of the 2 GB fallback swap file. A resumed stage2 attempt may use a 3 GB reserve only after `jq`, nginx, Grafana, and Prometheus are confirmed installed; a clean attempt never receives the reduced threshold. The installed limits are:

```text
journald: 200 MB / 7 days, vacuumed immediately and hourly
Golden VPN logs: daily, 7 compressed rotations
rsyslog /var/log/syslog: maxsize 50 MB, checked hourly
Grafana: 16 MB native rotation, 3-day retention, 20 MB logrotate fallback
Docker JSON logs, when Docker coexists: 20 MB, 3 compressed rotations
x-ui logs, when a legacy x-ui installation coexists: 20 MB, 3 compressed rotations
APT package cache: cleaned hourly
Prometheus: 7 days / 1 GB
```

Storage maintenance is provided by:

```bash
systemctl status logrotate.timer
systemctl status vpn-storage-maintenance.timer
systemctl start vpn-storage-maintenance.service
```

Apply only the storage protections to an existing installation without reinstalling VPN services:

```bash
./install-vpn-stack.sh storage-repair
```

The hourly maintenance job performs a bounded journal vacuum, removes Grafana's expired dated rotations, cleans the APT package cache, and forces bounded rotations when `/` reaches 90% usage. It does not delete Docker images, volumes, containerd snapshots, VPN keys, or active configuration files.

## Profile-preserving upgrades

Never run the full `install` mode over a working server. Full install intentionally creates a fresh server identity and fresh initial clients. Use the dedicated upgrade flow instead:

```bash
chmod +x install-vpn-stack.sh
./install-vpn-stack.sh upgrade-check
./install-vpn-stack.sh upgrade
```

If an older installation does not yet contain `/opt/vpn-stack/server-location.txt`, provide the location explicitly so newly created labels remain correct:

```bash
SERVER_LOCATION=FR ./install-vpn-stack.sh upgrade-check
SERVER_LOCATION=FR ./install-vpn-stack.sh upgrade
```

`upgrade-check` is read-only. It detects the installed Xray protocol and reports Xray, Hysteria, and AWG profile counts without printing credentials.

`upgrade` updates only the feature overlay: compatible helper commands, subscription/export tooling, monitoring, timers, and storage protection. It does not call the Xray, Hysteria, AWG, nginx, certificate, firewall, or clean-install configuration functions and does not restart VPN protocol services.

Before changing the overlay, it creates a root-only backup under:

```text
/root/vpn-keys/upgrade-backups/<UTC timestamp>.<unique suffix>/
```

The backup contains the current protocol registries, server configs, client files, and subscription bundles. A secret-free structural/hash manifest is written before and after the upgrade. Success is reported only if the protected profile set is byte-for-byte unchanged. The result is stored in `/root/vpn-keys/upgrade-report.json` and the installed script version in `/opt/vpn-stack/installer-version.txt`.

Legacy VLESS XHTTP installations are detected automatically. Their VLESS service, config, helper, and users are preserved; the upgrade deliberately does not install Trojan/subscription helpers over that server. Migrating VLESS users to Trojan remains a separate, parallel credential migration with a grace period.

To restore the protected profile state from a specific upgrade backup, first verify the archive path and checksum, then run the explicit rollback command:

```bash
sha256sum -c /root/vpn-keys/upgrade-backups/<backup>/profiles.tar.sha256
./install-vpn-stack.sh upgrade-rollback \
  /root/vpn-keys/upgrade-backups/<backup> \
  --confirm-profile-restore
```

Rollback replaces only the protected Xray, Hysteria, AWG, client-file, and subscription roots recorded in that backup. It verifies the archive paths and the restored byte-for-byte manifest. It deliberately does not restart VPN services; validate the restored configs before restarting only the affected service.

## Parallel legacy VLESS to Trojan migration

Legacy VLESS XHTTP TLS users require new Trojan credentials, but they do not need to be disconnected during preparation. Build a root-only migration bundle first:

```bash
./install-vpn-stack.sh migrate-vless-to-trojan-prepare
```

Preparation does not change live Xray/nginx files or restart services. The bundle contains candidate configs, checksums, a protected before-state, one mapped Trojan credential per existing labelled VLESS client, and the corresponding client links.

After reviewing the bundle, creating a provider snapshot, and arranging a maintenance window, apply that exact bundle explicitly:

```bash
./install-vpn-stack.sh migrate-vless-to-trojan-apply \
  /root/vpn-migration/vless-to-trojan/<bundle> \
  --confirm-parallel-trojan
```

Apply refuses stale or modified bundles, verifies that live Xray/nginx and protected VLESS/Hysteria/AWG state still match the prepared preimage, and creates a fresh upgrade backup. It adds a second Trojan inbound and nginx secret path while preserving the existing VLESS inbound. It tests both configs, restarts the existing Xray service once, reloads nginx, and requires both VLESS and Trojan unix sockets. A validation or activation failure automatically restores the exact VLESS preimage. Hysteria and AWG are not restarted.

Successful migration records its result in:

```text
/root/vpn-keys/vless-to-trojan-report.json
```

Keep VLESS active through the migration grace period. Removing the legacy inbound remains a separate confirmed operation after all required users have successfully moved.

## Same-key AWG MTU and full-tuning migration

To normalize an existing Golden AWG contour without rotating any key, first prepare a root-only candidate bundle. The tested mobile baseline is `1320`:

```bash
./install-vpn-stack.sh migrate-awg-mtu-prepare 1320
```

Preparation leaves live AWG untouched. It copies the exact preimage, reads the server's existing `Jc/Jmin/Jmax`, `S1-S4`, `H1-H4`, and `I1-I5`, writes MTU `1320` into candidate server/client configs, and synchronizes any missing full AWG 2.0 tuning fields into saved client configs. A normalized identity manifest proves that private keys, public keys, preshared keys, addresses, peers, endpoints, allowed IPs, and other non-tuning material did not change.

After provider snapshot and bundle review:

```bash
./install-vpn-stack.sh migrate-awg-mtu-apply \
  /root/vpn-migration/awg-mtu/<bundle> \
  --confirm-awg-mtu
```

Apply rejects stale source files, validates the candidate through `awg-quick strip`, creates a fresh profile backup, restarts only `awg-quick@awg0`, verifies runtime MTU and AWG status, and restores the exact server/client preimage if activation or identity verification fails. It also reconstructs `/opt/vpn-stack/awg-params.env` from the preserved server tuning so future clients inherit the same full obfuscation and MTU.

No credential is reissued. Existing imported clients continue using their local MTU until the updated same-key `.conf` is re-imported. The result is recorded in `/root/vpn-keys/awg-mtu-migration-report.json`.

## Troubleshooting

If `vpn-awg <name>` reports `printf: write error: No space left on device` while `/` is not full, check `/tmp`, `/run`, and inode usage. Older helpers wrote the AWG preshared key through a `mktemp` file, so a full tmpfs or exhausted inode table could break client creation even with free root-disk space. Current helpers avoid that temp file and `vpn-awg analyze` prints storage diagnostics.

```bash
vpn-awg analyze
df -h / /tmp /run /etc/amnezia/amneziawg /root/vpn-keys/awg
df -ih / /tmp /run /etc/amnezia/amneziawg /root/vpn-keys/awg
```
If SSH is blocked after a reboot, open the VPS provider web console or rescue console and restore SSH in UFW:

```bash
systemctl unmask ssh sshd ssh.service sshd.service ssh.socket || true
systemctl enable --now ssh.service || systemctl enable --now sshd.service || systemctl enable --now ssh.socket
systemctl restart ssh.service || systemctl restart sshd.service || true
ufw allow 22/tcp
ufw allow OpenSSH
ufw reload || ufw --force enable
ufw status verbose
systemctl status ssh sshd --no-pager
ss -lntp | grep ':22'
```

Then inspect the one-shot boot helpers:

```bash
journalctl -u vpn-stack-ssh-guard.service -b --no-pager
journalctl -u vpn-stack-resume-install.service -b --no-pager
systemctl list-timers vpn-stack-resume-install.timer --no-pager
cat /var/log/vpn-stack-ssh-guard.log
cat /var/log/vpn-stack-resume-install.log
```

If you see `Could not get lock /var/lib/dpkg/lock-frontend`, another install, cloud-init first-boot upgrade, or provider dist-upgrade is still using `apt`. Do not remove the lock file. The installer waits up to `APT_LOCK_TIMEOUT=1800` seconds and prints lock-holder PIDs. Watch the running installer instead:

```bash
vpn-install-status watch
# or
journalctl -fu vpn-stack-resume-install.service
```

ZeroSSL is the primary CA. If ZeroSSL registration fails with `Cannot resolve _eab_id` or the ZeroSSL EAB API returns `403`, the installer automatically falls back to Let's Encrypt DNS-01 for this certificate and continues without asking for manual EAB credentials.

To require strict ZeroSSL only, disable the fallback before retrying:

```bash
export VPN_STACK_DISABLE_LE_FALLBACK=1
./install-vpn-stack.sh
```

If AmneziaWG DKMS fails and the log says the running kernel is older than the latest installed kernel, reboot first:

```bash
reboot
```

After the VPS comes back:

```bash
apt-get -f install -y
dpkg --configure -a
./install-vpn-stack.sh install
```

If DKMS still fails, check:

```bash
tail -n 120 /var/lib/dkms/amneziawg/1.0.0/build/make.log
```

If acme.sh reports `invalid_email` or `contact email contains non-ASCII characters`, rerun with a clean ASCII email:

```bash
export EMAIL="teriomta@gmail.com"
export VPN_STACK_IGNORE_SAVED_ENV=1
./install-vpn-stack.sh
```
