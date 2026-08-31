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
grep -Fq 'issue_acme_certificate_with_retries letsencrypt "${acme[@]}"' <<<"${function_body}"
grep -Fq 'Certificate issuance failed through both ZeroSSL and Let' <<<"${function_body}"

retry_body="$({
  awk '
    /^issue_acme_certificate_with_retries\(\) \{/ {show=1}
    show {print}
    show && /^}$/ {exit}
  ' "${installer}"
} )"
[[ -n "${retry_body}" ]]
grep -Fq 'VPN_STACK_ACME_ISSUE_ATTEMPTS:-3' <<<"${retry_body}"
grep -Fq 'retrying the saved ACME order' <<<"${retry_body}"
grep -Fq -- '--issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --server "${server}"' <<<"${retry_body}"

existing_check_line="$(grep -nF 'Existing certificate is valid for at least 30 days.' <<<"${function_body}" | cut -d: -f1)"
zone_lookup_line="$(grep -nF 'cloudflare_zone_from_domain' <<<"${function_body}" | cut -d: -f1)"
((existing_check_line < zone_lookup_line))

printf 'ACME CA fallback tests passed\n'
