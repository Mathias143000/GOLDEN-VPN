# GOLDEN-VPN

Golden install script for a fresh Ubuntu/Debian VPS.

It deploys:

- VLESS XHTTP TLS on `443/tcp` behind nginx and the domain certificate
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

## Install From GitHub

```bash
apt-get update
apt-get install -y curl

curl -fsSL https://raw.githubusercontent.com/Mathias143000/GOLDEN-VPN/main/install-vpn-stack.sh -o install-vpn-stack.sh
chmod +x install-vpn-stack.sh

./install-vpn-stack.sh
```

The installer asks for:

```text
DOMAIN
EMAIL
CF_Token
```

`CF_Token` input is hidden. If the token cannot read the Cloudflare zone ID automatically, the installer also asks for `CF_Zone_ID`.

For unattended install, export variables before running:

```bash
export DOMAIN="s5.super-lemming.online"
export EMAIL="teriomta@gmail.com"
export CF_Token="CLOUDFLARE_DNS_TOKEN"
# Optional fallback:
export CF_Zone_ID="CLOUDFLARE_ZONE_ID"
# Optional: if a kernel reboot is pending, reboot and resume installer once.
export VPN_STACK_AUTO_REBOOT_RESUME=1

./install-vpn-stack.sh
```

If a kernel reboot is required for AmneziaWG DKMS, the interactive installer can create a one-time systemd resume unit and boot timer, reboot, and continue automatically after the VPS comes back. The installer saves the entered values in the systemd `EnvironmentFile` `/etc/golden-vpn-installer/install.env` with `0600` permissions, runs `/root/vpn-stack-resume/install-vpn-stack.sh` once after boot through `vpn-stack-resume-install.service` and `vpn-stack-resume-install.timer`, and removes the unit, timer, copied installer, and saved env only after the installation finishes successfully.

Before any installer-triggered reboot, the installer also installs a temporary `vpn-stack-ssh-guard.service` and immediately allows SSH in UFW. This guard opens `22/tcp`, `OpenSSH`, the current SSH session port, and configured `sshd` ports early on boot. It is removed after successful installation.

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
vpn-vless phone1
vpn-hysteria phone1
vpn-awg phone1
```

Initial client files:

```text
/root/vpn-keys/vless/main-vless.txt
/root/vpn-keys/hysteria/main-hysteria-client.txt
/root/vpn-keys/awg/main-awg.conf
```

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

Show help:

```bash
vpn-help
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
```

Captures are saved under:

```text
/var/log/vpn-stack/awg-captures/
```

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
