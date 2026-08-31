#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

export GOLDEN_VPN_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${installer}"

VPN_UDP_BUFFER_SYSCTL_FILE="${tmp_dir}/etc/sysctl.d/97-golden-vpn-udp-buffers.conf"
VPN_SYSCTL_BIN=true
configure_udp_buffers

[[ "$(stat -c '%a' "${VPN_UDP_BUFFER_SYSCTL_FILE}")" == 644 ]]
grep -Fq 'net.core.rmem_default = 4194304' "${VPN_UDP_BUFFER_SYSCTL_FILE}"
grep -Fq 'net.core.rmem_max = 16777216' "${VPN_UDP_BUFFER_SYSCTL_FILE}"
grep -Fq 'net.core.wmem_default = 4194304' "${VPN_UDP_BUFFER_SYSCTL_FILE}"
grep -Fq 'net.core.wmem_max = 16777216' "${VPN_UDP_BUFFER_SYSCTL_FILE}"
grep -Fq 'net.core.netdev_max_backlog = 4096' "${VPN_UDP_BUFFER_SYSCTL_FILE}"

apply_body="$({
  awk '
    /^apply_upgrade_overlay\(\) \{/ {show=1}
    show {print}
    show && /^}$/ {exit}
  ' "${installer}"
} )"
grep -Fq 'configure_udp_buffers' <<<"${apply_body}"

printf 'UDP buffer tuning tests passed\n'
