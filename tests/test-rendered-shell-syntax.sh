#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${repo_root}/install-vpn-stack.sh"
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

status_helper="${tmp_dir}/vpn-install-status"
# shellcheck disable=SC2016
extract_heredoc 'cat >"${INSTALL_STATUS_HELPER}" <<'"'"'EOF'"'"'' "${status_helper}"
if grep -Fq 'tput clear' "${status_helper}"; then
  printf 'vpn-install-status must not clear the terminal during watch updates\n' >&2
  exit 1
fi
grep -Fq 'WATCH_LAST_FRAME' "${status_helper}"
extract_heredoc 'cat >/usr/local/sbin/amneziawg-ensure-module.sh <<'"'"'EOF'"'"'' "${tmp_dir}/amneziawg-ensure-module"
# shellcheck disable=SC2016
extract_heredoc 'cat >"${TROJAN_HELPER_PATH}" <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-trojan"
extract_heredoc 'cat >/usr/local/bin/vpn-hysteria <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-hysteria"
extract_heredoc 'cat >/usr/local/bin/vpn-awg <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-awg"
extract_heredoc 'cat >/usr/local/bin/vpn-sub <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-sub"
extract_heredoc 'cat >/usr/local/bin/vpn-bot-export <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-bot-export"
extract_heredoc 'cat >/usr/local/bin/vpn-cert-notify <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-cert-notify"
extract_heredoc 'cat >/usr/local/bin/vpn-help <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-help"
extract_heredoc 'cat >/usr/local/sbin/vpn-storage-maintenance.sh <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-storage-maintenance"
extract_heredoc 'cat >/usr/local/sbin/vpn-awg-auto-update.sh <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-awg-auto-update"
extract_heredoc 'cat >/usr/local/sbin/vpn-core-auto-update.sh <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-core-auto-update"
extract_heredoc 'cat >/usr/local/sbin/vpn-stack-healthcheck.sh <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-stack-healthcheck"

printf 'rendered shell syntax tests passed\n'
