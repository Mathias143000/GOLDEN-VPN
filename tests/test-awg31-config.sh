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
AWG_TUNING_REPORT="${STACK_DIR}/awg-tuning-report.json"
DOMAIN="awg31.example.test"
SERVER_LOCATION="NL"
AWG_OBFS_PROFILE="dns"
AWG_MTU="1320"
export DOMAIN SERVER_LOCATION AWG_OBFS_PROFILE AWG_MTU
mkdir -p "${STACK_DIR}" "${KEY_DIR}"

awg() {
  case "${1:-}" in
    genkey)
      printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
      ;;
    pubkey)
      cat >/dev/null
      printf 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n'
      ;;
    *)
      return 1
      ;;
  esac
}

generate_awg_tuning
# shellcheck disable=SC1090,SC1091
source "${STACK_DIR}/awg-params.env"

[[ "${AWG_PROTOCOL_VERSION}" == "3.1" ]]
[[ "${AWG_MTU}" == "1320" ]]
[[ "${AWG_RANDOM_TRAILERS}" == "on" ]]
[[ "${AWG_DISABLE_COOKIES}" == "off" ]]
[[ -n "${AWG_HEADER_PROTECTION_KEY}" ]]
jq -e '.protocol_version == "3.1" and .header_protection == true and .random_trailers == "on"' \
  "${AWG_TUNING_REPORT}" >/dev/null

client_config="$(write_awg_client_config test-client client-private 10.66.66.2 server-public preshared-key)"
for field in \
  HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime \
  KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies; do
  grep -Eq "^${field}[[:space:]]*=" <<<"${client_config}"
done
grep -Fq '# Protocol = AmneziaWG 3.1' <<<"${client_config}"
grep -Fq 'MTU = 1320' <<<"${client_config}"

for field in \
  HeaderProtectionKey ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime \
  KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies; do
  grep -Fq "${field} = \${AWG_" "${installer}"
done

printf 'AWG 3.1 config tests passed\n'
