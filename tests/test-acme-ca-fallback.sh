#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
function_body="$(
  awk '
    /^install_acme_certificate\(\) \{/ {show=1}
    show {print}
    show && /^}$/ {exit}
  ' "${installer}"
)"

[[ -n "${function_body}" ]]
grep -Fq 'Existing certificate is valid for at least 30 days.' <<<"${function_body}"
grep -Fq 'ZeroSSL certificate issuance failed. Retrying with Let' <<<"${function_body}"
# shellcheck disable=SC2016
grep -Fq -- '--issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --server letsencrypt' <<<"${function_body}"
grep -Fq 'Certificate issuance failed through both ZeroSSL and Let' <<<"${function_body}"

existing_check_line="$(grep -nF 'Existing certificate is valid for at least 30 days.' <<<"${function_body}" | cut -d: -f1)"
zone_lookup_line="$(grep -nF 'cloudflare_zone_from_domain' <<<"${function_body}" | cut -d: -f1)"
((existing_check_line < zone_lookup_line))

printf 'ACME CA fallback tests passed\n'
