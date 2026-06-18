#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
export DEBIAN_FRONTEND=noninteractive

STACK_DIR="/opt/vpn-stack"
KEY_DIR="/root/vpn-keys"
XRAY_DIR="${STACK_DIR}/xray"
HYSTERIA_DIR="${STACK_DIR}/hysteria"
LOG_DIR="/var/log/vpn-stack"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN:-}"
PUBLIC_IPV4=""
EXT_IFACE=""
SWAP_RESULT="not checked"

BASE_PACKAGES=(
  curl
  wget
  unzip
  jq
  openssl
  ca-certificates
  socat
  qrencode
  ufw
  lsb-release
  gnupg
  iptables
  tcpdump
  python3
  build-essential
  dkms
  nginx
  libnginx-mod-stream
  prometheus
  prometheus-node-exporter
  grafana
)

log() {
  printf '[vpn-stack] %s\n' "$*"
}

warn() {
  printf '[vpn-stack] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[vpn-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local line="$1"
  warn "Installation failed near line ${line}. Check the messages above."
}
trap 'on_error "$LINENO"' ERR

have_tty() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prompt_required_var() {
  local var="$1"
  local label="$2"
  local secret="${3:-0}"
  local value

  if [[ -n "${!var:-}" ]]; then
    return 0
  fi

  have_tty || die "${var} is empty and no interactive terminal is available. Export ${var}=... before running."

  while true; do
    if [[ "${secret}" == "1" ]]; then
      printf '%s: ' "${label}" >/dev/tty
      IFS= read -r -s value </dev/tty || die "Could not read ${var}."
      printf '\n' >/dev/tty
    else
      printf '%s: ' "${label}" >/dev/tty
      IFS= read -r value </dev/tty || die "Could not read ${var}."
    fi

    value="$(trim_value "${value}")"
    if [[ -n "${value}" ]]; then
      printf -v "${var}" '%s' "${value}"
      export "${var}"
      return 0
    fi

    printf '%s cannot be empty.\n' "${var}" >/dev/tty
  done
}

require_root_and_env() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
  prompt_required_var DOMAIN "DOMAIN, without https://, example s5.example.com"
  prompt_required_var EMAIL "EMAIL for ZeroSSL/acme.sh"
  prompt_required_var CF_Token "Cloudflare DNS API token (hidden input)" 1
  CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

detect_public_ipv4() {
  local ip
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ip="$(curl -4fsS --max-time 8 https://ifconfig.me/ip || true)"
  fi
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Could not determine public IPv4."
  PUBLIC_IPV4="${ip}"
  log "Public IPv4: ${PUBLIC_IPV4}"
}

detect_external_iface() {
  EXT_IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "${EXT_IFACE}" ]] || die "Could not determine external network interface."
  log "External interface: ${EXT_IFACE}"
}

verify_domain_dns() {
  local found
  found="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  [[ -n "${found}" ]] || die "DOMAIN does not resolve to IPv4 yet: ${DOMAIN}"
  if ! printf '%s\n' "${found}" | tr ' ' '\n' | grep -qx "${PUBLIC_IPV4}"; then
    die "DOMAIN must resolve to ${PUBLIC_IPV4}. Current IPv4 answer(s): ${found}. Use Cloudflare DNS only / grey cloud."
  fi
  log "DOMAIN resolves to server IPv4."
}

install_apt_repositories() {
  log "Installing APT prerequisites and external repositories."
  apt-get update
  apt-get install -y apt-transport-https curl wget ca-certificates gnupg lsb-release iproute2 software-properties-common

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      add-apt-repository -y universe || true
    fi
  fi

  install -d -m 0755 /etc/apt/keyrings

  wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
  chmod 0644 /etc/apt/keyrings/grafana.asc
  printf 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main\n' \
    >/etc/apt/sources.list.d/grafana.list
  chmod 0644 /etc/apt/sources.list.d/grafana.list

  install -d -m 0755 /usr/share/keyrings
  if ! gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 75C9DD72C799870E310542E24166F2C257290828 >/dev/null 2>&1; then
    curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828' \
      | gpg --batch --dearmor >/usr/share/keyrings/amnezia.gpg
  else
    gpg --batch --export 75C9DD72C799870E310542E24166F2C257290828 | gpg --batch --dearmor >/usr/share/keyrings/amnezia.gpg
  fi
  chmod 0644 /usr/share/keyrings/amnezia.gpg
  cat >/etc/apt/sources.list.d/amneziawg.list <<'EOF'
deb [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
deb-src [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
EOF
  chmod 0644 /etc/apt/sources.list.d/amneziawg.list

  apt-get update
}

install_base_packages() {
  log "Installing base packages."
  apt-get install -y "${BASE_PACKAGES[@]}" software-properties-common python3-launchpadlib
  apt-get install -y "linux-headers-$(uname -r)" || warn "linux-headers-$(uname -r) was not installable; AmneziaWG DKMS may need manual kernel headers."
}

cloudflare_zone_from_domain() {
  local domain="$1"
  local parts candidate response zone_id
  IFS='.' read -r -a parts <<<"${domain}"
  for ((i=0; i<${#parts[@]}-1; i++)); do
    candidate="$(IFS='.'; echo "${parts[*]:i}")"
    response="$(curl -fsS --max-time 15 \
      -H "Authorization: Bearer ${CF_Token}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones?name=${candidate}&status=active" || true)"
    zone_id="$(printf '%s' "${response}" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
    if [[ -n "${zone_id}" ]]; then
      printf '%s\n' "${zone_id}"
      return 0
    fi
  done
  return 1
}

install_acme_certificate() {
  log "Issuing ZeroSSL certificate with acme.sh DNS-01."
  install -d -m 0700 /root/.acme.sh /root/acme-zerossl
  install -d -m 0755 "${CERT_DIR}"

  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"
  fi

  export CF_Token
  if [[ -z "${CF_Zone_ID:-}" && -z "${CF_Account_ID:-}" ]]; then
    CF_Zone_ID="$(cloudflare_zone_from_domain "${DOMAIN}" || true)"
    if [[ -z "${CF_Zone_ID}" ]]; then
      warn "Could not auto-detect Cloudflare zone. Token may not have Zone:Read permission."
      prompt_required_var CF_Zone_ID "Cloudflare Zone ID"
    fi
    export CF_Zone_ID
  fi

  local acme=(/root/.acme.sh/acme.sh --home /root/.acme.sh --config-home /root/acme-zerossl)
  "${acme[@]}" --set-default-ca --server zerossl
  "${acme[@]}" --register-account -m "${EMAIL}" --server zerossl || true

  if [[ -s "${CERT_DIR}/fullchain.pem" && -s "${CERT_DIR}/privkey.pem" ]] \
    && openssl x509 -checkend 2592000 -noout -in "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1 \
    && openssl pkey -check -noout -in "${CERT_DIR}/privkey.pem" >/dev/null 2>&1; then
    log "Existing certificate is valid for at least 30 days."
    return
  fi

  "${acme[@]}" --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --server zerossl
  "${acme[@]}" --install-cert -d "${DOMAIN}" --ecc \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --key-file "${CERT_DIR}/privkey.pem" \
    --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true; systemctl restart hysteria2 >/dev/null 2>&1 || true"

  openssl x509 -noout -subject -issuer -dates -in "${CERT_DIR}/fullchain.pem"
  openssl pkey -check -noout -in "${CERT_DIR}/privkey.pem"
}

install_xray() {
  log "Installing Xray."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
  systemctl disable --now xray.service >/dev/null 2>&1 || true
}

rand_hex() {
  openssl rand -hex "$1"
}

generate_xray_reality_keys() {
  local output private public
  output="$(/usr/local/bin/xray x25519)"
  private="$(printf '%s\n' "${output}" | awk -F': ' '/Private key|PrivateKey|Private/{print $2; exit}')"
  public="$(printf '%s\n' "${output}" | awk -F': ' '/Public key|PublicKey|Password/{print $2; exit}')"
  [[ -n "${private}" && -n "${public}" ]] || die "Could not parse xray x25519 output."
  printf '%s\n%s\n' "${private}" "${public}"
}

uri_encode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

write_vless_link() {
  local uuid="$1"
  local name="$2"
  local domain public_key short_id path encoded_path fragment link
  domain="$(<"${STACK_DIR}/domain.txt")"
  public_key="$(<"${STACK_DIR}/vless-reality-public-key.txt")"
  short_id="$(<"${STACK_DIR}/vless-reality-short-id.txt")"
  path="$(<"${STACK_DIR}/vless-reality-path.txt")"
  encoded_path="$(uri_encode "${path}")"
  fragment="$(uri_encode "VLESS-REALITY-XHTTP-${name}")"
  link="vless://${uuid}@${domain}:443?security=reality&type=xhttp&encryption=none&path=${encoded_path}&mode=stream-one&sni=www.vk.com&fp=chrome&pbk=${public_key}&sid=${short_id}&spx=%2F#${fragment}"
  install -d -m 0700 "${KEY_DIR}/vless-reality"
  printf '%s\n' "${link}" >"${KEY_DIR}/vless-reality/${name}.txt"
  chmod 0600 "${KEY_DIR}/vless-reality/${name}.txt"
  printf '%s\n' "${link}"
}

configure_xray() {
  log "Configuring VLESS REALITY XHTTP."
  install -d -m 0700 "${STACK_DIR}" "${XRAY_DIR}" "${LOG_DIR}" "${KEY_DIR}/vless-reality"
  printf '%s\n' "${DOMAIN}" >"${STACK_DIR}/domain.txt"
  printf '%s\n' "${PUBLIC_IPV4}" >"${STACK_DIR}/public-ipv4.txt"
  printf '%s\n' "${EXT_IFACE}" >"${STACK_DIR}/external-interface.txt"

  local uuid path short_id keys private public
  uuid="$(/usr/local/bin/xray uuid)"
  path="/$(rand_hex 8)/$(rand_hex 8)/"
  short_id="$(openssl rand -hex 8)"
  keys="$(generate_xray_reality_keys)"
  private="$(printf '%s\n' "${keys}" | sed -n '1p')"
  public="$(printf '%s\n' "${keys}" | sed -n '2p')"

  printf '%s\n' "${uuid}" >"${STACK_DIR}/vless-reality-uuid.txt"
  printf '%s\n' "${path}" >"${STACK_DIR}/vless-reality-path.txt"
  printf '%s\n' "${private}" >"${STACK_DIR}/vless-reality-private-key.txt"
  printf '%s\n' "${public}" >"${STACK_DIR}/vless-reality-public-key.txt"
  printf '%s\n' "${short_id}" >"${STACK_DIR}/vless-reality-short-id.txt"
  chmod 0600 "${STACK_DIR}"/vless-reality-*.txt

  jq -n \
    --arg uuid "${uuid}" \
    --arg path "${path}" \
    --arg private "${private}" \
    --arg sid "${short_id}" \
    '{
      log: {
        loglevel: "warning",
        access: "/var/log/vpn-stack/xray-access.log",
        error: "/var/log/vpn-stack/xray-error.log"
      },
      inbounds: [
        {
          tag: "vless-reality-xhttp",
          listen: "127.0.0.1",
          port: 10443,
          protocol: "vless",
          settings: {
            clients: [
              { id: $uuid, email: "main-reality" }
            ],
            decryption: "none"
          },
          streamSettings: {
            network: "xhttp",
            security: "reality",
            xhttpSettings: {
              path: $path,
              mode: "stream-one"
            },
            realitySettings: {
              show: false,
              target: "www.vk.com:443",
              xver: 0,
              serverNames: ["www.vk.com", "vk.com"],
              privateKey: $private,
              shortIds: [$sid]
            }
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"]
          }
        }
      ],
      outbounds: [
        { protocol: "freedom", tag: "direct" },
        { protocol: "blackhole", tag: "blocked" }
      ]
    }' >"${XRAY_DIR}/config.json"
  chmod 0600 "${XRAY_DIR}/config.json"

  cat >/etc/systemd/system/xray-vless-reality-xhttp.service <<EOF
[Unit]
Description=Xray VLESS REALITY XHTTP backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/xray-vless-reality-xhttp.service

  /usr/local/bin/xray run -test -config "${XRAY_DIR}/config.json"
  write_vless_link "${uuid}" "main-reality" >/dev/null
}

configure_nginx() {
  log "Configuring nginx stream router and local decoy HTTPS backend."
  install -d -m 0755 /var/www/decoy /etc/nginx/stream-conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled

  cat >/var/www/decoy/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Service status</title>
  <style>
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: Arial, sans-serif; color: #1f2937; background: #f8fafc; }
    main { width: min(560px, calc(100% - 40px)); }
    h1 { font-size: 28px; margin: 0 0 12px; }
    p { margin: 8px 0; line-height: 1.5; }
  </style>
</head>
<body>
  <main>
    <h1>Service status</h1>
    <p>This service is online.</p>
    <p>Maintenance and availability monitoring endpoint.</p>
  </main>
</body>
</html>
EOF
  chmod 0644 /var/www/decoy/index.html

  rm -f /etc/nginx/sites-enabled/default

  cat >/etc/nginx/sites-available/decoy-8444.conf <<EOF
server {
    listen 127.0.0.1:8444 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/decoy;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  chmod 0644 /etc/nginx/sites-available/decoy-8444.conf
  ln -sf /etc/nginx/sites-available/decoy-8444.conf /etc/nginx/sites-enabled/decoy-8444.conf

  cat >/etc/nginx/stream-conf.d/vpn-stack.conf <<'EOF'
stream {
    map $ssl_preread_server_name $vpn_backend {
        www.vk.com xray_reality;
        vk.com xray_reality;
        default decoy_https;
    }

    upstream xray_reality {
        server 127.0.0.1:10443;
    }

    upstream decoy_https {
        server 127.0.0.1:8444;
    }

    server {
        listen 443;
        proxy_pass $vpn_backend;
        ssl_preread on;
    }
}
EOF
  chmod 0644 /etc/nginx/stream-conf.d/vpn-stack.conf

  if ! grep -q 'stream-conf.d' /etc/nginx/nginx.conf; then
    local tmp
    tmp="$(mktemp)"
    awk '
      !inserted && $0 ~ /^http[[:space:]]*\{/ {
        print "include /etc/nginx/stream-conf.d/*.conf;";
        inserted=1
      }
      { print }
    ' /etc/nginx/nginx.conf >"${tmp}"
    install -m 0644 "${tmp}" /etc/nginx/nginx.conf
    rm -f "${tmp}"
  fi

  nginx -t
}

install_hysteria() {
  log "Installing Hysteria2."
  bash <(curl -fsSL https://get.hy2.sh/)
  local svc
  for svc in hysteria-server.service hysteria.service hysteria@server.service; do
    systemctl disable --now "${svc}" >/dev/null 2>&1 || true
  done
  need_command hysteria
}

hysteria_render_config() {
  local clients_json="${STACK_DIR}/hysteria-clients.json"
  local obfs
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"

  {
    printf 'listen: :8443\n'
    printf 'tls:\n'
    printf '  cert: %s/fullchain.pem\n' "${CERT_DIR}"
    printf '  key: %s/privkey.pem\n' "${CERT_DIR}"
    printf 'auth:\n'
    printf '  type: userpass\n'
    printf '  userpass:\n'
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "${clients_json}"
    printf 'obfs:\n'
    printf '  type: salamander\n'
    printf '  salamander:\n'
    printf '    password: %s\n' "${obfs}"
  } >"${HYSTERIA_DIR}/config.yaml"
  chmod 0600 "${HYSTERIA_DIR}/config.yaml"
}

write_hysteria_link() {
  local name="$1"
  local password="$2"
  local obfs domain tag link
  domain="$(<"${STACK_DIR}/domain.txt")"
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
  tag="$(uri_encode "Hysteria2-${name}")"
  link="hysteria2://${name}:${password}@${domain}:8443?obfs=salamander&obfs-password=${obfs}&sni=${domain}#${tag}"
  install -d -m 0700 "${KEY_DIR}/hysteria"
  printf '%s\n' "${link}" >"${KEY_DIR}/hysteria/${name}.txt"
  chmod 0600 "${KEY_DIR}/hysteria/${name}.txt"
  printf '%s\n' "${link}"
}

configure_hysteria() {
  log "Configuring Hysteria2 Salamander."
  install -d -m 0700 "${HYSTERIA_DIR}" "${KEY_DIR}/hysteria"
  local password obfs
  password="$(rand_hex 18)"
  obfs="$(rand_hex 24)"
  printf '%s\n' "${password}" >"${STACK_DIR}/hysteria-auth.txt"
  printf '%s\n' "${obfs}" >"${STACK_DIR}/hysteria-obfs.txt"
  jq -n --arg password "${password}" '{"main-hysteria-client": $password}' >"${STACK_DIR}/hysteria-clients.json"
  chmod 0600 "${STACK_DIR}/hysteria-auth.txt" "${STACK_DIR}/hysteria-obfs.txt" "${STACK_DIR}/hysteria-clients.json"

  hysteria_render_config
  write_hysteria_link "main-hysteria-client" "${password}" >/dev/null

  cat >/etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Salamander server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$(command -v hysteria) server -c ${HYSTERIA_DIR}/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/hysteria2.service
}

install_amneziawg() {
  log "Installing AmneziaWG."
  apt-get update
  apt-get install -y amneziawg || apt-get install -y amneziawg-dkms amneziawg-tools || die "Could not install AmneziaWG packages."

  if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
    warn "awg or awg-quick was not found after package install; building amneziawg-tools from source."
    apt-get install -y git make golang-go
    local build_dir
    build_dir="$(mktemp -d)"
    git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools "${build_dir}/amneziawg-tools"
    make -C "${build_dir}/amneziawg-tools/src"
    make -C "${build_dir}/amneziawg-tools/src" install
    rm -rf "${build_dir}"
  fi

  need_command awg
  need_command awg-quick
}

rand_u32() {
  local n
  while true; do
    n="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    if [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge 5 && "${n}" -le 4294967294 ]]; then
      printf '%s\n' "${n}"
      return
    fi
  done
}

rand_between() {
  local min="$1"
  local max="$2"
  local span n
  span=$((max - min + 1))
  while true; do
    n="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    if [[ "${n}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' $((min + (n % span)))
      return
    fi
  done
}

rand_range() {
  local min="$1"
  local max="$2"
  local width_min="$3"
  local width_max="$4"
  local start width end
  start="$(rand_between "${min}" "$((max - width_max))")"
  width="$(rand_between "${width_min}" "${width_max}")"
  end=$((start + width))
  printf '%s-%s\n' "${start}" "${end}"
}

awg_genpsk() {
  if awg genpsk >/dev/null 2>&1; then
    awg genpsk
  else
    openssl rand -base64 32
  fi
}

write_awg_client_config() {
  local name="$1"
  local client_private="$2"
  local client_ip="$3"
  local server_public="$4"
  local psk="$5"
  local out_file="${KEY_DIR}/awg/${name}.conf"

  # shellcheck disable=SC1091
  source "${STACK_DIR}/awg-params.env"
  install -d -m 0700 "${KEY_DIR}/awg"
  cat >"${out_file}" <<EOF
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
I1 = ${AWG_I1}
I2 = ${AWG_I2}
I3 = ${AWG_I3}
I4 = ${AWG_I4}
I5 = ${AWG_I5}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${DOMAIN}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 0600 "${out_file}"
  cat "${out_file}"
}

configure_amneziawg() {
  log "Configuring AmneziaWG 2.0."
  install -d -m 0700 /etc/amnezia/amneziawg "${KEY_DIR}/awg"

  cat >/etc/sysctl.d/98-vpn-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  chmod 0644 /etc/sysctl.d/98-vpn-forward.conf
  sysctl --system >/dev/null || true

  local server_private server_public client_private client_public psk
  server_private="$(awg genkey)"
  server_public="$(printf '%s\n' "${server_private}" | awg pubkey)"
  client_private="$(awg genkey)"
  client_public="$(printf '%s\n' "${client_private}" | awg pubkey)"
  psk="$(awg_genpsk)"

  local awg_profile jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5
  awg_profile="${AWG_OBFS_PROFILE:-dns}"
  case "${awg_profile}" in
    dns)
      jc="$(rand_between 5 8)"
      jmin="$(rand_between 48 96)"
      jmax="$(rand_between 420 760)"
      s1="$(rand_between 64 128)"
      s2="$(rand_between 48 96)"
      s3="$(rand_between 32 80)"
      s4="$(rand_between 64 128)"
      i1="<r 2><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010000026d000457fa27d1>"
      i2="<r 18><t><r 12>"
      i3="<r 24>"
      i4="<t><r 20>"
      i5="<rc 12><r 16>"
      ;;
    quic-lite)
      jc="$(rand_between 6 10)"
      jmin="$(rand_between 96 160)"
      jmax="$(rand_between 760 1180)"
      s1="$(rand_between 96 180)"
      s2="$(rand_between 64 128)"
      s3="$(rand_between 48 96)"
      s4="$(rand_between 96 180)"
      i1="<b 0xc300000001><r 8><t><r 80>"
      i2="<r 32><t><r 32>"
      i3="<r 96>"
      i4="<t><r 48>"
      i5="<r 64>"
      ;;
    *)
      die "Unsupported AWG_OBFS_PROFILE='${awg_profile}'. Use dns or quic-lite."
      ;;
  esac
  h1="$(rand_range 100000000 499999999 25000000 90000000)"
  h2="$(rand_range 600000000 999999999 25000000 90000000)"
  h3="$(rand_range 1100000000 1499999999 25000000 90000000)"
  h4="$(rand_range 1600000000 2100000000 25000000 90000000)"

  cat >"${STACK_DIR}/awg-params.env" <<EOF
AWG_OBFS_PROFILE=${awg_profile}
AWG_JC=${jc}
AWG_JMIN=${jmin}
AWG_JMAX=${jmax}
AWG_S1=${s1}
AWG_S2=${s2}
AWG_S3=${s3}
AWG_S4=${s4}
AWG_H1=${h1}
AWG_H2=${h2}
AWG_H3=${h3}
AWG_H4=${h4}
AWG_I1='${i1}'
AWG_I2='${i2}'
AWG_I3='${i3}'
AWG_I4='${i4}'
AWG_I5='${i5}'
EOF
  chmod 0600 "${STACK_DIR}/awg-params.env"
  printf '%s\n' "${server_public}" >"${STACK_DIR}/awg-server-public-key.txt"
  chmod 0600 "${STACK_DIR}/awg-server-public-key.txt"

  cat >/etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = ${server_private}
Jc = ${jc}
Jmin = ${jmin}
Jmax = ${jmax}
S1 = ${s1}
S2 = ${s2}
S3 = ${s3}
S4 = ${s4}
H1 = ${h1}
H2 = ${h2}
H3 = ${h3}
H4 = ${h4}
I1 = ${i1}
I2 = ${i2}
I3 = ${i3}
I4 = ${i4}
I5 = ${i5}
PostUp = iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o ${EXT_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT
PostUp = iptables -A FORWARD -o awg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o ${EXT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT
PostDown = iptables -D FORWARD -o awg0 -j ACCEPT

[Peer]
PublicKey = ${client_public}
PresharedKey = ${psk}
AllowedIPs = 10.66.66.2/32
EOF
  chmod 0600 /etc/amnezia/amneziawg/awg0.conf

  write_awg_client_config "main-awg" "${client_private}" "10.66.66.2" "${server_public}" "${psk}" >/dev/null

  cat >/usr/local/sbin/amneziawg-ensure-module.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! modprobe amneziawg 2>/dev/null; then
  dkms autoinstall || true
  modprobe amneziawg
fi
EOF
  chmod 0755 /usr/local/sbin/amneziawg-ensure-module.sh

  cat >/etc/systemd/system/amneziawg-ensure-module.service <<'EOF'
[Unit]
Description=Ensure AmneziaWG kernel module is available
DefaultDependencies=no
After=systemd-modules-load.service
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/amneziawg-ensure-module.sh

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/amneziawg-ensure-module.service

  if [[ ! -f /etc/systemd/system/awg-quick@.service && ! -f /lib/systemd/system/awg-quick@.service && ! -f /usr/lib/systemd/system/awg-quick@.service ]]; then
    cat >/etc/systemd/system/awg-quick@.service <<'EOF'
[Unit]
Description=AmneziaWG via awg-quick for %i
After=network-online.target amneziawg-ensure-module.service
Wants=network-online.target
Requires=amneziawg-ensure-module.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity
ExecStart=/bin/sh -c 'exec "$(command -v awg-quick)" up %i'
ExecStop=/bin/sh -c 'exec "$(command -v awg-quick)" down %i'

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/awg-quick@.service
  fi

  install -d -m 0755 /etc/systemd/system/awg-quick@awg0.service.d
  cat >/etc/systemd/system/awg-quick@awg0.service.d/override.conf <<'EOF'
[Unit]
Requires=amneziawg-ensure-module.service
After=network-online.target amneziawg-ensure-module.service
Wants=network-online.target
EOF
  chmod 0644 /etc/systemd/system/awg-quick@awg0.service.d/override.conf
}

configure_swap() {
  log "Configuring swap policy."
  if ! swapon --show | awk 'NR>1 {found=1} END {exit found ? 0 : 1}'; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    chmod 0600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    SWAP_RESULT="created /swapfile 2G"
  else
    SWAP_RESULT="existing swap left in place"
  fi

  cat >/etc/sysctl.d/99-vpn-swap.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
  chmod 0644 /etc/sysctl.d/99-vpn-swap.conf
  sysctl --system >/dev/null || true
}

configure_firewall() {
  log "Configuring UFW firewall."
  ufw allow 443/tcp
  ufw allow 8443/udp
  ufw allow 51820/udp
  if systemctl list-unit-files | grep -Eq '^(ssh|sshd)\.service'; then
    ufw allow OpenSSH || ufw allow 22/tcp || true
  fi
  ufw --force enable
}

install_helper_vless() {
  cat >/usr/local/bin/vpn-vless-reality <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/opt/vpn-stack/xray/config.json"
STACK_DIR="/opt/vpn-stack"
KEY_DIR="/root/vpn-keys/vless-reality"
SERVICE="xray-vless-reality-xhttp.service"

die() { echo "ERROR: $*" >&2; exit 1; }
uri_encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ $# -eq 1 ]] || die "Usage: vpn-vless-reality <name>"
name="$1"
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CONFIG}" ]] || die "Missing ${CONFIG}"

if jq -e --arg email "${name}" '.inbounds[] | select(.tag=="vless-reality-xhttp") | .settings.clients[]? | select(.email==$email)' "${CONFIG}" >/dev/null; then
  die "Client already exists: ${name}"
fi

uuid="$(/usr/local/bin/xray uuid)"
tmp="$(mktemp)"
backup="$(mktemp)"
cp "${CONFIG}" "${backup}"
jq --arg id "${uuid}" --arg email "${name}" \
  '(.inbounds[] | select(.tag=="vless-reality-xhttp") | .settings.clients) += [{id: $id, email: $email}]' \
  "${CONFIG}" >"${tmp}"
install -m 0600 "${tmp}" "${CONFIG}"
rm -f "${tmp}"

if ! /usr/local/bin/xray run -test -config "${CONFIG}"; then
  install -m 0600 "${backup}" "${CONFIG}"
  rm -f "${backup}"
  die "Xray config test failed; restored previous config."
fi
rm -f "${backup}"
systemctl restart "${SERVICE}"

domain="$(<"${STACK_DIR}/domain.txt")"
path="$(<"${STACK_DIR}/vless-reality-path.txt")"
public_key="$(<"${STACK_DIR}/vless-reality-public-key.txt")"
short_id="$(<"${STACK_DIR}/vless-reality-short-id.txt")"
encoded_path="$(uri_encode "${path}")"
fragment="$(uri_encode "VLESS-REALITY-XHTTP-${name}")"
link="vless://${uuid}@${domain}:443?security=reality&type=xhttp&encryption=none&path=${encoded_path}&mode=stream-one&sni=www.vk.com&fp=chrome&pbk=${public_key}&sid=${short_id}&spx=%2F#${fragment}"

install -d -m 0700 "${KEY_DIR}"
printf '%s\n' "${link}" >"${KEY_DIR}/${name}.txt"
chmod 0600 "${KEY_DIR}/${name}.txt"
printf '%s\n' "${link}"
EOF
  chmod 0755 /usr/local/bin/vpn-vless-reality
}

install_helper_hysteria() {
  cat >/usr/local/bin/vpn-hysteria <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="/opt/vpn-stack"
CONFIG="/opt/vpn-stack/hysteria/config.yaml"
CLIENTS="/opt/vpn-stack/hysteria-clients.json"
KEY_DIR="/root/vpn-keys/hysteria"
SERVICE="hysteria2.service"

die() { echo "ERROR: $*" >&2; exit 1; }
uri_encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
rand_hex() { openssl rand -hex "$1"; }

render_config() {
  local obfs
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
  {
    printf 'listen: :8443\n'
    printf 'tls:\n'
    printf '  cert: /etc/letsencrypt/live/%s/fullchain.pem\n' "$(<"${STACK_DIR}/domain.txt")"
    printf '  key: /etc/letsencrypt/live/%s/privkey.pem\n' "$(<"${STACK_DIR}/domain.txt")"
    printf 'auth:\n'
    printf '  type: userpass\n'
    printf '  userpass:\n'
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "${CLIENTS}"
    printf 'obfs:\n'
    printf '  type: salamander\n'
    printf '  salamander:\n'
    printf '    password: %s\n' "${obfs}"
  } >"${CONFIG}"
  chmod 0600 "${CONFIG}"
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ $# -eq 1 ]] || die "Usage: vpn-hysteria <name>"
name="$1"
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CLIENTS}" ]] || die "Missing ${CLIENTS}"

if jq -e --arg name "${name}" 'has($name)' "${CLIENTS}" >/dev/null; then
  die "Client already exists: ${name}"
fi

password="$(rand_hex 18)"
tmp="$(mktemp)"
jq --arg name "${name}" --arg password "${password}" '.[$name] = $password' "${CLIENTS}" >"${tmp}"
install -m 0600 "${tmp}" "${CLIENTS}"
rm -f "${tmp}"
render_config
systemctl restart "${SERVICE}"

domain="$(<"${STACK_DIR}/domain.txt")"
obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
tag="$(uri_encode "Hysteria2-${name}")"
link="hysteria2://${name}:${password}@${domain}:8443?obfs=salamander&obfs-password=${obfs}&sni=${domain}#${tag}"
install -d -m 0700 "${KEY_DIR}"
printf '%s\n' "${link}" >"${KEY_DIR}/${name}.txt"
chmod 0600 "${KEY_DIR}/${name}.txt"
printf '%s\n' "${link}"
EOF
  chmod 0755 /usr/local/bin/vpn-hysteria
}

install_helper_awg() {
  cat >/usr/local/bin/vpn-awg <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="/opt/vpn-stack"
CONFIG="/etc/amnezia/amneziawg/awg0.conf"
KEY_DIR="/root/vpn-keys/awg"

die() { echo "ERROR: $*" >&2; exit 1; }
awg_genpsk() {
  if awg genpsk >/dev/null 2>&1; then
    awg genpsk
  else
    openssl rand -base64 32
  fi
}

show_usage() {
  cat <<'USAGE'
Usage:
  vpn-awg <name>          Create a new AmneziaWG client
  vpn-awg analyze [sec]   Print AWG status; if sec > 0, also capture UDP/51820 for sec seconds
  vpn-awg capture [sec]   Save a tcpdump pcap for UDP/51820, default 20 seconds
USAGE
}

next_ip() {
  local i ip
  for i in $(seq 2 254); do
    ip="10.66.66.${i}"
    if ! grep -q "${ip}/32" "${CONFIG}"; then
      printf '%s\n' "${ip}"
      return 0
    fi
  done
  return 1
}

capture_awg_udp() {
  local seconds="${1:-20}"
  local iface out
  [[ "${seconds}" =~ ^[0-9]+$ && "${seconds}" -ge 1 && "${seconds}" -le 300 ]] || die "Capture duration must be 1..300 seconds."
  command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed."
  iface="$(cat "${STACK_DIR}/external-interface.txt" 2>/dev/null || true)"
  [[ -n "${iface}" ]] || iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "${iface}" ]] || die "Could not determine external interface."
  install -d -m 0700 /var/log/vpn-stack/awg-captures
  out="/var/log/vpn-stack/awg-captures/awg-udp-51820-$(date +%Y%m%d-%H%M%S).pcap"
  echo "Capturing UDP/51820 on ${iface} for ${seconds}s -> ${out}"
  echo "The pcap contains encrypted UDP metadata; keep it private."
  timeout "${seconds}" tcpdump -ni "${iface}" -s 192 -w "${out}" udp port 51820 || true
  chmod 0600 "${out}" 2>/dev/null || true
  echo "Saved: ${out}"
  echo "Packet size summary:"
  tcpdump -nn -tt -r "${out}" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "length") {
          n = $(i + 1)
          gsub(/[^0-9]/, "", n)
          if (n != "") {
            n += 0
            count++
            if (min == "" || n < min) min = n
            if (n > max) max = n
            bucket[int(n / 100) * 100]++
          }
        }
      }
    }
    END {
      if (!count) {
        print "  no packets captured"
        exit
      }
      printf "  packets=%d min=%d max=%d\n", count, min, max
      for (b in bucket) printf "  size %d-%d: %d\n", b, b + 99, bucket[b]
    }
  ' | sort -n -k2 2>/dev/null || true
}

analyze_awg() {
  local seconds="${1:-0}"
  local iface
  iface="$(cat "${STACK_DIR}/external-interface.txt" 2>/dev/null || true)"
  echo "AmneziaWG diagnostics"
  echo
  echo "Services:"
  systemctl is-active awg-quick@awg0.service 2>/dev/null | sed 's/^/  awg-quick@awg0 active: /' || true
  systemctl is-enabled awg-quick@awg0.service 2>/dev/null | sed 's/^/  awg-quick@awg0 enabled: /' || true
  systemctl is-active amneziawg-ensure-module.service 2>/dev/null | sed 's/^/  amneziawg-ensure-module active: /' || true
  echo
  echo "Kernel/module:"
  lsmod | awk '$1 ~ /^(amneziawg|wireguard)$/ {print "  " $0}' || true
  echo
  echo "Listening socket:"
  ss -lunp | awk '$5 ~ /:51820$/ {print "  " $0}' || true
  echo
  echo "Routing/sysctl:"
  printf '  net.ipv4.ip_forward = '; sysctl -n net.ipv4.ip_forward 2>/dev/null || true
  printf '  external interface = '; printf '%s\n' "${iface:-unknown}"
  echo
  echo "Firewall:"
  ufw status 2>/dev/null | sed 's/^/  /' || true
  iptables -t nat -S POSTROUTING 2>/dev/null | grep '10.66.66.0/24' | sed 's/^/  /' || true
  echo
  echo "AWG interface:"
  awg show awg0 2>/dev/null | sed 's/^/  /' || true
  echo
  echo "AWG obfuscation profile:"
  if [[ -f "${STACK_DIR}/awg-params.env" ]]; then
    grep -E '^AWG_(OBFS_PROFILE|JC|JMIN|JMAX|S[1-4]|H[1-4]|I[1-5])=' "${STACK_DIR}/awg-params.env" | sed 's/^/  /'
  else
    echo "  missing ${STACK_DIR}/awg-params.env"
  fi
  if [[ "${seconds}" =~ ^[0-9]+$ && "${seconds}" -gt 0 ]]; then
    echo
    capture_awg_udp "${seconds}"
  fi
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ $# -ge 1 ]] || { show_usage; exit 1; }
case "${1}" in
  -h|--help|help)
    show_usage
    exit 0
    ;;
  analyze|diagnose|diag)
    analyze_awg "${2:-0}"
    exit 0
    ;;
  capture|tcpdump)
    capture_awg_udp "${2:-20}"
    exit 0
    ;;
esac
[[ $# -eq 1 ]] || die "Usage: vpn-awg <name>"
name="$1"
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CONFIG}" ]] || die "Missing ${CONFIG}"
[[ -f "${STACK_DIR}/awg-params.env" ]] || die "Missing ${STACK_DIR}/awg-params.env"
if [[ -f "${KEY_DIR}/${name}.conf" ]]; then
  die "Client config already exists: ${KEY_DIR}/${name}.conf"
fi

# shellcheck disable=SC1091
source "${STACK_DIR}/awg-params.env"
domain="$(<"${STACK_DIR}/domain.txt")"
server_public="$(<"${STACK_DIR}/awg-server-public-key.txt")"
client_ip="$(next_ip)" || die "No free IP left in 10.66.66.0/24."
client_private="$(awg genkey)"
client_public="$(printf '%s\n' "${client_private}" | awg pubkey)"
psk="$(awg_genpsk)"

cat >>"${CONFIG}" <<EOF_PEER

[Peer]
PublicKey = ${client_public}
PresharedKey = ${psk}
AllowedIPs = ${client_ip}/32
EOF_PEER
chmod 0600 "${CONFIG}"

if awg show awg0 >/dev/null 2>&1; then
  psk_file="$(mktemp)"
  chmod 0600 "${psk_file}"
  printf '%s\n' "${psk}" >"${psk_file}"
  awg set awg0 peer "${client_public}" preshared-key "${psk_file}" allowed-ips "${client_ip}/32"
  rm -f "${psk_file}"
else
  systemctl restart awg-quick@awg0.service
fi

install -d -m 0700 "${KEY_DIR}"
out="${KEY_DIR}/${name}.conf"
cat >"${out}" <<EOF_CLIENT
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
I1 = ${AWG_I1}
I2 = ${AWG_I2}
I3 = ${AWG_I3}
I4 = ${AWG_I4}
I5 = ${AWG_I5}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${domain}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF_CLIENT
chmod 0600 "${out}"
cat "${out}"
EOF
  chmod 0755 /usr/local/bin/vpn-awg
}

install_helper_help() {
  cat >/usr/local/bin/vpn-help <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

show_key_if_exists() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    echo "No saved key yet: ${file}"
  fi
}

proto="${1:-}"
name="${2:-}"

case "${proto}" in
  reality|xhttp|vless)
    [[ -n "${name}" ]] && show_key_if_exists "/root/vpn-keys/vless-reality/${name}.txt" && exit 0
    echo "Create: vpn-vless-reality <name>"
    exit 0
    ;;
  hysteria)
    [[ -n "${name}" ]] && show_key_if_exists "/root/vpn-keys/hysteria/${name}.txt" && exit 0
    echo "Create: vpn-hysteria <name>"
    exit 0
    ;;
  awg)
    [[ -n "${name}" ]] && show_key_if_exists "/root/vpn-keys/awg/${name}.conf" && exit 0
    echo "Create: vpn-awg <name>"
    exit 0
    ;;
esac

cat <<'HELP'
Golden VPN helper commands

Create clients:
  vpn-vless-reality phone1
  vpn-hysteria phone1
  vpn-awg phone1

AmneziaWG diagnostics:
  vpn-awg analyze
  vpn-awg analyze 20
  vpn-awg capture 30

Saved keys:
  /root/vpn-keys/vless-reality/<name>.txt
  /root/vpn-keys/hysteria/<name>.txt
  /root/vpn-keys/awg/<name>.conf

Show saved client material:
  vpn-help reality phone1
  vpn-help xhttp phone1
  vpn-help vless phone1
  vpn-help hysteria phone1
  vpn-help awg phone1

Check services:
  systemctl status nginx --no-pager
  systemctl status xray-vless-reality-xhttp --no-pager
  systemctl status hysteria2 --no-pager
  systemctl status awg-quick@awg0 --no-pager -l
  systemctl status prometheus --no-pager
  systemctl status prometheus-node-exporter --no-pager
  systemctl status grafana-server --no-pager

Grafana SSH tunnel:
  ssh -L 3000:127.0.0.1:3000 root@SERVER_IP
  Open http://localhost:3000
  Default login: admin / admin

Dashboard:
  Node Exporter Full dashboard ID 1860 is provisioned when download succeeds.
  Manual import path: Grafana -> Dashboards -> New -> Import -> 1860 -> datasource Prometheus
HELP
EOF
  chmod 0755 /usr/local/bin/vpn-help
}

install_helpers() {
  log "Installing helper commands."
  rm -f /usr/local/bin/vpn /usr/local/bin/vpn-trojan /usr/local/bin/vpn-vless-xhttp
  install_helper_vless
  install_helper_hysteria
  install_helper_awg
  install_helper_help
}

configure_monitoring() {
  log "Configuring Prometheus, Node Exporter, and Grafana localhost-only monitoring."

  cat >/etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090
  - job_name: node
    static_configs:
      - targets:
          - 127.0.0.1:9100
EOF
  chmod 0644 /etc/prometheus/prometheus.yml

  install -d -m 0755 /etc/systemd/system/prometheus.service.d
  cat >/etc/systemd/system/prometheus.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/metrics2 --web.console.templates=/usr/share/prometheus/consoles --web.console.libraries=/usr/share/prometheus/console_libraries --web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=7d --storage.tsdb.retention.size=1GB
EOF
  chmod 0644 /etc/systemd/system/prometheus.service.d/override.conf

  install -d -m 0755 /etc/systemd/system/prometheus-node-exporter.service.d
  cat >/etc/systemd/system/prometheus-node-exporter.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=127.0.0.1:9100
EOF
  chmod 0644 /etc/systemd/system/prometheus-node-exporter.service.d/override.conf

  if [[ -f /etc/grafana/grafana.ini ]]; then
    sed -i -E 's/^[;[:space:]]*http_addr[[:space:]]*=.*/http_addr = 127.0.0.1/' /etc/grafana/grafana.ini
    sed -i -E 's/^[;[:space:]]*http_port[[:space:]]*=.*/http_port = 3000/' /etc/grafana/grafana.ini
  fi

  install -d -m 0755 /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
  cat >/etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: true
EOF
  chmod 0644 /etc/grafana/provisioning/datasources/prometheus.yaml

  cat >/etc/grafana/provisioning/dashboards/node-exporter-full.yaml <<'EOF'
apiVersion: 1

providers:
  - name: Node Exporter Full
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 60
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF
  chmod 0644 /etc/grafana/provisioning/dashboards/node-exporter-full.yaml

  if curl -fsSL https://grafana.com/api/dashboards/1860/revisions/latest/download \
    -o /var/lib/grafana/dashboards/node-exporter-full-1860.json; then
    chmod 0644 /var/lib/grafana/dashboards/node-exporter-full-1860.json
    chown -R grafana:grafana /var/lib/grafana/dashboards || true
  else
    warn "Could not download Grafana dashboard 1860; vpn-help includes manual import instructions."
  fi
}

configure_log_limits() {
  log "Configuring log retention limits."
  install -d -m 0755 /etc/systemd/journald.conf.d "${LOG_DIR}"
  cat >/etc/systemd/journald.conf.d/limits.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF
  chmod 0644 /etc/systemd/journald.conf.d/limits.conf

  cat >/etc/logrotate.d/vpn-stack <<'EOF'
/var/log/vpn-stack/*.log /var/log/vpn-soft-reboot.log /var/log/vpn-stack-healthcheck.log {
    daily
    rotate 7
    compress
    copytruncate
    missingok
    notifempty
}
EOF
  chmod 0644 /etc/logrotate.d/vpn-stack
}

configure_timers() {
  log "Configuring soft reboot and boot healthcheck timers."

  cat >/usr/local/sbin/vpn-soft-reboot.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s soft reboot requested\n' "$(date -Is)" >>/var/log/vpn-soft-reboot.log
systemctl reboot
EOF
  chmod 0755 /usr/local/sbin/vpn-soft-reboot.sh

  cat >/etc/systemd/system/vpn-soft-reboot.service <<'EOF'
[Unit]
Description=Daily soft reboot for VPN stack

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-soft-reboot.sh
EOF
  chmod 0644 /etc/systemd/system/vpn-soft-reboot.service

  cat >/etc/systemd/system/vpn-soft-reboot.timer <<'EOF'
[Unit]
Description=Run VPN soft reboot daily at 04:00 Europe/Moscow

[Timer]
OnCalendar=*-*-* 04:00:00 Europe/Moscow
Persistent=false
Unit=vpn-soft-reboot.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-soft-reboot.timer

  cat >/usr/local/sbin/vpn-stack-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file="/var/log/vpn-stack-healthcheck.log"
services=(
  nginx
  xray-vless-reality-xhttp
  hysteria2
  prometheus
  prometheus-node-exporter
  grafana-server
  amneziawg-ensure-module
  awg-quick@awg0
)

printf '%s healthcheck start\n' "$(date -Is)" >>"${log_file}"
for svc in "${services[@]}"; do
  if ! systemctl is-active --quiet "${svc}"; then
    printf '%s restarting %s\n' "$(date -Is)" "${svc}" >>"${log_file}"
    systemctl restart "${svc}" >>"${log_file}" 2>&1 || true
  fi
done
printf '%s healthcheck done\n' "$(date -Is)" >>"${log_file}"
EOF
  chmod 0755 /usr/local/sbin/vpn-stack-healthcheck.sh

  cat >/etc/systemd/system/vpn-stack-healthcheck.service <<'EOF'
[Unit]
Description=VPN stack boot healthcheck
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-stack-healthcheck.sh
EOF
  chmod 0644 /etc/systemd/system/vpn-stack-healthcheck.service

  cat >/etc/systemd/system/vpn-stack-healthcheck.timer <<'EOF'
[Unit]
Description=Run VPN stack healthcheck after boot

[Timer]
OnBootSec=2min
Persistent=false
Unit=vpn-stack-healthcheck.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-stack-healthcheck.timer
}

enable_and_start_services() {
  log "Enabling and starting services."
  systemctl daemon-reload

  systemctl enable nginx
  systemctl enable xray-vless-reality-xhttp
  systemctl enable hysteria2
  systemctl enable amneziawg-ensure-module
  systemctl enable awg-quick@awg0
  systemctl enable prometheus
  systemctl enable prometheus-node-exporter
  systemctl enable grafana-server
  systemctl enable vpn-soft-reboot.timer
  systemctl enable vpn-stack-healthcheck.timer

  systemctl restart systemd-journald || true
  systemctl restart xray-vless-reality-xhttp
  systemctl restart nginx
  systemctl restart hysteria2
  systemctl restart amneziawg-ensure-module
  systemctl restart awg-quick@awg0
  systemctl restart prometheus
  systemctl restart prometheus-node-exporter
  systemctl restart grafana-server
  systemctl restart vpn-soft-reboot.timer
  systemctl restart vpn-stack-healthcheck.timer
}

service_summary() {
  local unit="$1"
  local active enabled
  active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
  [[ -n "${active}" ]] || active="unknown"
  [[ -n "${enabled}" ]] || enabled="unknown"
  printf '%s/%s' "${active}" "${enabled}"
}

listen_any_port() {
  local proto="$1"
  local port="$2"
  ss -H -lntup 2>/dev/null | awk -v proto="${proto}" -v port=":${port}" \
    'tolower($1) == proto && $5 ~ (port "$") { found=1 } END { exit found ? 0 : 1 }'
}

listen_local_port() {
  local proto="$1"
  local port="$2"
  ss -H -lntup 2>/dev/null | awk -v proto="${proto}" -v port=":${port}" '
    tolower($1) == proto && ($5 == "127.0.0.1" port || $5 == "[::1]" port) { found=1 }
    END { exit found ? 0 : 1 }
  '
}

listen_label() {
  local scope="$1"
  local proto="$2"
  local port="$3"
  if [[ "${scope}" == "local" ]]; then
    if listen_local_port "${proto}" "${port}"; then
      printf 'OK'
    else
      printf 'MISSING'
    fi
  else
    if listen_any_port "${proto}" "${port}"; then
      printf 'OK'
    else
      printf 'MISSING'
    fi
  fi
}

print_install_summary() {
  local dashboard_status
  if [[ -s /var/lib/grafana/dashboards/node-exporter-full-1860.json ]]; then
    dashboard_status="provisioned from local JSON"
  else
    dashboard_status="not provisioned; import dashboard ID 1860 manually"
  fi

  cat <<EOF

============================================================
Golden VPN stack summary
============================================================
Domain: ${DOMAIN}
Server IPv4: ${PUBLIC_IPV4}
External interface: ${EXT_IFACE}

Contours:
  VLESS REALITY XHTTP : service $(service_summary xray-vless-reality-xhttp); external 443/tcp $(listen_label any tcp 443); backend 127.0.0.1:10443 $(listen_label local tcp 10443)
  Hysteria2 Salamander: service $(service_summary hysteria2); external 8443/udp $(listen_label any udp 8443)
  AmneziaWG 2.0       : service $(service_summary awg-quick@awg0); external 51820/udp $(listen_label any udp 51820); interface awg0
  Decoy HTTPS site    : nginx $(service_summary nginx); https://${DOMAIN}/; backend 127.0.0.1:8444 $(listen_label local tcp 8444)

Monitoring, localhost only:
  Grafana       : service $(service_summary grafana-server); 127.0.0.1:3000 $(listen_label local tcp 3000)
  Prometheus    : service $(service_summary prometheus); 127.0.0.1:9090 $(listen_label local tcp 9090)
  Node Exporter : service $(service_summary prometheus-node-exporter); 127.0.0.1:9100 $(listen_label local tcp 9100)
  Dashboard 1860: ${dashboard_status}

Grafana SSH tunnel:
  ssh -L 3000:127.0.0.1:3000 root@${PUBLIC_IPV4}
  Open: http://localhost:3000
  Default login: admin / admin

AmneziaWG diagnostics:
  Obfuscation profile: $(grep -E '^AWG_OBFS_PROFILE=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')
  Full status: vpn-awg analyze
  Status + short sniff: vpn-awg analyze 20
  Save pcap: vpn-awg capture 30

Swap:
  Install decision: ${SWAP_RESULT}
EOF

  if swapon --show | awk 'NR>1 {found=1} END {exit found ? 0 : 1}'; then
    swapon --show
  else
    printf '  Active swap: none\n'
  fi

  cat <<EOF

Storage limits:
  journald: /etc/systemd/journald.conf.d/limits.conf
  logrotate: /etc/logrotate.d/vpn-stack
  Prometheus retention: 7d / 1GB

Initial client files:
  ${KEY_DIR}/vless-reality/main-reality.txt
  ${KEY_DIR}/hysteria/main-hysteria-client.txt
  ${KEY_DIR}/awg/main-awg.conf

Create more clients:
  vpn-vless-reality phone1
  vpn-hysteria phone1
  vpn-awg phone1
  vpn-help
============================================================
EOF
}

final_checks() {
  log "Final listening socket check."
  set +e
  ss -lntup | grep -E ':443|:8443|:51820|:3000|:9090|:9100|:10443|:8444'

  systemctl status nginx --no-pager
  systemctl status xray-vless-reality-xhttp --no-pager
  systemctl status hysteria2 --no-pager
  systemctl status awg-quick@awg0 --no-pager -l
  systemctl status prometheus --no-pager
  systemctl status prometheus-node-exporter --no-pager
  systemctl status grafana-server --no-pager

  curl -vk "https://${DOMAIN}/"
  vpn-help
  set -e

  log "Initial client files:"
  printf '  %s\n' \
    "${KEY_DIR}/vless-reality/main-reality.txt" \
    "${KEY_DIR}/hysteria/main-hysteria-client.txt" \
    "${KEY_DIR}/awg/main-awg.conf"
  log "Optional helper smoke tests create extra clients:"
  printf '  vpn-vless-reality test-reality\n  vpn-hysteria test-hy2\n  vpn-awg test-awg\n'
  print_install_summary
}

main() {
  require_root_and_env
  install_apt_repositories
  install_base_packages
  need_command ip
  need_command getent
  need_command curl
  need_command jq
  need_command openssl
  detect_public_ipv4
  detect_external_iface
  verify_domain_dns
  install_acme_certificate
  install_xray
  configure_xray
  configure_nginx
  install_hysteria
  configure_hysteria
  install_amneziawg
  configure_amneziawg
  configure_swap
  configure_firewall
  install_helpers
  configure_monitoring
  configure_log_limits
  configure_timers
  enable_and_start_services
  final_checks
  log "Golden VPN stack installation complete."
}

main "$@"
