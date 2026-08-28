#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"

if grep -Fq 'mode: "stream-one"' "${installer}"; then exit 1; fi
if grep -Fq 'mode=stream-one' "${installer}"; then exit 1; fi
grep -Fq 'mode: "auto"' "${installer}"
grep -Fq 'mode=auto' "${installer}"
grep -Fq 'alpn=h2#' "${installer}"
if grep -Fq 'fp=chrome' "${installer}"; then exit 1; fi
if grep -Eq '"mux"[[:space:]]*:' "${installer}"; then exit 1; fi

printf 'XHTTP auto-mode tests passed\n'
