#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${repo_root}/install-vpn-stack.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

extract_single_quoted_heredoc() {
  local target="$1"
  awk -v target="${target}" '
    index($0, "cat >" target " <<\047EOF\047") {show=1; next}
    show && /^EOF$/ {exit}
    show {print}
  ' "${installer}"
}

for name in vpn-stack grafana-server golden-vpn-external-logs; do
  extract_single_quoted_heredoc "/etc/logrotate.d/${name}" >"${tmp_dir}/${name}.logrotate"
  if [[ "${name}" == "grafana-server" ]]; then
    sed -i 's/create 0640 grafana adm/create 0640 root root/' "${tmp_dir}/${name}.logrotate"
  fi
  logrotate --debug "${tmp_dir}/${name}.logrotate" >/dev/null
done

extract_single_quoted_heredoc /usr/local/sbin/vpn-storage-maintenance.sh \
  >"${tmp_dir}/vpn-storage-maintenance.sh"
chmod 0755 "${tmp_dir}/vpn-storage-maintenance.sh"
bash -n "${tmp_dir}/vpn-storage-maintenance.sh"

for unit in vpn-storage-maintenance.service vpn-storage-maintenance.timer; do
  extract_single_quoted_heredoc "/etc/systemd/system/${unit}" >"${tmp_dir}/${unit}"
done
sed -i "s#/usr/local/sbin/vpn-storage-maintenance.sh#${tmp_dir}/vpn-storage-maintenance.sh#" \
  "${tmp_dir}/vpn-storage-maintenance.service"
systemd-analyze verify \
  "${tmp_dir}/vpn-storage-maintenance.service" \
  "${tmp_dir}/vpn-storage-maintenance.timer"

eval "$(awk '
  /^set_ini_section_value\(\)/ {show=1}
  /^configure_log_limits\(\)/ {exit}
  show {print}
' "${installer}")"

printf '%s\n' \
  '[server]' \
  'http_port = 3000' \
  '[log.file]' \
  ';max_size_shift = 28' \
  'max_days = 7' \
  '[paths]' \
  'logs = /var/log/grafana' >"${tmp_dir}/grafana.ini"
set_ini_section_value "${tmp_dir}/grafana.ini" log.file max_size_shift 24
set_ini_section_value "${tmp_dir}/grafana.ini" log.file max_days 3
grep -qx 'max_size_shift = 24' "${tmp_dir}/grafana.ini"
grep -qx 'max_days = 3' "${tmp_dir}/grafana.ini"
[[ "$(grep -c '^max_size_shift[[:space:]]*=' "${tmp_dir}/grafana.ini")" -eq 1 ]]
[[ "$(grep -c '^max_days[[:space:]]*=' "${tmp_dir}/grafana.ini")" -eq 1 ]]

printf '%s\n' \
  '/var/log/syslog' \
  '{' \
  '    rotate 7' \
  '    daily' \
  '}' \
  '/var/log/mail.log' \
  '{' \
  '    weekly' \
  '}' >"${tmp_dir}/rsyslog"
ensure_logrotate_path_maxsize \
  "${tmp_dir}/rsyslog" \
  '^[[:space:]]*/var/log/syslog([[:space:]]|$)' \
  50M
ensure_logrotate_path_maxsize \
  "${tmp_dir}/rsyslog" \
  '^[[:space:]]*/var/log/syslog([[:space:]]|$)' \
  50M
[[ "$(grep -c '^[[:space:]]*maxsize 50M$' "${tmp_dir}/rsyslog")" -eq 1 ]]
