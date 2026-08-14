#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

export GOLDEN_VPN_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${installer}"

STACK_DIR="${tmp_dir}/opt/vpn-stack"
KEY_DIR="${tmp_dir}/root/vpn-keys"
XRAY_DIR="${STACK_DIR}/xray"
HYSTERIA_DIR="${STACK_DIR}/hysteria"
SUBSCRIPTION_DIR="${STACK_DIR}/subscriptions"
SUBSCRIPTION_WEB_DIR="${tmp_dir}/var/www/subscriptions"
AWG_CONFIG="${tmp_dir}/etc/amnezia/amneziawg/awg0.conf"
UPGRADE_BACKUP_ROOT="${KEY_DIR}/upgrade-backups"
VLESS_TROJAN_MIGRATION_ROOT="${tmp_dir}/root/vpn-migration/vless-to-trojan"
VLESS_TROJAN_MIGRATION_REPORT="${KEY_DIR}/vless-to-trojan-report.json"
TROJAN_XHTTP_SOCKET="${tmp_dir}/run/xray-trojan-xhttp.sock"
TROJAN_HELPER_PATH="${tmp_dir}/usr/local/bin/vpn-trojan"
VLESS_MIGRATION_NGINX_SITE="${tmp_dir}/etc/nginx/sites-enabled/decoy-443.conf"
VLESS_XRAY_SERVICE="xray-vless-xhttp-tls.service"
XRAY_BIN="${tmp_dir}/bin/xray"
export STACK_DIR KEY_DIR XRAY_DIR HYSTERIA_DIR SUBSCRIPTION_DIR SUBSCRIPTION_WEB_DIR AWG_CONFIG
export UPGRADE_BACKUP_ROOT VLESS_TROJAN_MIGRATION_ROOT VLESS_TROJAN_MIGRATION_REPORT
export TROJAN_XHTTP_SOCKET VLESS_MIGRATION_NGINX_SITE VLESS_XRAY_SERVICE XRAY_BIN
export TROJAN_HELPER_PATH
export SERVER_LOCATION=FR

mkdir -p \
  "${XRAY_DIR}" "${HYSTERIA_DIR}" "$(dirname "${AWG_CONFIG}")" \
  "${KEY_DIR}/vless-xhttp" "${KEY_DIR}/hysteria" "${KEY_DIR}/awg" \
  "${SUBSCRIPTION_DIR}" "${SUBSCRIPTION_WEB_DIR}" \
  "$(dirname "${VLESS_MIGRATION_NGINX_SITE}")" "${tmp_dir}/bin" "$(dirname "${TROJAN_XHTTP_SOCKET}")"

cat >"${XRAY_DIR}/config.json" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "vless-xhttp-tls",
      "listen": "${tmp_dir}/run/xray-vless.sock,0666",
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "legacy-id-one", "email": "alpha"},
          {"id": "legacy-id-two", "email": "beta"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "/legacy/secret/", "mode": "stream-one"}
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
JSON
chmod 0600 "${XRAY_DIR}/config.json"
printf 'example.test\n' >"${STACK_DIR}/domain.txt"
printf '{"alpha":"hy-secret"}\n' >"${STACK_DIR}/hysteria-clients.json"
printf 'hysteria config\n' >"${HYSTERIA_DIR}/config.yaml"
printf 'hysteria client\n' >"${KEY_DIR}/hysteria/alpha.txt"
cat >"${AWG_CONFIG}" <<'CONF'
[Interface]
PrivateKey = awg-server-private

[Peer]
PublicKey = awg-alpha-public
AllowedIPs = 10.66.66.2/32
CONF
printf 'awg client\n' >"${KEY_DIR}/awg/alpha.conf"
printf 'legacy vless link\n' >"${KEY_DIR}/vless-xhttp/alpha.txt"

cat >"${VLESS_MIGRATION_NGINX_SITE}" <<'NGINX'
server {
    listen 443 ssl http2;
    server_name example.test;

    location ^~ /legacy/secret/ {
        grpc_pass unix:/tmp/xray-vless.sock;
    }

    location / {
        try_files $uri /404.html;
    }
}
NGINX

cat >"${XRAY_BIN}" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
config="${@: -1}"
jq -e '.inbounds | type == "array" and length > 0' "${config}" >/dev/null
SH
chmod 0755 "${XRAY_BIN}"

cat >"${tmp_dir}/bin/nginx" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "-t" && "${FAIL_NGINX_TEST:-0}" == "1" ]]; then
  exit 1
fi
exit 0
SH
chmod 0755 "${tmp_dir}/bin/nginx"

cat >"${tmp_dir}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  cat|is-active|reload)
    exit 0
    ;;
  restart)
    while IFS= read -r socket_path; do
      [[ -n "${socket_path}" ]] || continue
      rm -f "${socket_path}"
      python3 - "${socket_path}" <<'PY'
import pathlib
import socket
import sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
s = socket.socket(socket.AF_UNIX)
s.bind(str(path))
s.close()
PY
    done < <(jq -r '.inbounds[]?.listen // empty | split(",")[0]' "${XRAY_DIR}/config.json")
    exit 0
    ;;
esac
exit 0
SH
chmod 0755 "${tmp_dir}/bin/systemctl"
export PATH="${tmp_dir}/bin:${PATH}"

cp "${XRAY_DIR}/config.json" "${tmp_dir}/xray.original.json"
cp "${VLESS_MIGRATION_NGINX_SITE}" "${tmp_dir}/nginx.original.conf"
cp "${AWG_CONFIG}" "${tmp_dir}/awg.original.conf"
cp "${STACK_DIR}/hysteria-clients.json" "${tmp_dir}/hysteria.original.json"

bundle="$(prepare_vless_to_trojan_migration | tail -1)"
[[ -d "${bundle}" ]]
cmp -s "${XRAY_DIR}/config.json" "${tmp_dir}/xray.original.json"
cmp -s "${VLESS_MIGRATION_NGINX_SITE}" "${tmp_dir}/nginx.original.conf"
(
  cd "${bundle}"
  sha256sum -c bundle.sha256 >/dev/null
)
[[ "$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "${bundle}/xray.candidate.json")" == "1" ]]
[[ "$(jq '[.inbounds[] | select(.protocol == "trojan")][0].settings.clients | length' "${bundle}/xray.candidate.json")" == "2" ]]
jq -S '[.inbounds[] | select(.protocol == "vless")]' "${tmp_dir}/xray.original.json" >"${tmp_dir}/vless.before.json"
jq -S '[.inbounds[] | select(.protocol == "vless")]' "${bundle}/xray.candidate.json" >"${tmp_dir}/vless.candidate.json"
cmp -s "${tmp_dir}/vless.before.json" "${tmp_dir}/vless.candidate.json"
grep -Fq 'GOLDEN PARALLEL TROJAN BEGIN' "${bundle}/nginx.candidate.conf"
grep -Fq 'location ^~ /legacy/secret/' "${bundle}/nginx.candidate.conf"
[[ "$(find "${bundle}/links" -type f -name '*.txt' | wc -l)" == "2" ]]

if (apply_vless_to_trojan_migration "${bundle}" >/dev/null 2>&1); then
  printf 'migration apply accepted a missing confirmation flag\n' >&2
  exit 1
fi

# Force nginx validation to fail after candidate files are installed. The
# transaction must restore both live files to their exact VLESS preimage.
export FAIL_NGINX_TEST=1
if (apply_vless_to_trojan_migration "${bundle}" --confirm-parallel-trojan >/dev/null 2>&1); then
  printf 'migration apply unexpectedly succeeded during forced nginx failure\n' >&2
  exit 1
fi
unset FAIL_NGINX_TEST
cmp -s "${XRAY_DIR}/config.json" "${tmp_dir}/xray.original.json"
cmp -s "${VLESS_MIGRATION_NGINX_SITE}" "${tmp_dir}/nginx.original.conf"

# Force the final helper installation to fail after both services accepted the
# candidate. Generated client artifacts must be removed and VLESS restored.
declare -f install_helper_trojan >"${tmp_dir}/install-helper-trojan.function"
install_helper_trojan() { return 1; }
if (apply_vless_to_trojan_migration "${bundle}" --confirm-parallel-trojan >/dev/null 2>&1); then
  printf 'migration apply unexpectedly succeeded during forced artifact failure\n' >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${tmp_dir}/install-helper-trojan.function"
cmp -s "${XRAY_DIR}/config.json" "${tmp_dir}/xray.original.json"
cmp -s "${VLESS_MIGRATION_NGINX_SITE}" "${tmp_dir}/nginx.original.conf"
[[ ! -e "${STACK_DIR}/trojan-xhttp-path.txt" ]]
[[ ! -e "${TROJAN_HELPER_PATH}" ]]
[[ ! -d "${KEY_DIR}/trojan" ]]

apply_vless_to_trojan_migration "${bundle}" --confirm-parallel-trojan
[[ "$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "${XRAY_DIR}/config.json")" == "1" ]]
[[ "$(jq '[.inbounds[] | select(.protocol == "trojan")] | length' "${XRAY_DIR}/config.json")" == "1" ]]
[[ "$(jq '[.inbounds[] | select(.protocol == "trojan")][0].settings.clients | length' "${XRAY_DIR}/config.json")" == "2" ]]
jq -S '[.inbounds[] | select(.protocol == "vless")]' "${XRAY_DIR}/config.json" >"${tmp_dir}/vless.after.json"
cmp -s "${tmp_dir}/vless.before.json" "${tmp_dir}/vless.after.json"
cmp -s "${AWG_CONFIG}" "${tmp_dir}/awg.original.conf"
cmp -s "${STACK_DIR}/hysteria-clients.json" "${tmp_dir}/hysteria.original.json"
grep -Fq 'GOLDEN PARALLEL TROJAN BEGIN' "${VLESS_MIGRATION_NGINX_SITE}"
[[ -S "${TROJAN_XHTTP_SOCKET}" ]]
[[ "$(find "${KEY_DIR}/trojan" -type f -name '*.txt' | wc -l)" == "2" ]]
[[ -x "${TROJAN_HELPER_PATH}" ]]
jq -e '.legacy_vless_preserved == true and .trojan_clients_created == 2' "${VLESS_TROJAN_MIGRATION_REPORT}" >/dev/null

printf 'vless to trojan migration tests passed\n'
