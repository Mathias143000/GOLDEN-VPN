#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"

storage_hint_line="$(awk '/^storage_hint\(\) \{/ {print NR; exit}' "${installer}")"
storage_gate_line="$(awk '/^require_install_storage\(\) \{/ {print NR; exit}' "${installer}")"

[[ "${storage_hint_line}" =~ ^[0-9]+$ ]]
[[ "${storage_gate_line}" =~ ^[0-9]+$ ]]
((storage_hint_line < storage_gate_line))

printf 'storage gate contract tests passed\n'
