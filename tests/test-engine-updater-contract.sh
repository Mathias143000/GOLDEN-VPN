#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

extract_heredoc() {
  local marker="$1" output="$2"
  awk -v marker="${marker}" '
    index($0, marker) {show=1; next}
    show && /^EOF$/ {exit}
    show {print}
  ' "${installer}" >"${output}"
  [[ -s "${output}" ]]
  bash -n "${output}"
}

extract_heredoc 'cat >/usr/local/sbin/vpn-awg-auto-update.sh <<'"'"'EOF'"'"'' "${tmp_dir}/awg-update"
extract_heredoc 'cat >/usr/local/sbin/vpn-core-auto-update.sh <<'"'"'EOF'"'"'' "${tmp_dir}/core-update"

grep -Fq 'lock_file="/run/vpn-engine-update.lock"' "${tmp_dir}/awg-update"
grep -Fq 'lock_file="/run/vpn-engine-update.lock"' "${tmp_dir}/core-update"
grep -Fq 'profiles.tar.gz' "${tmp_dir}/awg-update"
# shellcheck disable=SC2016
grep -Fq '"${backup_dir}"/debs/*.deb' "${tmp_dir}/awg-update"
grep -Fq -- '--allow-downgrades' "${tmp_dir}/awg-update"
grep -Fq 'releases/latest' "${tmp_dir}/core-update"
grep -Fq 'run -test -config' "${tmp_dir}/core-update"
grep -Fq 'restoring previous Xray and Hysteria binaries' "${tmp_dir}/core-update"
grep -Fq 'hysteria2-gecko.service' "${tmp_dir}/core-update"
grep -Fq 'hysteria2-mimic.service' "${tmp_dir}/core-update"
grep -Fq 'hysteria-gecko-port.txt' "${tmp_dir}/core-update"
if grep -Fq -- '--beta' "${tmp_dir}/core-update"; then exit 1; fi
if grep -Fq 'systemctl reboot' "${tmp_dir}/awg-update" "${tmp_dir}/core-update"; then exit 1; fi

printf 'engine updater contract tests passed\n'
