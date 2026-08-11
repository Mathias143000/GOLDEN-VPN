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
export UPGRADE_BACKUP_ROOT="${KEY_DIR}/upgrade-backups"

mkdir -p \
  "${XRAY_DIR}" \
  "${HYSTERIA_DIR}" \
  "$(dirname "${AWG_CONFIG}")" \
  "${KEY_DIR}/trojan" \
  "${KEY_DIR}/hysteria" \
  "${KEY_DIR}/awg" \
  "${SUBSCRIPTION_DIR}/token-one" \
  "${SUBSCRIPTION_WEB_DIR}/token-one"

cat >"${XRAY_DIR}/config.json" <<'JSON'
{
  "inbounds": [
    {
      "protocol": "trojan",
      "settings": {
        "clients": [
          {"email": "alpha", "password": "secret-alpha"},
          {"email": "beta", "password": "secret-beta"}
        ]
      }
    }
  ]
}
JSON

cat >"${STACK_DIR}/hysteria-clients.json" <<'JSON'
{"alpha":"secret-one","gamma":"secret-two"}
JSON

cat >"${HYSTERIA_DIR}/config.yaml" <<'YAML'
auth:
  type: userpass
  userpass:
    alpha: secret-one
    gamma: secret-two
YAML

cat >"${AWG_CONFIG}" <<'CONF'
[Interface]
PrivateKey = server-private

# alpha
[Peer]
PublicKey = alpha-public

# delta
[Peer]
PublicKey = delta-public
CONF

printf 'trojan profile\n' >"${KEY_DIR}/trojan/alpha.txt"
printf 'hysteria profile\n' >"${KEY_DIR}/hysteria/gamma.txt"
printf 'awg profile\n' >"${KEY_DIR}/awg/delta.conf"
printf '{"name":"alpha"}\n' >"${SUBSCRIPTION_DIR}/token-one/meta.json"
printf 'portal\n' >"${SUBSCRIPTION_WEB_DIR}/token-one/index.html"

before="${tmp_dir}/before.tsv"
after="${tmp_dir}/after.tsv"
changed="${tmp_dir}/changed.tsv"
write_upgrade_profile_manifest "${before}"

[[ "$(detect_installed_xray_protocol)" == "trojan" ]]
[[ "$(manifest_record_count "${before}" xray_client)" == "2" ]]
[[ "$(manifest_record_count "${before}" hysteria_client)" == "2" ]]
[[ "$(awk -F '\t' '$1 == "awg_peer_count" {print $2}' "${before}")" == "2" ]]
if grep -q 'secret-alpha\|secret-one\|server-private' "${before}"; then
  printf 'manifest leaked credential material\n' >&2
  exit 1
fi

backup_dir="$(create_upgrade_backup)"
[[ -s "${backup_dir}/profiles.tar" ]]
[[ -s "${backup_dir}/profiles.tar.sha256" ]]
[[ "$(stat -c '%a' "${backup_dir}/profiles.tar")" == "600" ]]
sha256sum -c "${backup_dir}/profiles.tar.sha256" >/dev/null
tar -tf "${backup_dir}/profiles.tar" | grep -F 'root/vpn-keys/awg/delta.conf' >/dev/null
cmp -s "${before}" "${backup_dir}/profiles.before.tsv"

# Adding non-profile feature files must not alter the preservation manifest.
mkdir -p "${tmp_dir}/usr/local/bin"
printf '#!/usr/bin/env bash\n' >"${tmp_dir}/usr/local/bin/vpn-new-feature"
write_upgrade_profile_manifest "${after}"
cmp -s "${before}" "${after}"

# Legacy VLESS is detected and remains a supported, non-converting upgrade input.
cp "${XRAY_DIR}/config.json" "${tmp_dir}/trojan-config.json"
jq '.inbounds[0].protocol = "vless"' "${XRAY_DIR}/config.json" >"${XRAY_DIR}/config.json.tmp"
mv "${XRAY_DIR}/config.json.tmp" "${XRAY_DIR}/config.json"
[[ "$(detect_installed_xray_protocol)" == "vless" ]]
cp "${tmp_dir}/trojan-config.json" "${XRAY_DIR}/config.json"

# Any credential/profile change must be detected.
printf '\n# unexpected mutation\n' >>"${AWG_CONFIG}"
write_upgrade_profile_manifest "${changed}"
if cmp -s "${before}" "${changed}"; then
  printf 'profile mutation was not detected\n' >&2
  exit 1
fi

# The upgrade implementation must never call destructive protocol installers.
upgrade_code="$({
  awk '/^install_upgrade_helpers\(\)/,/^}/' "${installer}"
  awk '/^apply_upgrade_overlay\(\)/,/^}/' "${installer}"
  awk '/^upgrade_existing_stack\(\)/,/^}/' "${installer}"
})"
for forbidden in \
  configure_xray \
  configure_hysteria \
  configure_amneziawg \
  configure_nginx \
  configure_firewall \
  install_xray \
  install_hysteria \
  install_amneziawg \
  enable_and_start_services; do
  if grep -Eq "(^|[[:space:]])${forbidden}([[:space:]]|$)" <<<"${upgrade_code}"; then
    printf 'upgrade calls destructive function: %s\n' "${forbidden}" >&2
    exit 1
  fi
done

printf 'upgrade profile preservation tests passed\n'
