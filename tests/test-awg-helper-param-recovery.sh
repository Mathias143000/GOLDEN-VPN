#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

helper="$({
  awk '
    /^  cat >\/usr\/local\/bin\/vpn-awg <<'\''EOF'\''$/ {capture=1; next}
    capture && /^EOF$/ {exit}
    capture {print}
  ' "${installer}"
} )"
[[ -n "${helper}" ]]

functions="$({
  awk '
    /^load_params\(\) \{/ {capture=1}
    /^show_usage\(\) \{/ {exit}
    capture {print}
  ' <<<"${helper}"
} )"
[[ -n "${functions}" ]]

die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
eval "${functions}"

STACK_DIR="${tmp_dir}/opt/vpn-stack"
KEY_DIR="${tmp_dir}/root/vpn-keys/awg"
PARAMS="${STACK_DIR}/awg-params.env"
CONFIG="${tmp_dir}/etc/amnezia/amneziawg/awg0.conf"
DEFAULT_PORT=443
mkdir -p "${STACK_DIR}" "${KEY_DIR}" "$(dirname "${CONFIG}")"

cat >"${PARAMS}" <<'EOF_PARAMS'
AWG_MTU=1420
AWG_JC=4
AWG_JMIN=40
AWG_JMAX=70
EOF_PARAMS

cat >"${CONFIG}" <<'EOF_CONFIG'
[Interface]
PrivateKey = server-secret
HeaderProtectionKey = recovered-header-key
ContentPaddingAddition = 16-96
RekeyAfterTime = 120
RekeyTimeout = 5
RejectAfterTime = 180
KeepaliveTimeout = 10
MaxHandshakeAttempts = 5
RandomTrailers = on
DisableCookies = off

[Peer]
PublicKey = peer-public
EOF_CONFIG

load_params
[[ "${AWG_HEADER_PROTECTION_KEY}" == "recovered-header-key" ]]
[[ "${AWG_CONTENT_PADDING_ADDITION}" == "16-96" ]]
[[ "${AWG_REKEY_AFTER_TIME}" == 120 ]]
[[ "${AWG_REKEY_TIMEOUT}" == 5 ]]
[[ "${AWG_REJECT_AFTER_TIME}" == 180 ]]
[[ "${AWG_KEEPALIVE_TIMEOUT}" == 10 ]]
[[ "${AWG_MAX_HANDSHAKE_ATTEMPTS}" == 5 ]]
[[ "${AWG_RANDOM_TRAILERS}" == on ]]
[[ "${AWG_DISABLE_COOKIES}" == off ]]

empty="${KEY_DIR}/AWG-FR-RIBULYA.conf"
: >"${empty}"
archive_empty_client_file "${empty}"
[[ ! -e "${empty}" ]]
[[ "$(find "${KEY_DIR}/.failed" -maxdepth 1 -type f -name 'AWG-FR-RIBULYA.conf.empty.*' | wc -l)" -eq 1 ]]

printf 'AWG helper parameter recovery tests passed\n'
