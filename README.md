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

If a kernel reboot is required for AmneziaWG DKMS, the interactive installer can create a one-time systemd resume unit, reboot, and continue automatically after the VPS comes back. The resume unit removes itself before running, so it does not start after later reboots.

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
