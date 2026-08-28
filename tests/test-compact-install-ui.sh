#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
status_helper="${tmp_dir}/vpn-install-status"

awk '
  /cat >"\$\{INSTALL_STATUS_HELPER\}" <<'"'"'EOF'"'"'/ {show=1; next}
  show && /^EOF$/ {exit}
  show {print}
' "${installer}" >"${status_helper}"

bash -n "${status_helper}"
grep -Fq 'Important messages:' "${status_helper}"
# shellcheck disable=SC2016
grep -Fq 'important_log_tail "${lines}"' "${status_helper}"
grep -Fq 'enable_compact_install_ui reset' "${installer}"
grep -Fq 'enable_compact_install_ui append' "${installer}"
# shellcheck disable=SC2016
grep -Fq 'exec >>"${RESUME_INSTALL_LOG}" 2>&1' "${installer}"

printf 'compact install UI tests passed\n'
