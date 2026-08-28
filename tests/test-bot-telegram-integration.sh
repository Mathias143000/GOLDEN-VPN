#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

extract_helper() {
  local marker="$1" output="$2"
  awk -v marker="${marker}" '
    index($0, marker) {show=1; next}
    show && /^EOF$/ {exit}
    show {print}
  ' "${installer}" >"${output}"
  chmod 0755 "${output}"
  bash -n "${output}"
}

extract_helper 'cat >/usr/local/bin/vpn-bot-export <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-bot-export"
extract_helper 'cat >/usr/local/bin/vpn-cert-notify <<'"'"'EOF'"'"'' "${tmp_dir}/vpn-cert-notify"

stack_dir="${tmp_dir}/stack"
key_root="${tmp_dir}/keys"
mkdir -p "${stack_dir}" "${key_root}/awg" "${key_root}/trojan" "${key_root}/hysteria"
printf 'NL\n' >"${stack_dir}/server-location.txt"
printf 'test.example.com\n' >"${stack_dir}/domain.txt"
printf '[Interface]\nPrivateKey = awg-secret\n' >"${key_root}/awg/AWG-NL-alpha.conf"
printf 'trojan://trojan-secret@example.invalid#alpha\n' >"${key_root}/trojan/TROJAN-NL-alpha.txt"
printf 'hysteria2://hysteria-secret@example.invalid#alpha\n' >"${key_root}/hysteria/HYSTERIA-NL-alpha.txt"
printf 'server: "example.invalid:23456"\nauth: "alpha:hysteria-secret"\nmimic:\n  enabled: true\n' \
  >"${key_root}/hysteria/HYSTERIA-NL-alpha-mimic.yaml"

export VPN_BOT_EXPORT_ALLOW_NON_ROOT=1
export VPN_BOT_STACK_DIR="${stack_dir}"
export VPN_BOT_KEY_ROOT="${key_root}"

inventory="${tmp_dir}/active.sqlite"
"${tmp_dir}/vpn-bot-export" inventory --type all --plan plan_30 --out "${inventory}"
python3 - "${inventory}" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
assert con.execute("select format_version from export_meta").fetchone()[0] == "golden-vpn.typed-keys.v1"
assert con.execute("select count(*) from typed_keys").fetchone()[0] == 4
assert dict(con.execute("select key_type, count(*) from typed_keys group by key_type")) == {
    "awg": 1, "hysteria": 2, "trojan": 1
}
assert con.execute("select count(*) from typed_keys where plan_code='plan_30'").fetchone()[0] == 4
assert con.execute("select count(*) from typed_keys where key_status='issued'").fetchone()[0] == 4
PY
[[ "$(stat -c '%a' "${inventory}")" == "600" ]]

if "${tmp_dir}/vpn-bot-export" inventory --type awg --plan plan_30 --send >/dev/null 2>&1; then
  echo 'Partial Telegram inventory export was accepted' >&2
  exit 1
fi

# A fake AWG helper exercises batch orchestration without generating real keys.
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/vpn-awg" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
name="$1"
out="${VPN_BOT_KEY_ROOT}/awg/AWG-NL-${name}.conf"
printf '[Interface]\nPrivateKey = generated-%s\n' "${name}" >"${out}"
chmod 0600 "${out}"
SH
chmod 0755 "${tmp_dir}/bin/vpn-awg"
export PATH="${tmp_dir}/bin:${PATH}"

batch="${tmp_dir}/batch.sqlite"
"${tmp_dir}/vpn-bot-export" batch \
  --type awg --count 3 --prefix stock --plan plan_30 --out "${batch}"
python3 - "${batch}" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
rows = con.execute("select key_type, label from typed_keys order by label").fetchall()
assert rows == [
    ("awg", "AWG-NL-stock-0001"),
    ("awg", "AWG-NL-stock-0002"),
    ("awg", "AWG-NL-stock-0003"),
]
assert con.execute("select count(*) from typed_keys where key_status='available'").fetchone()[0] == 3
PY

# Telegram delivery must fail closed when no credentials are configured.
if "${tmp_dir}/vpn-bot-export" send "${inventory}" >/dev/null 2>&1; then
  echo 'Telegram send unexpectedly succeeded without credentials' >&2
  exit 1
fi

# A token file readable by group/others must be rejected before it is sourced.
telegram_env="${tmp_dir}/issuer-bot.env"
printf 'GOLDEN_ISSUER_BOT_TOKEN=do-not-use\nGOLDEN_ISSUER_CHAT_ID=1\n' >"${telegram_env}"
chmod 0644 "${telegram_env}"
if GOLDEN_ISSUER_BOT_ENV="${telegram_env}" "${tmp_dir}/vpn-bot-export" help >/dev/null 2>&1; then
  echo 'Insecure Telegram credential file was accepted' >&2
  exit 1
fi
chmod 0600 "${telegram_env}"

cert_root="${tmp_dir}/certs"
cert_state="${tmp_dir}/cert-state"
mkdir -p "${cert_root}/test.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 5 \
  -subj '/CN=test.example.com' \
  -keyout "${tmp_dir}/key.pem" \
  -out "${cert_root}/test.example.com/fullchain.pem" >/dev/null 2>&1
export VPN_CERT_STACK_DIR="${stack_dir}"
export VPN_CERT_ROOT="${cert_root}"
export VPN_CERT_STATE_DIR="${cert_state}"
check_output="$("${tmp_dir}/vpn-cert-notify" check --dry-run)"
grep -q 'expires soon' <<<"${check_output}"
grep -q 'test.example.com' <<<"${check_output}"
renew_output="$("${tmp_dir}/vpn-cert-notify" renewed --dry-run)"
grep -q 'certificate renewed' <<<"${renew_output}"
[[ ! -e "${cert_state}/cert-notify-state.json" ]]

printf 'bot and certificate notification tests passed\n'
