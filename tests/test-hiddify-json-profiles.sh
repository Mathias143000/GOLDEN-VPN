#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

export GOLDEN_VPN_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${installer}"

HIDDIFY_PROFILE_HELPER_PATH="${tmp_dir}/vpn-hiddify-profile"
install_helper_hiddify_profile

mkdir -p "${tmp_dir}/raw/trojan" "${tmp_dir}/raw/hysteria" "${tmp_dir}/wrapped"
printf '%s\n' \
  'trojan://trojan-secret@example.test:443?security=tls&type=xhttp&path=%2Fprivate%2Fpath&mode=auto&sni=example.test&host=example.test&alpn=h2#TROJAN-US-user' \
  >"${tmp_dir}/raw/trojan/TROJAN-US-user.txt"
printf '%s\n' \
  'hysteria2://user:hy-secret@example.test:8443,20000-50000/?obfs=salamander&obfs-password=obfs-secret&sni=example.test#HYSTERIA-US-user' \
  >"${tmp_dir}/raw/hysteria/HYSTERIA-US-user.txt"
printf '%s\n' \
  'hysteria2://user:hy-secret@example.test:8443/?obfs=gecko&obfs-password=obfs-secret&sni=example.test#HYSTERIA-US-gecko' \
  >"${tmp_dir}/raw/hysteria/HYSTERIA-US-gecko.txt"

"${HIDDIFY_PROFILE_HELPER_PATH}" wrap "${tmp_dir}/raw/trojan/TROJAN-US-user.txt" \
  --output-dir "${tmp_dir}/wrapped" >/dev/null
"${HIDDIFY_PROFILE_HELPER_PATH}" wrap "${tmp_dir}/raw/hysteria/HYSTERIA-US-user.txt" \
  --output-dir "${tmp_dir}/wrapped" >/dev/null

jq -e '
  .outbounds[0].type == "trojan" and
  .outbounds[0].password == "trojan-secret" and
  .outbounds[0].tls.enabled == true and
  .outbounds[0].tls.insecure == false and
  .outbounds[0].transport.type == "xhttp" and
  .outbounds[0].transport.path == "/private/path" and
  .outbounds[0].transport.mode == "stream-one" and
  .dns.servers[0].type == "https" and
  .dns.servers[0].detour == "proxy" and
  .dns.final == "dns-remote" and
  .route.final == "proxy" and
  any(.route.rules[]; .protocol == "dns" and .action == "hijack-dns")
' "${tmp_dir}/wrapped/TROJAN-US-user.json" >/dev/null

jq -e '
  .outbounds[0].type == "hysteria2" and
  .outbounds[0].password == "user:hy-secret" and
  .outbounds[0].server_ports == ["8443:8443", "20000:50000"] and
  .outbounds[0].obfs.type == "salamander" and
  .outbounds[0].obfs.password == "obfs-secret" and
  .dns.servers[0].detour == "proxy"
' "${tmp_dir}/wrapped/HYSTERIA-US-user.json" >/dev/null

"${HIDDIFY_PROFILE_HELPER_PATH}" bundle \
  "${tmp_dir}/raw/trojan/TROJAN-US-user.txt" \
  "${tmp_dir}/raw/hysteria/HYSTERIA-US-user.txt" \
  --output "${tmp_dir}/hiddify.json" >/dev/null
jq -e '
  .outbounds[0].type == "selector" and
  .outbounds[0].tag == "proxy" and
  .outbounds[0].default == "hysteria2" and
  .outbounds[0].outbounds == ["hysteria2", "trojan"] and
  any(.outbounds[]; .tag == "hysteria2") and
  any(.outbounds[]; .tag == "trojan") and
  .route.final == "proxy"
' "${tmp_dir}/hiddify.json" >/dev/null

if [[ -n "${HIDDIFY_CHECK_BIN:-}" ]]; then
  for config in "${tmp_dir}/wrapped/TROJAN-US-user.json" \
    "${tmp_dir}/wrapped/HYSTERIA-US-user.json" "${tmp_dir}/hiddify.json"; do
    check_path="${config}"
    if [[ "${HIDDIFY_CHECK_BIN}" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
      check_path="$(wslpath -w "${config}")"
    fi
    "${HIDDIFY_CHECK_BIN}" check -c "${check_path}"
  done
fi

for file in "${tmp_dir}/wrapped/TROJAN-US-user.json" \
  "${tmp_dir}/wrapped/HYSTERIA-US-user.json" "${tmp_dir}/hiddify.json"; do
  [[ "$(stat -c '%a' "${file}")" == 600 ]]
done

bulk_out="$("${HIDDIFY_PROFILE_HELPER_PATH}" bulk "${tmp_dir}/raw/hysteria" --output-dir "${tmp_dir}/bulk")"
[[ "${bulk_out}" == "wrapped=1" ]]
[[ -s "${tmp_dir}/bulk/HYSTERIA-US-user.json" ]]
[[ ! -e "${tmp_dir}/bulk/HYSTERIA-US-gecko.json" ]]

printf '%s\n' '[Interface]' >"${tmp_dir}/raw/awg.conf"
if "${HIDDIFY_PROFILE_HELPER_PATH}" wrap "${tmp_dir}/raw/awg.conf" >/dev/null 2>&1; then
  echo "AWG must not be converted to a Hiddify Sing-box profile" >&2
  exit 1
fi

[[ "$(grep -Fc 'install_helper_hiddify_profile' "${installer}")" -ge 3 ]]
[[ "$(grep -Fc '/usr/local/bin/vpn-hiddify-profile wrap "${source}"' "${installer}")" -eq 2 ]]
grep -Fq '/usr/local/bin/vpn-hiddify-profile bundle "${trojan_file}" "${hysteria_file}"' "${installer}"
grep -Fq 'Hiddify JSON: %s/hiddify.json' "${installer}"
if grep -Fq '"${HIDDIFY_PROFILE_HELPER_PATH}" bulk "${KEY_DIR}/awg"' "${installer}"; then
  echo "AWG must keep its native embedded DNS configuration" >&2
  exit 1
fi

printf 'Hiddify JSON profile tests passed\n'
