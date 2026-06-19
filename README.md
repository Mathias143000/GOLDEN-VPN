# GOLDEN-VPN

Golden install script for a fresh Ubuntu/Debian VPS.

It deploys:

- Trojan XHTTP TLS on `443/tcp` behind nginx and the domain certificate
- Hysteria2 Salamander on `8443/udp`
- AmneziaWG 2.0 on `51820/udp`
- randomized static decoy HTTPS site on `https://DOMAIN/`
- Grafana, Prometheus, and Node Exporter on localhost only

## Requirements

Before running the installer:

- point `A DOMAIN` to the VPS public IPv4
- keep Cloudflare proxy status as DNS only / grey cloud
- run as `root`
- use a Cloudflare token with DNS edit access for the zone

## Safe Two-Stage Install

Use this flow on fresh VPS hosts. It keeps SSH explicit, clears stale one-time resume units, performs one manual reboot, then installs from Git without installer-managed reboot/resume.

Stage 1, run from the VPS console or SSH, then let it reboot:

```bash
cat >/root/golden-vpn-preflight.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

systemctl disable --now vpn-stack-resume-install.timer vpn-stack-resume-install.service vpn-stack-ssh-guard.service 2>/dev/null || true
rm -f /etc/systemd/system/vpn-stack-resume-install.service /etc/systemd/system/vpn-stack-resume-install.timer /etc/systemd/system/vpn-stack-ssh-guard.service
rm -f /usr/local/sbin/vpn-stack-resume-install.sh /usr/local/sbin/vpn-stack-ssh-guard.sh
rm -f /root/vpn-stack-resume/install-vpn-stack.sh /etc/golden-vpn-installer/install.env
rmdir /root/vpn-stack-resume /etc/golden-vpn-installer 2>/dev/null || true
systemctl daemon-reload || true

while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
  echo "Waiting for apt/dpkg lock..."
  sleep 5
done

dpkg --configure -a
apt-get -f install -y
apt-get update
apt-get install -y openssh-server curl ca-certificates git
ssh-keygen -A

systemctl unmask ssh sshd ssh.service sshd.service ssh.socket || true
systemctl enable --now ssh.service || systemctl enable --now sshd.service || systemctl enable --now ssh.socket
systemctl restart ssh.service || systemctl restart sshd.service || true

ufw allow 22/tcp || true
ufw allow OpenSSH || true
ufw reload || ufw --force enable || true
ss -lntp | grep -E ':(22)\b'

reboot
EOF

bash /root/golden-vpn-preflight.sh
```

Stage 2, after the VPS comes back and SSH works:

```bash
apt-get update
apt-get install -y git curl ca-certificates

if [ -d /root/GOLDEN-VPN/.git ]; then
  git -C /root/GOLDEN-VPN pull --ff-only
else
  git clone https://github.com/Mathias143000/GOLDEN-VPN.git /root/GOLDEN-VPN
fi
cd /root/GOLDEN-VPN

export VPN_STACK_NO_AUTO_REBOOT=1
export VPN_STACK_IGNORE_SAVED_ENV=1

if [ -n "${DOMAIN:-}" ] && [ -n "${EMAIL:-}" ] && [ -n "${SERVER_LOCATION:-}" ] && [ -n "${CF_Token:-}" ]; then
  ./install-vpn-stack.sh preflight
fi

./install-vpn-stack.sh install
```

## Install From GitHub

```bash
apt-get update
apt-get install -y curl

curl -fsSL https://raw.githubusercontent.com/Mathias143000/GOLDEN-VPN/main/install-vpn-stack.sh -o install-vpn-stack.sh
chmod +x install-vpn-stack.sh

./install-vpn-stack.sh
```

Installer modes:

```bash
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
# Recommended for manual two-stage installs:
export VPN_STACK_NO_AUTO_REBOOT=1
export VPN_STACK_IGNORE_SAVED_ENV=1

./install-vpn-stack.sh
```

Optional tuning variables:

```bash
export AWG_OBFS_PROFILE="random-balanced"   # dns, quic-lite, video-call, mobile-low-mtu, random-balanced, custom
export AWG_MTU="1280"                       # or auto
export AWG_ENDPOINT_PORT="51820"
export AWG_DNS="1.1.1.1, 8.8.8.8"
export AWG_ALLOWED_IPS="0.0.0.0/0, ::/0"
export AWG_KEEPALIVE="25"

export DECOY_PROFILE="random"               # network-monitor, software-status, edge-docs, availability-lab, random
export DECOY_SEED="optional-repeatable-seed"
export DECOY_BRAND="Optional Brand"
export DECOY_REGION="EU-West"
```

If a kernel reboot is required for AmneziaWG DKMS, the installer stops and asks you to reboot manually. Automatic reboot/resume is disabled by default to avoid losing SSH access. The old one-time resume prompt is available only when explicitly requested:

```bash
export VPN_STACK_ALLOW_REBOOT_PROMPT=1
```

The older systemd resume flow saves values in `/etc/golden-vpn-installer/install.env` and runs `/root/vpn-stack-resume/install-vpn-stack.sh` once after boot. Prefer the Safe Two-Stage Install above for clean servers.

Resume logs:

```bash
vpn-install-status
vpn-install-status follow
journalctl -u vpn-stack-resume-install.service -b --no-pager
systemctl list-timers vpn-stack-resume-install.timer --no-pager
cat /var/log/vpn-stack-ssh-guard.log
cat /var/log/vpn-stack-resume-install.log
```

While the resume service is active, do not run `install-vpn-stack.sh` manually. The installer holds a lock at `/run/golden-vpn-install.lock`; a second run exits with a status message instead of competing for `apt`/`dpkg`.

If the resume service did not start, running `./install-vpn-stack.sh` manually after reboot loads `/etc/golden-vpn-installer/install.env` automatically and continues with the saved `DOMAIN`, `EMAIL`, and Cloudflare token.

The installer keeps SSH open before enabling UFW: it allows `22/tcp`, the current SSH session port from `SSH_CONNECTION`, and ports reported by `sshd`.

## Install With Git

```bash
apt-get update
apt-get install -y git

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

Show help:

```bash
vpn-help
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

AmneziaWG parameters are randomized from the selected profile. Supported profiles are `dns`, `quic-lite`, `video-call`, `mobile-low-mtu`, `random-balanced`, and `custom`; default is `random-balanced`. The installer writes `/opt/vpn-stack/awg-params.env` and `/opt/vpn-stack/awg-tuning-report.json`. Use `AWG_MTU=auto` for a PMTU probe with safe fallback to `1280`, or set an explicit value from `1200..1420`. Tcpdump is not run automatically during install; use `vpn-awg analyze 20`, `vpn-awg capture 30`, or `vpn-awg analyze-live 20` only when you intentionally want packet-size diagnostics.

## Troubleshooting

If SSH is blocked after a reboot, open the VPS provider web console or rescue console and restore SSH in UFW:

```bash
ufw allow 22/tcp
ufw reload || ufw --force enable
ufw status verbose
systemctl status ssh sshd --no-pager
ss -lntp | grep ':22'
```

If you see `Could not get lock /var/lib/dpkg/lock-frontend`, another install or resume process is still using `apt`. Do not remove the lock file. Watch the running installer instead:

```bash
vpn-install-status follow
# or
journalctl -fu vpn-stack-resume-install.service
```

ZeroSSL is the primary CA. If ZeroSSL registration fails with `Cannot resolve _eab_id` or the ZeroSSL EAB API returns `403`, the installer automatically falls back to Let's Encrypt DNS-01 for this certificate and continues without asking for manual EAB credentials.

To require strict ZeroSSL only, disable the fallback before retrying:

```bash
export VPN_STACK_DISABLE_LE_FALLBACK=1
./install-vpn-stack.sh
```

If AmneziaWG DKMS fails and the log says the running kernel is older than the latest installed kernel, use the built-in one-time reboot/resume prompt or reboot first:

```bash
reboot
```

After the VPS comes back:

```bash
apt-get -f install -y
dpkg --configure -a
./install-vpn-stack.sh
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
