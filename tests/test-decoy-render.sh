#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

export GOLDEN_VPN_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${installer}"

STACK_DIR="${tmp_dir}/stack"
DECOY_PROFILE="edge-docs"
DECOY_SEED="golden-decoy-test"
export STACK_DIR DECOY_PROFILE DECOY_SEED
mkdir -p "${STACK_DIR}"

render_decoy_site "${tmp_dir}/site" "${tmp_dir}/manifest.json"
for file in \
  index.html status.html docs.html privacy.html 404.html robots.txt \
  assets/style.css assets/favicon.svg; do
  [[ -s "${tmp_dir}/site/${file}" ]]
done
grep -Fq '<link rel="icon" href="/assets/favicon.svg"' "${tmp_dir}/site/index.html"
jq -e '.profile == "edge-docs" and (.pages | index("assets/favicon.svg")) != null' \
  "${tmp_dir}/manifest.json" >/dev/null
scan_decoy_tree "${tmp_dir}/site"

printf 'decoy render tests passed\n'
