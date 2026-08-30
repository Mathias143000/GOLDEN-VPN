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
HYSTERIA_DIR="${STACK_DIR}/hysteria"
HYSTERIA_PROFILE_DIR="${STACK_DIR}/hysteria-profiles"
# shellcheck disable=SC2034
CERT_DIR="/etc/letsencrypt/live/test.example.com"
mkdir -p "${HYSTERIA_DIR}" "${HYSTERIA_PROFILE_DIR}"
printf '{"alpha":"unchanged-password","beta":"second-password"}\n' >"${STACK_DIR}/hysteria-clients.json"
printf 'legacy-secret\n' >"${STACK_DIR}/hysteria-obfs.txt"
printf 'gecko-secret\n' >"${STACK_DIR}/hysteria-obfs-gecko.txt"
printf 'mimic-secret\n' >"${STACK_DIR}/hysteria-obfs-mimic.txt"
printf '23456\n' >"${STACK_DIR}/hysteria-gecko-port.txt"
printf '34567\n' >"${STACK_DIR}/hysteria-mimic-port.txt"
cp "${STACK_DIR}/hysteria-clients.json" "${tmp_dir}/clients.before"

hysteria_render_profile_config salamander "${HYSTERIA_DIR}/config.yaml"
hysteria_render_profile_config gecko "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
hysteria_render_profile_config mimic "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"

grep -Fq 'listen: :8443,20000-50000' "${HYSTERIA_DIR}/config.yaml"
grep -Fq 'disablePathMTUDiscovery: true' "${HYSTERIA_DIR}/config.yaml"
grep -Fq 'listen: :23456' "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
grep -Fq 'disablePathMTUDiscovery: true' "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
grep -Fq 'type: gecko' "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
grep -Fq 'minPacketSize: 512' "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
grep -Fq 'maxPacketSize: 1200' "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
grep -Fq 'alpha: unchanged-password' "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
grep -Fq 'listen: :34567' "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
grep -Fq 'disablePathMTUDiscovery: true' "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
grep -Fq 'type: salamander' "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
grep -Fq 'mimic:' "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
grep -Fq 'xdpMode: skb' "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
cmp -s "${tmp_dir}/clients.before" "${STACK_DIR}/hysteria-clients.json"
[[ "${HYSTERIA_PROFILE_DIR}" != "${HYSTERIA_DIR}" ]]

helper="${tmp_dir}/vpn-hysteria"
awk '
  /cat >\/usr\/local\/bin\/vpn-hysteria <<'"'"'EOF'"'"'/ {show=1; next}
  show && /^EOF$/ {exit}
  show {print}
' "${installer}" >"${helper}"
bash -n "${helper}"
# shellcheck disable=SC2016
grep -Fq 'profile="${2:-salamander}"' "${helper}"
# shellcheck disable=SC2016
grep -Fq 'has($name)' "${helper}"
# shellcheck disable=SC2016
grep -Fq '.[$name]' "${helper}"
# shellcheck disable=SC2016
grep -Fq '${label}-gecko.txt' "${helper}"
# shellcheck disable=SC2016
grep -Fq '${label}-mimic.yaml' "${helper}"
grep -Fq 'port="8443,20000-50000"' "${helper}"
grep -Fq 'disablePathMTUDiscovery: true' "${helper}"

grep -Fq 'RuntimeDirectory=mimic' "${installer}"
grep -Fq 'RuntimeDirectoryMode=0755' "${installer}"
grep -Fq ':8443,20000-50000/?obfs=salamander' "${installer}"

printf 'hysteria profile tests passed\n'
