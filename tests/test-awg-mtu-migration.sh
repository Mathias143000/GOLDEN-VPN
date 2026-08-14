#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${GOLDEN_TEST_INSTALLER:-${repo_root}/install-vpn-stack.sh}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

export GOLDEN_VPN_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${installer}"

STACK_DIR="${tmp_dir}/opt/vpn-stack"
KEY_DIR="${tmp_dir}/root/vpn-keys"
XRAY_DIR="${STACK_DIR}/xray"
HYSTERIA_DIR="${STACK_DIR}/hysteria"
SUBSCRIPTION_DIR="${STACK_DIR}/subscriptions"
SUBSCRIPTION_WEB_DIR="${tmp_dir}/var/www/subscriptions"
AWG_CONFIG="${tmp_dir}/etc/amnezia/amneziawg/awg0.conf"
AWG_TUNING_REPORT="${STACK_DIR}/awg-tuning-report.json"
UPGRADE_BACKUP_ROOT="${KEY_DIR}/upgrade-backups"
AWG_MTU_MIGRATION_ROOT="${tmp_dir}/root/vpn-migration/awg-mtu"
AWG_MTU_MIGRATION_REPORT="${KEY_DIR}/awg-mtu-migration-report.json"
AWG_QUICK_BIN="${tmp_dir}/bin/awg-quick"
export STACK_DIR KEY_DIR XRAY_DIR HYSTERIA_DIR SUBSCRIPTION_DIR SUBSCRIPTION_WEB_DIR
export AWG_CONFIG AWG_TUNING_REPORT UPGRADE_BACKUP_ROOT AWG_MTU_MIGRATION_ROOT
export AWG_MTU_MIGRATION_REPORT AWG_QUICK_BIN

mkdir -p "$(dirname "${AWG_CONFIG}")" "${KEY_DIR}/awg" "${STACK_DIR}" "${tmp_dir}/bin"
cat >"${AWG_CONFIG}" <<'CONF'
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = server-private-key
MTU = 1420
Jc = 6
Jmin = 79
Jmax = 539
S1 = 80
S2 = 77
S3 = 51
S4 = 73
H1 = 389647707-436811644
H2 = 604599261-650236027
H3 = 1260918721-1329764915
H4 = 1824969240-1864400415
I1 = <r 2><b 0x85800001>
I2 = <r 18><t><r 12>
I3 = <r 24>
I4 = <t><r 20>
I5 = <rc 12><r 16>

[Peer]
PublicKey = alpha-public
PresharedKey = alpha-psk
AllowedIPs = 10.66.66.2/32

[Peer]
PublicKey = beta-public
PresharedKey = beta-psk
AllowedIPs = 10.66.66.3/32
CONF

# Legacy client without an explicit MTU and without I1-I5. Preparation must
# synchronize tuning from the server without touching its credentials.
cat >"${KEY_DIR}/awg/alpha.conf" <<'CONF'
# alpha
[Interface]
PrivateKey = alpha-private
Address = 10.66.66.2/32
DNS = 1.1.1.1, 8.8.8.8
Jc = 6
Jmin = 79
Jmax = 539
S1 = 80
S2 = 77
S3 = 51
S4 = 73
H1 = 389647707-436811644
H2 = 604599261-650236027
H3 = 1260918721-1329764915
H4 = 1824969240-1864400415

[Peer]
PublicKey = server-public
PresharedKey = alpha-psk
Endpoint = s5.example.test:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF

cat >"${KEY_DIR}/awg/beta.conf" <<'CONF'
# beta
# MTU = 1420
[Interface]
PrivateKey = beta-private
Address = 10.66.66.3/32
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420
Jc = 6
Jmin = 79
Jmax = 539
S1 = 80
S2 = 77
S3 = 51
S4 = 73
H1 = 389647707-436811644
H2 = 604599261-650236027
H3 = 1260918721-1329764915
H4 = 1824969240-1864400415
I1 = <r 2><b 0x85800001>
I2 = <r 18><t><r 12>
I3 = <r 24>
I4 = <t><r 20>
I5 = <rc 12><r 16>

[Peer]
PublicKey = server-public
PresharedKey = beta-psk
Endpoint = s5.example.test:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF

cat >"${AWG_QUICK_BIN}" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
config="${2:-}"
[[ "${1:-}" == "strip" && -s "${config}" ]]
for key in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
  grep -Eiq "^[[:space:]]*${key}[[:space:]]*=" "${config}"
done
cat "${config}"
SH
chmod 0755 "${AWG_QUICK_BIN}"

cat >"${tmp_dir}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  is-active)
    exit 0
    ;;
  restart)
    [[ "${FAIL_AWG_RESTART:-0}" != "1" ]]
    exit 0
    ;;
esac
exit 0
SH
cat >"${tmp_dir}/bin/awg" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == "show" && "${2:-}" == "awg0" ]]
SH
cat >"${tmp_dir}/bin/ip" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
mtu="$(awk -F= 'tolower($1) ~ /^[[:space:]]*mtu[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "${AWG_CONFIG}")"
printf '3: awg0: <UP> mtu %s qdisc noqueue state UNKNOWN\n' "${mtu}"
SH
chmod 0755 "${tmp_dir}/bin/systemctl" "${tmp_dir}/bin/awg" "${tmp_dir}/bin/ip"
export PATH="${tmp_dir}/bin:${PATH}"

cp "${AWG_CONFIG}" "${tmp_dir}/server.original.conf"
cp "${KEY_DIR}/awg/alpha.conf" "${tmp_dir}/alpha.original.conf"
cp "${KEY_DIR}/awg/beta.conf" "${tmp_dir}/beta.original.conf"
write_awg_non_tuning_manifest "${AWG_CONFIG}" "${KEY_DIR}/awg" "${tmp_dir}/identity.original.tsv"

bundle="$(prepare_awg_mtu_migration 1320 | tail -1)"
[[ -d "${bundle}" ]]
cmp -s "${AWG_CONFIG}" "${tmp_dir}/server.original.conf"
cmp -s "${KEY_DIR}/awg/alpha.conf" "${tmp_dir}/alpha.original.conf"
cmp -s "${KEY_DIR}/awg/beta.conf" "${tmp_dir}/beta.original.conf"
(
  cd "${bundle}"
  sha256sum -c bundle.sha256 >/dev/null
)
grep -Eq '^MTU[[:space:]]*=[[:space:]]*1320$' "${bundle}/awg0.candidate.conf"
for client in "${bundle}"/clients.candidate/*.conf; do
  grep -Eq '^MTU[[:space:]]*=[[:space:]]*1320$' "${client}"
  if grep -Eq '^#[[:space:]]*MTU[[:space:]]*=[[:space:]]*1420$' "${client}"; then
    printf 'stale MTU comment remained in %s\n' "${client}" >&2
    exit 1
  fi
  for key in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
    grep -Eiq "^[[:space:]]*${key}[[:space:]]*=" "${client}"
  done
done
cmp -s "${bundle}/identity.before.tsv" "${bundle}/identity.candidate.tsv"
grep -Fq 'AWG_MTU=1320' "${bundle}/awg-params.candidate.env"

if (apply_awg_mtu_migration "${bundle}" >/dev/null 2>&1); then
  printf 'AWG MTU apply accepted missing confirmation\n' >&2
  exit 1
fi

export FAIL_AWG_RESTART=1
if (apply_awg_mtu_migration "${bundle}" --confirm-awg-mtu >/dev/null 2>&1); then
  printf 'AWG MTU apply unexpectedly succeeded during forced restart failure\n' >&2
  exit 1
fi
unset FAIL_AWG_RESTART
cmp -s "${AWG_CONFIG}" "${tmp_dir}/server.original.conf"
cmp -s "${KEY_DIR}/awg/alpha.conf" "${tmp_dir}/alpha.original.conf"
cmp -s "${KEY_DIR}/awg/beta.conf" "${tmp_dir}/beta.original.conf"
[[ ! -e "${STACK_DIR}/awg-params.env" ]]

apply_awg_mtu_migration "${bundle}" --confirm-awg-mtu
grep -Eq '^MTU[[:space:]]*=[[:space:]]*1320$' "${AWG_CONFIG}"
for client in "${KEY_DIR}"/awg/*.conf; do
  grep -Eq '^MTU[[:space:]]*=[[:space:]]*1320$' "${client}"
  for key in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
    grep -Eiq "^[[:space:]]*${key}[[:space:]]*=" "${client}"
  done
done
write_awg_non_tuning_manifest "${AWG_CONFIG}" "${KEY_DIR}/awg" "${tmp_dir}/identity.final.tsv"
cmp -s "${tmp_dir}/identity.original.tsv" "${tmp_dir}/identity.final.tsv"
grep -Fq 'AWG_MTU=1320' "${STACK_DIR}/awg-params.env"
jq -e '.mtu == 1320 and .credentials_preserved == true and .full_awg2_tuning == true' "${AWG_MTU_MIGRATION_REPORT}" >/dev/null

printf 'AWG MTU migration tests passed\n'
