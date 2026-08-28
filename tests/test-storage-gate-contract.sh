#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"

storage_hint_line="$(awk '/^storage_hint\(\) \{/ {print NR; exit}' "${installer}")"
storage_gate_line="$(awk '/^require_install_storage\(\) \{/ {print NR; exit}' "${installer}")"

[[ "${storage_hint_line}" =~ ^[0-9]+$ ]]
[[ "${storage_gate_line}" =~ ^[0-9]+$ ]]
((storage_hint_line < storage_gate_line))
grep -Fq 'INSTALL_RESUME_MIN_FREE_MB=3072' "${installer}"
grep -Fq 'base_package_stage_complete' "${installer}"
# shellcheck disable=SC2016
grep -Fq 'storage_required_mb="$(install_required_free_mb)"' "${installer}"

printf 'storage gate contract tests passed\n'
