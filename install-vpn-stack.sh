#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
export DEBIAN_FRONTEND=noninteractive

STACK_DIR="/opt/vpn-stack"
KEY_DIR="/root/vpn-keys"
XRAY_DIR="${STACK_DIR}/xray"
HYSTERIA_DIR="${STACK_DIR}/hysteria"
LOG_DIR="/var/log/vpn-stack"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN:-}"
TROJAN_XHTTP_SOCKET="/dev/shm/xray-trojan-xhttp.sock"
RESUME_INSTALL_DIR="/root/vpn-stack-resume"
RESUME_INSTALL_SCRIPT="${RESUME_INSTALL_DIR}/install-vpn-stack.sh"
RESUME_INSTALL_ENV_DIR="/etc/golden-vpn-installer"
RESUME_INSTALL_ENV="${RESUME_INSTALL_ENV_DIR}/install.env"
RESUME_INSTALL_RUNNER="/usr/local/sbin/vpn-stack-resume-install.sh"
RESUME_INSTALL_SERVICE="vpn-stack-resume-install.service"
RESUME_INSTALL_UNIT="/etc/systemd/system/${RESUME_INSTALL_SERVICE}"
RESUME_INSTALL_TIMER="vpn-stack-resume-install.timer"
RESUME_INSTALL_TIMER_UNIT="/etc/systemd/system/${RESUME_INSTALL_TIMER}"
RESUME_INSTALL_LOG="/var/log/vpn-stack-resume-install.log"
SSH_GUARD_SCRIPT="/usr/local/sbin/vpn-stack-ssh-guard.sh"
SSH_GUARD_SERVICE="vpn-stack-ssh-guard.service"
SSH_GUARD_UNIT="/etc/systemd/system/${SSH_GUARD_SERVICE}"
INSTALL_LOCK="/run/golden-vpn-install.lock"
INSTALL_PROGRESS_FILE="${LOG_DIR}/install-progress.env"
INSTALL_STATUS_HELPER="/usr/local/bin/vpn-install-status"
INSTALL_TOTAL_STEPS=25
INSTALL_STEP=0
PUBLIC_IPV4=""
EXT_IFACE=""
SWAP_RESULT="not checked"
DKMS_KERNEL_REBOOT_PROMPTED=0

BASE_PACKAGES=(
  curl
  wget
  unzip
  jq
  openssl
  ca-certificates
  openssh-server
  socat
  qrencode
  ufw
  lsb-release
  gnupg
  iptables
  tcpdump
  python3
  build-essential
  dkms
  nginx
  libnginx-mod-stream
  prometheus
  prometheus-node-exporter
  grafana
)

log() {
  printf '[vpn-stack] %s\n' "$*"
}

warn() {
  printf '[vpn-stack] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[vpn-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

progress() {
  local message="$1"
  local width=24
  local filled empty percent bar

  INSTALL_STEP=$((INSTALL_STEP + 1))
  if [[ "${INSTALL_STEP}" -gt "${INSTALL_TOTAL_STEPS}" ]]; then
    INSTALL_STEP="${INSTALL_TOTAL_STEPS}"
  fi

  percent=$((INSTALL_STEP * 100 / INSTALL_TOTAL_STEPS))
  filled=$((INSTALL_STEP * width / INSTALL_TOTAL_STEPS))
  empty=$((width - filled))
  bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')$(printf '%*s' "${empty}" '' | tr ' ' '-')"
  log "[${bar}] ${percent}% (${INSTALL_STEP}/${INSTALL_TOTAL_STEPS}) ${message}"

  if mkdir -p "$(dirname "${INSTALL_PROGRESS_FILE}")" 2>/dev/null; then
    {
      printf 'STEP=%q\n' "${INSTALL_STEP}"
      printf 'TOTAL=%q\n' "${INSTALL_TOTAL_STEPS}"
      printf 'PERCENT=%q\n' "${percent}"
      printf 'MESSAGE=%q\n' "${message}"
      printf 'UPDATED_AT=%q\n' "$(date -Is)"
    } >"${INSTALL_PROGRESS_FILE}" 2>/dev/null || true
    chmod 0600 "${INSTALL_PROGRESS_FILE}" 2>/dev/null || true
  fi
}

on_error() {
  local line="$1"
  warn "Installation failed near line ${line}. Check the messages above."
}
trap 'on_error "$LINENO"' ERR

have_tty() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prompt_required_var() {
  local var="$1"
  local label="$2"
  local secret="${3:-0}"
  local value

  if [[ -n "${!var:-}" ]]; then
    return 0
  fi

  have_tty || die "${var} is empty and no interactive terminal is available. Export ${var}=... before running."

  while true; do
    if [[ "${secret}" == "1" ]]; then
      printf '%s: ' "${label}" >/dev/tty
      IFS= read -r -s value </dev/tty || die "Could not read ${var}."
      printf '\n' >/dev/tty
    else
      printf '%s: ' "${label}" >/dev/tty
      IFS= read -r value </dev/tty || die "Could not read ${var}."
    fi

    value="$(trim_value "${value}")"
    if [[ -n "${value}" ]]; then
      printf -v "${var}" '%s' "${value}"
      export "${var}"
      return 0
    fi

    printf '%s cannot be empty.\n' "${var}" >/dev/tty
  done
}

prompt_yes_no() {
  local prompt="$1"
  local answer

  have_tty || return 1
  while true; do
    printf '%s [Y/n]: ' "${prompt}" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    answer="$(trim_value "${answer}")"
    case "${answer}" in
      ""|y|Y|yes|YES|Yes)
        return 0
        ;;
      n|N|no|NO|No)
        return 1
        ;;
      *)
        printf 'Please answer y or n.\n' >/dev/tty
        ;;
    esac
  done
}

require_root_and_env() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
  load_saved_resume_env
  prompt_required_var DOMAIN "DOMAIN, without https://, example s5.example.com"
  prompt_required_var EMAIL "EMAIL for ZeroSSL/acme.sh"
  prompt_required_var CF_Token "Cloudflare DNS API token (hidden input)" 1
  CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
}

installer_self_path() {
  local self
  self="$(readlink -f "$0" 2>/dev/null || true)"
  [[ -n "${self}" && -r "${self}" ]] || return 1
  printf '%s\n' "${self}"
}

load_saved_resume_env() {
  if [[ -z "${VPN_STACK_RESUMED:-}" && -r "${RESUME_INSTALL_ENV}" ]]; then
    log "Loading saved installer environment from ${RESUME_INSTALL_ENV}."
    set -a
    # shellcheck disable=SC1090
    source "${RESUME_INSTALL_ENV}"
    set +a
    export VPN_STACK_RESUMED=1
  fi
}

write_resume_env() {
  install -d -m 0700 "${RESUME_INSTALL_ENV_DIR}"
  {
    printf 'DOMAIN=%q\n' "${DOMAIN}"
    printf 'EMAIL=%q\n' "${EMAIL}"
    printf 'CF_Token=%q\n' "${CF_Token}"
    [[ -n "${CF_Zone_ID:-}" ]] && printf 'CF_Zone_ID=%q\n' "${CF_Zone_ID}"
    [[ -n "${CF_Account_ID:-}" ]] && printf 'CF_Account_ID=%q\n' "${CF_Account_ID}"
    [[ -n "${ZEROSSL_EAB_KID:-}" ]] && printf 'ZEROSSL_EAB_KID=%q\n' "${ZEROSSL_EAB_KID}"
    [[ -n "${ZEROSSL_EAB_HMAC_KEY:-}" ]] && printf 'ZEROSSL_EAB_HMAC_KEY=%q\n' "${ZEROSSL_EAB_HMAC_KEY}"
    [[ -n "${VPN_STACK_DISABLE_LE_FALLBACK:-}" ]] && printf 'VPN_STACK_DISABLE_LE_FALLBACK=%q\n' "${VPN_STACK_DISABLE_LE_FALLBACK}"
    printf 'VPN_STACK_RESUMED=1\n'
    printf 'DEBIAN_FRONTEND=noninteractive\n'
  } >"${RESUME_INSTALL_ENV}"
  chmod 0600 "${RESUME_INSTALL_ENV}"
}

ensure_ssh_firewall_access() {
  local ssh_port had_errexit=0

  case $- in
    *e*)
      had_errexit=1
      set +e
      ;;
  esac

  log "Ensuring SSH remains reachable before firewall/reboot changes."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp comment 'SSH default' || true
    ufw allow OpenSSH || true

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      ssh_port="$(awk '{print $4}' <<<"${SSH_CONNECTION}" 2>/dev/null || true)"
      if [[ "${ssh_port}" =~ ^[0-9]+$ ]]; then
        ufw allow "${ssh_port}/tcp" comment 'Current SSH session' || true
      fi
    fi

    if command -v sshd >/dev/null 2>&1; then
      while read -r ssh_port; do
        if [[ "${ssh_port}" =~ ^[0-9]+$ ]]; then
          ufw allow "${ssh_port}/tcp" comment 'sshd configured port' || true
        fi
      done < <(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -n -u)
    fi

    if [[ -r /etc/ssh/sshd_config || -d /etc/ssh/sshd_config.d ]]; then
      while read -r ssh_port; do
        if [[ "${ssh_port}" =~ ^[0-9]+$ ]]; then
          ufw allow "${ssh_port}/tcp" comment 'sshd config port' || true
        fi
      done < <(grep -RihE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | sort -n -u)
    fi

    ufw reload || true
  fi

  if ! command -v sshd >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y openssh-server >/dev/null 2>&1 || true
  fi

  ssh-keygen -A >/dev/null 2>&1 || true
  systemctl unmask ssh sshd ssh.service sshd.service ssh.socket >/dev/null 2>&1 || true
  systemctl enable --now ssh.service >/dev/null 2>&1 \
    || systemctl enable --now sshd.service >/dev/null 2>&1 \
    || systemctl enable --now ssh.socket >/dev/null 2>&1 \
    || true
  systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart sshd.service >/dev/null 2>&1 || true

  if [[ "${had_errexit}" == "1" ]]; then
    set -e
  fi
  return 0
}

install_ssh_guard_once() {
  local current_ssh_port=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    current_ssh_port="$(awk '{print $4}' <<<"${SSH_CONNECTION}" 2>/dev/null || true)"
  fi

  cat >"${SSH_GUARD_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

log_file="/var/log/vpn-stack-ssh-guard.log"
current_ssh_port="${current_ssh_port}"

{
  printf '%s ssh guard start\n' "\$(date -Is)"

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp comment 'SSH default' || true
    ufw allow OpenSSH || true

    if [[ "\${current_ssh_port}" =~ ^[0-9]+$ ]]; then
      ufw allow "\${current_ssh_port}/tcp" comment 'Current SSH session before reboot' || true
    fi

    if command -v sshd >/dev/null 2>&1; then
      while read -r ssh_port; do
        if [[ "\${ssh_port}" =~ ^[0-9]+$ ]]; then
          ufw allow "\${ssh_port}/tcp" comment 'sshd configured port' || true
        fi
      done < <(sshd -T 2>/dev/null | awk '\$1 == "port" {print \$2}' | sort -n -u)
    fi

    if [[ -r /etc/ssh/sshd_config || -d /etc/ssh/sshd_config.d ]]; then
      while read -r ssh_port; do
        if [[ "\${ssh_port}" =~ ^[0-9]+$ ]]; then
          ufw allow "\${ssh_port}/tcp" comment 'sshd config port' || true
        fi
      done < <(grep -RihE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print \$2}' | sort -n -u)
    fi

    ufw reload || true
    ufw status verbose || true
  fi

  if ! command -v sshd >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    apt-get update || true
    apt-get install -y openssh-server || true
  fi

  ssh-keygen -A || true
  systemctl unmask ssh sshd ssh.service sshd.service ssh.socket || true
  systemctl enable --now ssh.service || systemctl enable --now sshd.service || systemctl enable --now ssh.socket || true
  systemctl restart ssh.service || systemctl restart sshd.service || true
  ss -lntp | grep -E ':(22|'"${current_ssh_port:-22}"')' || true
  printf '%s ssh guard done\n' "\$(date -Is)"
} >>"\${log_file}" 2>&1
EOF
  chmod 0755 "${SSH_GUARD_SCRIPT}"

  cat >"${SSH_GUARD_UNIT}" <<EOF
[Unit]
Description=Keep SSH reachable during Golden VPN installer resume
DefaultDependencies=no
Before=network-online.target ${RESUME_INSTALL_SERVICE}
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${SSH_GUARD_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${SSH_GUARD_UNIT}"

  systemctl daemon-reload
  systemctl enable "${SSH_GUARD_SERVICE}" >/dev/null 2>&1 || true
}

install_resume_status_helper() {
  cat >"${INSTALL_STATUS_HELPER}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

service="${RESUME_INSTALL_SERVICE}"
timer="${RESUME_INSTALL_TIMER}"
log_file="${RESUME_INSTALL_LOG}"
progress_file="${INSTALL_PROGRESS_FILE}"
lock_file="${INSTALL_LOCK}"

show_status() {
  echo "Golden VPN installer status"
  echo
  if [[ -r "\${progress_file}" ]]; then
    # shellcheck disable=SC1090
    source "\${progress_file}" || true
    printf 'Progress: %s/%s %s%% - %s\n' "\${STEP:-?}" "\${TOTAL:-?}" "\${PERCENT:-?}" "\${MESSAGE:-unknown}"
    printf 'Updated: %s\n' "\${UPDATED_AT:-unknown}"
    echo
  fi
  systemctl status "\${service}" --no-pager -l || true
  echo
  systemctl list-timers "\${timer}" --no-pager || true
  echo
  if command -v fuser >/dev/null 2>&1 && fuser "\${lock_file}" >/dev/null 2>&1; then
    echo "Installer lock is held: another install/resume run is active."
  fi
  echo
  if [[ -r "\${log_file}" ]]; then
    echo "Last log lines:"
    tail -n 80 "\${log_file}" || true
  else
    echo "No log file yet: \${log_file}"
  fi
}

case "\${1:-status}" in
  follow|-f)
    echo "Following \${service}. Press Ctrl+C to stop watching."
    journalctl -fu "\${service}"
    ;;
  log)
    tail -n "\${2:-200}" "\${log_file}" || true
    ;;
  status|"")
    show_status
    ;;
  *)
    echo "Usage: vpn-install-status [status|follow|log [lines]]" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "${INSTALL_STATUS_HELPER}"
}

cleanup_resume_install_state() {
  local had_state=0
  for path in "${RESUME_INSTALL_UNIT}" "${RESUME_INSTALL_TIMER_UNIT}" "${RESUME_INSTALL_RUNNER}" "${RESUME_INSTALL_SCRIPT}" "${RESUME_INSTALL_ENV}" "${INSTALL_STATUS_HELPER}" "${SSH_GUARD_UNIT}" "${SSH_GUARD_SCRIPT}"; do
    [[ -e "${path}" ]] && had_state=1
  done

  systemctl disable "${RESUME_INSTALL_SERVICE}" "${RESUME_INSTALL_TIMER}" "${SSH_GUARD_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${RESUME_INSTALL_UNIT}" "${RESUME_INSTALL_TIMER_UNIT}" "${RESUME_INSTALL_RUNNER}" "${RESUME_INSTALL_SCRIPT}" "${RESUME_INSTALL_ENV}" "${INSTALL_STATUS_HELPER}" "${SSH_GUARD_UNIT}" "${SSH_GUARD_SCRIPT}"
  rmdir "${RESUME_INSTALL_DIR}" 2>/dev/null || true
  rmdir "${RESUME_INSTALL_ENV_DIR}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ "${had_state}" == "1" ]]; then
    log "One-time resume state removed."
  fi
}

schedule_resume_install_once() {
  local self
  self="$(installer_self_path)" || die "Could not resolve installer path. Download the script to a file and run it again."

  install -d -m 0700 "${RESUME_INSTALL_DIR}"
  install -m 0700 "${self}" "${RESUME_INSTALL_SCRIPT}"
  write_resume_env
  install_resume_status_helper
  install_ssh_guard_once
  ensure_ssh_firewall_access

  cat >"${RESUME_INSTALL_RUNNER}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

service="${RESUME_INSTALL_SERVICE}"
timer="${RESUME_INSTALL_TIMER}"
unit="${RESUME_INSTALL_UNIT}"
timer_unit="${RESUME_INSTALL_TIMER_UNIT}"
runner="${RESUME_INSTALL_RUNNER}"
status_helper="${INSTALL_STATUS_HELPER}"
ssh_guard_service="${SSH_GUARD_SERVICE}"
ssh_guard_unit="${SSH_GUARD_UNIT}"
ssh_guard_script="${SSH_GUARD_SCRIPT}"
env_file="${RESUME_INSTALL_ENV}"
env_dir="${RESUME_INSTALL_ENV_DIR}"
installer="${RESUME_INSTALL_SCRIPT}"
resume_dir="${RESUME_INSTALL_DIR}"
log_file="${RESUME_INSTALL_LOG}"

mkdir -p "\$(dirname "\${log_file}")"
touch "\${log_file}"
chmod 0600 "\${log_file}" || true
exec > >(tee -a "\${log_file}") 2>&1

printf '%s resume start\n' "\$(date -Is)"
printf 'Use "vpn-install-status follow" to watch this installation.\n'
printf 'Do not start install-vpn-stack.sh manually while this service is active.\n'

if [[ ! -r "\${env_file}" || ! -x "\${installer}" ]]; then
  printf '%s missing resume env or installer; keeping service for diagnostics\n' "\$(date -Is)"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "\${env_file}"
set +a
export VPN_STACK_RESUMED=1
export DEBIAN_FRONTEND=noninteractive

printf '%s resume env loaded from %s\n' "\$(date -Is)" "\${env_file}"

set +e
bash "\${installer}"
status="\$?"
set -e

if [[ "\${status}" -eq 0 ]]; then
  printf '%s resume install succeeded; removing one-time unit and saved env\n' "\$(date -Is)"
  systemctl disable "\${service}" "\${timer}" "\${ssh_guard_service}" >/dev/null 2>&1 || true
  rm -f "\${unit}" "\${timer_unit}" "\${env_file}" "\${installer}" "\${runner}" "\${status_helper}" "\${ssh_guard_unit}" "\${ssh_guard_script}"
  rmdir "\${resume_dir}" 2>/dev/null || true
  rmdir "\${env_dir}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
else
  printf '%s resume install failed; keeping unit/env for next boot or manual retry\n' "\$(date -Is)"
fi

printf '%s resume exit status=%s\n' "\$(date -Is)" "\${status}"
exit "\${status}"
EOF
  chmod 0700 "${RESUME_INSTALL_RUNNER}"

  cat >"${RESUME_INSTALL_UNIT}" <<EOF
[Unit]
Description=Resume Golden VPN installer once after reboot
After=network-online.target
Wants=network-online.target
ConditionPathExists=${RESUME_INSTALL_SCRIPT}
ConditionPathExists=${RESUME_INSTALL_ENV}

[Service]
Type=oneshot
EnvironmentFile=${RESUME_INSTALL_ENV}
ExecStartPre=/bin/sleep 15
ExecStart=${RESUME_INSTALL_RUNNER}
TimeoutStartSec=0
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${RESUME_INSTALL_UNIT}"

  cat >"${RESUME_INSTALL_TIMER_UNIT}" <<EOF
[Unit]
Description=Start Golden VPN installer resume once after boot

[Timer]
OnBootSec=1min
AccuracySec=15s
Persistent=false
Unit=${RESUME_INSTALL_SERVICE}

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "${RESUME_INSTALL_TIMER_UNIT}"

  systemctl daemon-reload
  systemctl enable "${RESUME_INSTALL_SERVICE}" "${RESUME_INSTALL_TIMER}"
  log "One-time resume service installed: ${RESUME_INSTALL_SERVICE}"
  log "One-time resume timer installed: ${RESUME_INSTALL_TIMER}"
  log "SSH guard installed for the reboot: ${SSH_GUARD_SERVICE}"
  log "Resume env saved: ${RESUME_INSTALL_ENV}"
  log "Resume log after reboot: ${RESUME_INSTALL_LOG}"
  log "Resume journal after reboot: journalctl -u ${RESUME_INSTALL_SERVICE} -b --no-pager"
  log "Resume timer after reboot: systemctl list-timers ${RESUME_INSTALL_TIMER} --no-pager"
  log "Live resume output after reboot: vpn-install-status follow"
}

auto_reboot_resume_enabled() {
  [[ "${VPN_STACK_AUTO_REBOOT_RESUME:-}" == "1" || "${AUTO_REBOOT_RESUME:-}" == "1" ]]
}

newest_installed_kernel() {
  find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
    | sed 's/^vmlinuz-//' \
    | sort -V \
    | tail -n 1
}

check_dkms_kernel_ready() {
  local mode="${1:-prompt}"
  local running latest
  running="$(uname -r)"
  latest="$(newest_installed_kernel || true)"

  if [[ -n "${latest}" && "${latest}" != "${running}" ]]; then
    cat >&2 <<EOF
[vpn-stack] Pending kernel reboot detected.
[vpn-stack] Running kernel: ${running}
[vpn-stack] Latest installed kernel: ${latest}

AmneziaWG uses DKMS. Building the kernel module while the VPS is still
running an older kernel often fails.
EOF

    if [[ "${VPN_STACK_RESUMED:-}" == "1" ]]; then
      cat >&2 <<EOF

[vpn-stack] ERROR: The one-time resume already ran, but the kernel is still not updated.
Reboot manually and check that the VPS boots into ${latest}.
EOF
      exit 1
    fi

    if auto_reboot_resume_enabled; then
      schedule_resume_install_once
      log "Rebooting now. The installer will continue once after the VPS comes back."
      systemctl reboot
      exit 0
    fi

    if [[ "${mode}" == "prompt" && "${DKMS_KERNEL_REBOOT_PROMPTED}" != "1" ]]; then
      DKMS_KERNEL_REBOOT_PROMPTED=1
      if prompt_yes_no "Reboot now and resume installer once after boot?"; then
        schedule_resume_install_once
        log "Rebooting now. The installer will continue once after the VPS comes back."
        systemctl reboot
        exit 0
      fi
    else
      warn "Kernel reboot is required before AmneziaWG DKMS can continue; not asking again in this run."
    fi

    cat >&2 <<EOF

Reboot the VPS, then run the installer again:

  reboot
  ./install-vpn-stack.sh

EOF
    exit 1
  fi
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

detect_public_ipv4() {
  local ip
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ip="$(curl -4fsS --max-time 8 https://ifconfig.me/ip || true)"
  fi
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Could not determine public IPv4."
  PUBLIC_IPV4="${ip}"
  log "Public IPv4: ${PUBLIC_IPV4}"
}

detect_external_iface() {
  EXT_IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "${EXT_IFACE}" ]] || die "Could not determine external network interface."
  log "External interface: ${EXT_IFACE}"
}

verify_domain_dns() {
  local found
  found="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  [[ -n "${found}" ]] || die "DOMAIN does not resolve to IPv4 yet: ${DOMAIN}"
  if ! printf '%s\n' "${found}" | tr ' ' '\n' | grep -qx "${PUBLIC_IPV4}"; then
    die "DOMAIN must resolve to ${PUBLIC_IPV4}. Current IPv4 answer(s): ${found}. Use Cloudflare DNS only / grey cloud."
  fi
  log "DOMAIN resolves to server IPv4."
}

install_apt_repositories() {
  log "Installing APT prerequisites and external repositories."
  apt-get update
  apt-get install -y apt-transport-https curl wget ca-certificates gnupg lsb-release iproute2 software-properties-common

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      add-apt-repository -y universe || true
    fi
  fi

  install -d -m 0755 /etc/apt/keyrings

  wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
  chmod 0644 /etc/apt/keyrings/grafana.asc
  printf 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main\n' \
    >/etc/apt/sources.list.d/grafana.list
  chmod 0644 /etc/apt/sources.list.d/grafana.list

  install -d -m 0755 /usr/share/keyrings
  if ! gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 75C9DD72C799870E310542E24166F2C257290828 >/dev/null 2>&1; then
    curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75C9DD72C799870E310542E24166F2C257290828' \
      | gpg --batch --dearmor >/usr/share/keyrings/amnezia.gpg
  else
    gpg --batch --export 75C9DD72C799870E310542E24166F2C257290828 | gpg --batch --dearmor >/usr/share/keyrings/amnezia.gpg
  fi
  chmod 0644 /usr/share/keyrings/amnezia.gpg
  cat >/etc/apt/sources.list.d/amneziawg.list <<'EOF'
deb [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
deb-src [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main
EOF
  chmod 0644 /etc/apt/sources.list.d/amneziawg.list

  apt-get update
}

install_base_packages() {
  log "Installing base packages."
  apt-get install -y "${BASE_PACKAGES[@]}" software-properties-common python3-launchpadlib
  apt-get install -y "linux-headers-$(uname -r)" || warn "linux-headers-$(uname -r) was not installable; AmneziaWG DKMS may need manual kernel headers."
}

cloudflare_zone_from_domain() {
  local domain="$1"
  local parts candidate response zone_id
  IFS='.' read -r -a parts <<<"${domain}"
  for ((i=0; i<${#parts[@]}-1; i++)); do
    candidate="$(IFS='.'; echo "${parts[*]:i}")"
    response="$(curl -fsS --max-time 15 \
      -H "Authorization: Bearer ${CF_Token}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones?name=${candidate}&status=active" || true)"
    zone_id="$(printf '%s' "${response}" | jq -r '.result[0].id // empty' 2>/dev/null || true)"
    if [[ -n "${zone_id}" ]]; then
      printf '%s\n' "${zone_id}"
      return 0
    fi
  done
  return 1
}

fetch_zerossl_eab_credentials() {
  local response kid hmac

  if [[ -n "${ZEROSSL_EAB_KID:-}" && -n "${ZEROSSL_EAB_HMAC_KEY:-}" ]]; then
    return 0
  fi

  log "Requesting ZeroSSL EAB credentials for ${EMAIL}."
  response="$(curl -fsS --max-time 20 -X POST \
    https://api.zerossl.com/acme/eab-credentials-email \
    --data-urlencode "email=${EMAIL}" || true)"

  kid="$(printf '%s' "${response}" | jq -r '.eab_kid // .kid // .data.eab_kid // empty' 2>/dev/null || true)"
  hmac="$(printf '%s' "${response}" | jq -r '.eab_hmac_key // .hmac_key // .data.eab_hmac_key // empty' 2>/dev/null || true)"

  if [[ -n "${kid}" && -n "${hmac}" ]]; then
    ZEROSSL_EAB_KID="${kid}"
    ZEROSSL_EAB_HMAC_KEY="${hmac}"
    export ZEROSSL_EAB_KID ZEROSSL_EAB_HMAC_KEY
    [[ -d "${RESUME_INSTALL_ENV_DIR}" ]] && write_resume_env
    log "ZeroSSL EAB credentials received."
    return 0
  fi

  warn "ZeroSSL EAB API did not return credentials for ${EMAIL}."
  if [[ -n "${response}" ]]; then
    printf '%s\n' "${response}" | jq -c . >&2 2>/dev/null || printf '%s\n' "${response}" >&2
  fi
  return 1
}

ensure_zerossl_account() {
  local -a acme=("$@")

  if "${acme[@]}" --register-account -m "${EMAIL}" --server zerossl; then
    return 0
  fi

  warn "Automatic ZeroSSL account registration failed; trying ZeroSSL EAB API."
  if ! fetch_zerossl_eab_credentials; then
    warn "ZeroSSL EAB credentials are unavailable; continuing with fallback CA."
    return 1
  fi

  "${acme[@]}" --register-account \
    -m "${EMAIL}" \
    --server zerossl \
    --eab-kid "${ZEROSSL_EAB_KID}" \
    --eab-hmac-key "${ZEROSSL_EAB_HMAC_KEY}"
}

install_acme_certificate() {
  log "Issuing ZeroSSL certificate with acme.sh DNS-01."
  local acme_server="zerossl"
  install -d -m 0700 /root/.acme.sh /root/acme-zerossl
  install -d -m 0755 "${CERT_DIR}"

  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    local acme_installer
    acme_installer="$(mktemp)"
    curl -fsSL https://get.acme.sh -o "${acme_installer}"
    HOME=/root sh "${acme_installer}" email="${EMAIL}"
    rm -f "${acme_installer}"
  fi

  export CF_Token
  if [[ -z "${CF_Zone_ID:-}" && -z "${CF_Account_ID:-}" ]]; then
    CF_Zone_ID="$(cloudflare_zone_from_domain "${DOMAIN}" || true)"
    if [[ -z "${CF_Zone_ID}" ]]; then
      warn "Could not auto-detect Cloudflare zone. Token may not have Zone:Read permission."
      prompt_required_var CF_Zone_ID "Cloudflare Zone ID"
    fi
    export CF_Zone_ID
  fi

  local acme=(/root/.acme.sh/acme.sh --home /root/.acme.sh --config-home /root/acme-zerossl)
  "${acme[@]}" --set-default-ca --server zerossl
  if ! ensure_zerossl_account "${acme[@]}"; then
    if [[ "${VPN_STACK_DISABLE_LE_FALLBACK:-0}" == "1" ]]; then
      die "ZeroSSL account registration failed and Let's Encrypt fallback is disabled."
    fi
    warn "ZeroSSL registration failed. Falling back to Let's Encrypt DNS-01 for this certificate."
    acme_server="letsencrypt"
    "${acme[@]}" --set-default-ca --server letsencrypt
    "${acme[@]}" --register-account -m "${EMAIL}" --server letsencrypt || true
  fi

  if [[ -s "${CERT_DIR}/fullchain.pem" && -s "${CERT_DIR}/privkey.pem" ]] \
    && openssl x509 -checkend 2592000 -noout -in "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1 \
    && openssl pkey -check -noout -in "${CERT_DIR}/privkey.pem" >/dev/null 2>&1; then
    log "Existing certificate is valid for at least 30 days."
    return
  fi

  "${acme[@]}" --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --server "${acme_server}"
  "${acme[@]}" --install-cert -d "${DOMAIN}" --ecc \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --key-file "${CERT_DIR}/privkey.pem" \
    --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true; systemctl restart hysteria2 >/dev/null 2>&1 || true"

  openssl x509 -noout -subject -issuer -dates -in "${CERT_DIR}/fullchain.pem"
  openssl pkey -check -noout -in "${CERT_DIR}/privkey.pem"
}

install_xray() {
  log "Installing Xray."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
  systemctl disable --now xray.service >/dev/null 2>&1 || true
}

rand_hex() {
  openssl rand -hex "$1"
}

uri_encode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

label_name() {
  local prefix="$1"
  local name="$2"
  if [[ "${name}" == "${prefix}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s' "${prefix}" "${name}"
  fi
}

pick_decoy_value() {
  local count="$#"
  local idx
  [[ "${count}" -gt 0 ]] || return 1
  idx="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
  idx=$((idx % count + 1))
  while ((idx > 1)); do
    shift
    idx=$((idx - 1))
  done
  printf '%s' "$1"
}

write_trojan_link() {
  local password="$1"
  local name="$2"
  local domain path label encoded_path fragment link
  domain="$(<"${STACK_DIR}/domain.txt")"
  path="$(<"${STACK_DIR}/trojan-xhttp-path.txt")"
  label="$(label_name "TROJAN" "${name}")"
  encoded_path="$(uri_encode "${path}")"
  fragment="$(uri_encode "${label}")"
  link="trojan://${password}@${domain}:443?security=tls&type=xhttp&path=${encoded_path}&mode=stream-one&sni=${domain}&host=${domain}&fp=chrome&alpn=h2%2Chttp%2F1.1#${fragment}"
  install -d -m 0700 "${KEY_DIR}/trojan"
  printf '%s\n' "${link}" >"${KEY_DIR}/trojan/${label}.txt"
  chmod 0600 "${KEY_DIR}/trojan/${label}.txt"
  printf '%s\n' "${link}"
}

configure_xray() {
  log "Configuring Trojan XHTTP TLS backend."
  install -d -m 0700 "${STACK_DIR}" "${XRAY_DIR}" "${LOG_DIR}" "${KEY_DIR}/trojan"
  printf '%s\n' "${DOMAIN}" >"${STACK_DIR}/domain.txt"
  printf '%s\n' "${PUBLIC_IPV4}" >"${STACK_DIR}/public-ipv4.txt"
  printf '%s\n' "${EXT_IFACE}" >"${STACK_DIR}/external-interface.txt"

  local password path
  password="$(rand_hex 24)"
  path="/$(rand_hex 8)/$(rand_hex 8)/"

  printf '%s\n' "${password}" >"${STACK_DIR}/trojan-xhttp-password.txt"
  printf '%s\n' "${path}" >"${STACK_DIR}/trojan-xhttp-path.txt"
  printf '%s\n' "${TROJAN_XHTTP_SOCKET}" >"${STACK_DIR}/trojan-xhttp-socket.txt"
  chmod 0600 "${STACK_DIR}"/trojan-xhttp-*.txt
  rm -f "${TROJAN_XHTTP_SOCKET}" /dev/shm/xray-vless-xhttp.sock
  rm -f "${STACK_DIR}"/vless-xhttp-*.txt "${STACK_DIR}"/vless-reality-*.txt
  systemctl disable --now xray-vless-xhttp-tls.service >/dev/null 2>&1 || true
  systemctl disable --now xray-vless-reality-xhttp.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray-vless-xhttp-tls.service
  rm -f /etc/systemd/system/xray-vless-reality-xhttp.service

  jq -n \
    --arg password "${password}" \
    --arg path "${path}" \
    --arg listen "${TROJAN_XHTTP_SOCKET},0666" \
    '{
      log: {
        loglevel: "warning",
        access: "/var/log/vpn-stack/xray-access.log",
        error: "/var/log/vpn-stack/xray-error.log"
      },
      inbounds: [
        {
          tag: "trojan-xhttp-tls",
          listen: $listen,
          protocol: "trojan",
          settings: {
            clients: [
              { password: $password, email: "main-trojan" }
            ]
          },
          streamSettings: {
            network: "xhttp",
            xhttpSettings: {
              path: $path,
              mode: "stream-one"
            }
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"]
          }
        }
      ],
      outbounds: [
        { protocol: "freedom", tag: "direct" },
        { protocol: "blackhole", tag: "blocked" }
      ]
    }' >"${XRAY_DIR}/config.json"
  chmod 0600 "${XRAY_DIR}/config.json"

  cat >/etc/systemd/system/xray-trojan-xhttp-tls.service <<EOF
[Unit]
Description=Xray Trojan XHTTP TLS backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=/usr/bin/rm -f ${TROJAN_XHTTP_SOCKET}
ExecStart=/usr/local/bin/xray run -config ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
RuntimeDirectory=xray-trojan-xhttp
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/xray-trojan-xhttp-tls.service

  /usr/local/bin/xray run -test -config "${XRAY_DIR}/config.json"
  write_trojan_link "${password}" "main-trojan" >/dev/null
}

configure_nginx() {
  log "Configuring nginx HTTPS decoy and Trojan XHTTP TLS path."
  install -d -m 0755 /var/www/decoy/assets /etc/nginx/stream-conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled

  local trojan_path brand tagline focus region primary accent bg surface build_id status_note docs_title
  trojan_path="$(<"${STACK_DIR}/trojan-xhttp-path.txt")"
  brand="$(pick_decoy_value "Netwatch" "Pulsegrid" "Uplink Labs" "Signal Harbor" "Lattice Monitor" "Northstar Systems")"
  tagline="$(pick_decoy_value "Lightweight network availability monitoring." "Practical uptime checks for distributed teams." "Quiet visibility for service availability." "Simple status signals for operations teams.")"
  focus="$(pick_decoy_value "availability checks" "edge route checks" "latency snapshots" "incident notes" "maintenance windows")"
  region="$(pick_decoy_value "EU-West" "North Atlantic" "Central Europe" "Edge Group 7" "Global Relay")"
  primary="$(pick_decoy_value "#0f766e" "#2563eb" "#334155" "#047857" "#4f46e5")"
  accent="$(pick_decoy_value "#f59e0b" "#06b6d4" "#22c55e" "#f97316" "#64748b")"
  bg="$(pick_decoy_value "#f8fafc" "#f5f7fb" "#f7f7f2" "#f4f7f5")"
  surface="$(pick_decoy_value "#ffffff" "#fbfdff" "#fffdf7")"
  build_id="$(rand_hex 4)"
  status_note="$(pick_decoy_value "All public endpoints are responding normally." "No active maintenance windows are scheduled." "Regional checks are within normal operating range." "Availability sampling is operating normally.")"
  docs_title="$(pick_decoy_value "Operator notes" "Check catalog" "Availability guide" "Reference notes")"

  printf '%s\n' "${brand}" >"${STACK_DIR}/decoy-brand.txt"
  printf '%s\n' "${build_id}" >"${STACK_DIR}/decoy-build-id.txt"
  chmod 0600 "${STACK_DIR}/decoy-brand.txt" "${STACK_DIR}/decoy-build-id.txt"

  cat >/var/www/decoy/assets/style.css <<EOF
:root {
  --primary: ${primary};
  --accent: ${accent};
  --bg: ${bg};
  --surface: ${surface};
  --text: #172033;
  --muted: #607086;
  --line: #d9e1ea;
}

* { box-sizing: border-box; }
html { min-height: 100%; background: var(--bg); }
body { margin: 0; min-height: 100vh; font-family: Arial, Helvetica, sans-serif; color: var(--text); background: var(--bg); }
a { color: inherit; text-decoration: none; }
.site-header { border-bottom: 1px solid var(--line); background: rgba(255,255,255,.82); }
.wrap { width: min(1040px, calc(100% - 40px)); margin: 0 auto; }
.nav { display: flex; align-items: center; justify-content: space-between; min-height: 72px; gap: 24px; }
.brand { display: flex; align-items: center; gap: 12px; font-weight: 700; }
.mark { width: 34px; height: 34px; border-radius: 8px; background: linear-gradient(135deg, var(--primary), var(--accent)); }
.nav-links { display: flex; align-items: center; gap: 18px; color: var(--muted); font-size: 14px; }
.hero { padding: 72px 0 50px; }
.hero-grid { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(280px, .85fr); gap: 42px; align-items: center; }
.eyebrow { color: var(--primary); font-size: 13px; font-weight: 700; text-transform: uppercase; letter-spacing: .08em; }
h1 { margin: 14px 0 18px; font-size: clamp(36px, 7vw, 62px); line-height: 1.02; letter-spacing: 0; }
.lead { max-width: 640px; color: var(--muted); font-size: 18px; line-height: 1.7; }
.panel { border: 1px solid var(--line); border-radius: 8px; background: var(--surface); padding: 24px; }
.metric { display: grid; grid-template-columns: 1fr auto; gap: 12px; padding: 14px 0; border-bottom: 1px solid var(--line); }
.metric:last-child { border-bottom: 0; }
.metric span { color: var(--muted); }
.ok { color: var(--primary); font-weight: 700; }
.section { padding: 42px 0; }
.cards { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 18px; }
.card { border: 1px solid var(--line); border-radius: 8px; background: var(--surface); padding: 22px; }
.card h2, .card h3 { margin: 0 0 10px; }
.card p, .body-copy { color: var(--muted); line-height: 1.65; }
.footer { border-top: 1px solid var(--line); color: var(--muted); padding: 28px 0; font-size: 14px; }
@media (max-width: 760px) {
  .nav { align-items: flex-start; flex-direction: column; padding: 18px 0; }
  .nav-links { flex-wrap: wrap; }
  .hero { padding-top: 44px; }
  .hero-grid, .cards { grid-template-columns: 1fr; }
}
EOF

  cat >/var/www/decoy/index.html <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${brand} - Availability Monitoring</title>
  <link rel="stylesheet" href="/assets/style.css">
</head>
<body>
  <header class="site-header">
    <div class="wrap nav">
      <a class="brand" href="/"><span class="mark"></span><span>${brand}</span></a>
      <nav class="nav-links"><a href="/status">Status</a><a href="/docs">Docs</a><a href="/privacy">Privacy</a></nav>
    </div>
  </header>
  <main class="hero">
    <div class="wrap hero-grid">
      <section>
        <div class="eyebrow">${region} / build ${build_id}</div>
        <h1>${tagline}</h1>
        <p class="lead">${brand} provides a compact public surface for ${focus}, maintenance messages, and simple service availability snapshots.</p>
      </section>
      <aside class="panel">
        <div class="metric"><span>Public endpoint</span><strong class="ok">Online</strong></div>
        <div class="metric"><span>Sampling window</span><strong>60 sec</strong></div>
        <div class="metric"><span>Signal region</span><strong>${region}</strong></div>
        <div class="metric"><span>Incident feed</span><strong class="ok">Clear</strong></div>
      </aside>
    </div>
  </main>
  <section class="section"><div class="wrap cards"><article class="card"><h3>Endpoint checks</h3><p>Small availability checks help teams confirm that public service surfaces are reachable.</p></article><article class="card"><h3>Maintenance notes</h3><p>Planned work and operational windows are recorded as concise status updates.</p></article><article class="card"><h3>Route samples</h3><p>Regional signal snapshots make routine network behavior easier to compare over time.</p></article></div></section>
  <footer class="footer"><div class="wrap">(c) 2026 ${brand}. Operational reference ${build_id}.</div></footer>
</body>
</html>
EOF

  cat >/var/www/decoy/status.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Status - ${brand}</title><link rel="stylesheet" href="/assets/style.css"></head>
<body>
  <header class="site-header"><div class="wrap nav"><a class="brand" href="/"><span class="mark"></span><span>${brand}</span></a><nav class="nav-links"><a href="/status">Status</a><a href="/docs">Docs</a><a href="/privacy">Privacy</a></nav></div></header>
  <main class="section"><div class="wrap"><div class="eyebrow">Status</div><h1>Service status</h1><p class="lead">${status_note}</p><div class="panel"><div class="metric"><span>HTTPS surface</span><strong class="ok">Operational</strong></div><div class="metric"><span>Monitoring schedule</span><strong class="ok">Operational</strong></div><div class="metric"><span>Incident queue</span><strong>Empty</strong></div></div></div></main>
  <footer class="footer"><div class="wrap">Last generated reference ${build_id}.</div></footer>
</body>
</html>
EOF

  cat >/var/www/decoy/docs.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Docs - ${brand}</title><link rel="stylesheet" href="/assets/style.css"></head>
<body>
  <header class="site-header"><div class="wrap nav"><a class="brand" href="/"><span class="mark"></span><span>${brand}</span></a><nav class="nav-links"><a href="/status">Status</a><a href="/docs">Docs</a><a href="/privacy">Privacy</a></nav></div></header>
  <main class="section"><div class="wrap"><div class="eyebrow">${docs_title}</div><h1>Availability reference</h1><p class="body-copy">This static reference describes the public status surface, sampling cadence, and maintenance message format used by ${brand}. It does not collect visitor input and does not require an account.</p><div class="cards"><article class="card"><h3>Checks</h3><p>Endpoint checks are lightweight and intended for availability confirmation.</p></article><article class="card"><h3>Updates</h3><p>Maintenance updates are short, timestamped, and human reviewed.</p></article><article class="card"><h3>Retention</h3><p>Public operational notes are kept compact and rotated periodically.</p></article></div></div></main>
  <footer class="footer"><div class="wrap">Reference ${build_id}.</div></footer>
</body>
</html>
EOF

  cat >/var/www/decoy/privacy.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Privacy - ${brand}</title><link rel="stylesheet" href="/assets/style.css"></head>
<body>
  <header class="site-header"><div class="wrap nav"><a class="brand" href="/"><span class="mark"></span><span>${brand}</span></a><nav class="nav-links"><a href="/status">Status</a><a href="/docs">Docs</a><a href="/privacy">Privacy</a></nav></div></header>
  <main class="section"><div class="wrap"><div class="eyebrow">Privacy</div><h1>Minimal public page</h1><p class="lead">${brand} is a static informational surface. It has no forms, no accounts, no cookies, and no browser analytics.</p><div class="panel"><p class="body-copy">Standard web server logs may record request time, IP address, user agent, and requested path for security and operational troubleshooting.</p></div></div></main>
  <footer class="footer"><div class="wrap">Policy reference ${build_id}.</div></footer>
</body>
</html>
EOF

  cat >/var/www/decoy/404.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Not found - ${brand}</title><link rel="stylesheet" href="/assets/style.css"></head>
<body><main class="section"><div class="wrap"><div class="eyebrow">404</div><h1>Page not found</h1><p class="lead">The requested reference page is not available.</p><p><a href="/">Return to ${brand}</a></p></div></main></body>
</html>
EOF

  cat >/var/www/decoy/robots.txt <<'EOF'
User-agent: *
Allow: /
Disallow: /assets/
EOF
  chmod 0644 /var/www/decoy/assets/style.css /var/www/decoy/index.html /var/www/decoy/status.html /var/www/decoy/docs.html /var/www/decoy/privacy.html /var/www/decoy/404.html /var/www/decoy/robots.txt

  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-enabled/decoy-8444.conf /etc/nginx/sites-available/decoy-8444.conf
  rm -f /etc/nginx/stream-conf.d/vpn-stack.conf

  cat >/etc/nginx/sites-available/decoy-443.conf <<EOF
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    root /var/www/decoy;
    index index.html;

    location ^~ ${trojan_path} {
        client_max_body_size 0;
        client_body_timeout 5m;
        grpc_read_timeout 315s;
        grpc_send_timeout 5m;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_pass unix:${TROJAN_XHTTP_SOCKET};
    }

    location / {
        try_files \$uri \$uri.html \$uri/ /404.html;
    }

    error_page 404 /404.html;
}
EOF
  chmod 0644 /etc/nginx/sites-available/decoy-443.conf
  ln -sf /etc/nginx/sites-available/decoy-443.conf /etc/nginx/sites-enabled/decoy-443.conf

  nginx -t
}

install_hysteria() {
  log "Installing Hysteria2."
  bash <(curl -fsSL https://get.hy2.sh/)
  local svc
  for svc in hysteria-server.service hysteria.service hysteria@server.service; do
    systemctl disable --now "${svc}" >/dev/null 2>&1 || true
  done
  need_command hysteria
}

hysteria_render_config() {
  local clients_json="${STACK_DIR}/hysteria-clients.json"
  local obfs
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"

  {
    printf 'listen: :8443\n'
    printf 'tls:\n'
    printf '  cert: %s/fullchain.pem\n' "${CERT_DIR}"
    printf '  key: %s/privkey.pem\n' "${CERT_DIR}"
    printf 'auth:\n'
    printf '  type: userpass\n'
    printf '  userpass:\n'
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "${clients_json}"
    printf 'obfs:\n'
    printf '  type: salamander\n'
    printf '  salamander:\n'
    printf '    password: %s\n' "${obfs}"
  } >"${HYSTERIA_DIR}/config.yaml"
  chmod 0600 "${HYSTERIA_DIR}/config.yaml"
}

write_hysteria_link() {
  local name="$1"
  local password="$2"
  local obfs domain label tag link
  domain="$(<"${STACK_DIR}/domain.txt")"
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
  label="$(label_name "HYSTERIA" "${name}")"
  tag="$(uri_encode "${label}")"
  link="hysteria2://${name}:${password}@${domain}:8443?obfs=salamander&obfs-password=${obfs}&sni=${domain}#${tag}"
  install -d -m 0700 "${KEY_DIR}/hysteria"
  printf '%s\n' "${link}" >"${KEY_DIR}/hysteria/${label}.txt"
  chmod 0600 "${KEY_DIR}/hysteria/${label}.txt"
  printf '%s\n' "${link}"
}

configure_hysteria() {
  log "Configuring Hysteria2 Salamander."
  install -d -m 0700 "${HYSTERIA_DIR}" "${KEY_DIR}/hysteria"
  local password obfs
  password="$(rand_hex 18)"
  obfs="$(rand_hex 24)"
  printf '%s\n' "${password}" >"${STACK_DIR}/hysteria-auth.txt"
  printf '%s\n' "${obfs}" >"${STACK_DIR}/hysteria-obfs.txt"
  jq -n --arg password "${password}" '{"main-hysteria-client": $password}' >"${STACK_DIR}/hysteria-clients.json"
  chmod 0600 "${STACK_DIR}/hysteria-auth.txt" "${STACK_DIR}/hysteria-obfs.txt" "${STACK_DIR}/hysteria-clients.json"

  hysteria_render_config
  write_hysteria_link "main-hysteria-client" "${password}" >/dev/null

  cat >/etc/systemd/system/hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Salamander server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$(command -v hysteria) server -c ${HYSTERIA_DIR}/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/hysteria2.service
}

install_amneziawg() {
  log "Installing AmneziaWG."
  check_dkms_kernel_ready no-prompt
  apt-get update
  if ! apt-get install -y amneziawg; then
    warn "amneziawg meta package install failed; trying amneziawg-dkms and amneziawg-tools directly."
    if ! apt-get install -y amneziawg-dkms amneziawg-tools; then
      if [[ -f /var/lib/dkms/amneziawg/1.0.0/build/make.log ]]; then
        warn "Last 80 lines of AmneziaWG DKMS build log:"
        tail -n 80 /var/lib/dkms/amneziawg/1.0.0/build/make.log >&2 || true
      else
        warn "AmneziaWG DKMS make.log was not found at /var/lib/dkms/amneziawg/1.0.0/build/make.log."
      fi
      die "Could not install AmneziaWG packages. If a kernel upgrade is pending, reboot the VPS and rerun this installer."
    fi
  fi

  if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1; then
    warn "awg or awg-quick was not found after package install; building amneziawg-tools from source."
    apt-get install -y git make golang-go
    local build_dir
    build_dir="$(mktemp -d)"
    git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools "${build_dir}/amneziawg-tools"
    make -C "${build_dir}/amneziawg-tools/src"
    make -C "${build_dir}/amneziawg-tools/src" install
    rm -rf "${build_dir}"
  fi

  need_command awg
  need_command awg-quick
}

rand_u32() {
  local n
  while true; do
    n="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    if [[ "${n}" =~ ^[0-9]+$ && "${n}" -ge 5 && "${n}" -le 4294967294 ]]; then
      printf '%s\n' "${n}"
      return
    fi
  done
}

rand_between() {
  local min="$1"
  local max="$2"
  local span n
  span=$((max - min + 1))
  while true; do
    n="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    if [[ "${n}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' $((min + (n % span)))
      return
    fi
  done
}

rand_range() {
  local min="$1"
  local max="$2"
  local width_min="$3"
  local width_max="$4"
  local start width end
  start="$(rand_between "${min}" "$((max - width_max))")"
  width="$(rand_between "${width_min}" "${width_max}")"
  end=$((start + width))
  printf '%s-%s\n' "${start}" "${end}"
}

awg_genpsk() {
  if awg genpsk >/dev/null 2>&1; then
    awg genpsk
  else
    openssl rand -base64 32
  fi
}

write_awg_client_config() {
  local name="$1"
  local client_private="$2"
  local client_ip="$3"
  local server_public="$4"
  local psk="$5"
  local label out_file
  label="$(label_name "AWG" "${name}")"
  out_file="${KEY_DIR}/awg/${label}.conf"

  # shellcheck disable=SC1091
  source "${STACK_DIR}/awg-params.env"
  install -d -m 0700 "${KEY_DIR}/awg"
  cat >"${out_file}" <<EOF
# ${label}
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
I1 = ${AWG_I1}
I2 = ${AWG_I2}
I3 = ${AWG_I3}
I4 = ${AWG_I4}
I5 = ${AWG_I5}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${DOMAIN}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 0600 "${out_file}"
  cat "${out_file}"
}

configure_amneziawg() {
  log "Configuring AmneziaWG 2.0."
  install -d -m 0700 /etc/amnezia/amneziawg "${KEY_DIR}/awg"

  cat >/etc/sysctl.d/98-vpn-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  chmod 0644 /etc/sysctl.d/98-vpn-forward.conf
  sysctl --system >/dev/null || true

  local server_private server_public client_private client_public psk
  server_private="$(awg genkey)"
  server_public="$(printf '%s\n' "${server_private}" | awg pubkey)"
  client_private="$(awg genkey)"
  client_public="$(printf '%s\n' "${client_private}" | awg pubkey)"
  psk="$(awg_genpsk)"

  local awg_profile jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5
  awg_profile="${AWG_OBFS_PROFILE:-dns}"
  case "${awg_profile}" in
    dns)
      jc="$(rand_between 5 8)"
      jmin="$(rand_between 48 96)"
      jmax="$(rand_between 420 760)"
      s1="$(rand_between 64 128)"
      s2="$(rand_between 48 96)"
      s3="$(rand_between 32 80)"
      s4="$(rand_between 64 128)"
      i1="<r 2><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010000026d000457fa27d1>"
      i2="<r 18><t><r 12>"
      i3="<r 24>"
      i4="<t><r 20>"
      i5="<rc 12><r 16>"
      ;;
    quic-lite)
      jc="$(rand_between 6 10)"
      jmin="$(rand_between 96 160)"
      jmax="$(rand_between 760 1180)"
      s1="$(rand_between 96 180)"
      s2="$(rand_between 64 128)"
      s3="$(rand_between 48 96)"
      s4="$(rand_between 96 180)"
      i1="<b 0xc300000001><r 8><t><r 80>"
      i2="<r 32><t><r 32>"
      i3="<r 96>"
      i4="<t><r 48>"
      i5="<r 64>"
      ;;
    *)
      die "Unsupported AWG_OBFS_PROFILE='${awg_profile}'. Use dns or quic-lite."
      ;;
  esac
  h1="$(rand_range 100000000 499999999 25000000 90000000)"
  h2="$(rand_range 600000000 999999999 25000000 90000000)"
  h3="$(rand_range 1100000000 1499999999 25000000 90000000)"
  h4="$(rand_range 1600000000 2100000000 25000000 90000000)"

  cat >"${STACK_DIR}/awg-params.env" <<EOF
AWG_OBFS_PROFILE=${awg_profile}
AWG_JC=${jc}
AWG_JMIN=${jmin}
AWG_JMAX=${jmax}
AWG_S1=${s1}
AWG_S2=${s2}
AWG_S3=${s3}
AWG_S4=${s4}
AWG_H1=${h1}
AWG_H2=${h2}
AWG_H3=${h3}
AWG_H4=${h4}
AWG_I1='${i1}'
AWG_I2='${i2}'
AWG_I3='${i3}'
AWG_I4='${i4}'
AWG_I5='${i5}'
EOF
  chmod 0600 "${STACK_DIR}/awg-params.env"
  printf '%s\n' "${server_public}" >"${STACK_DIR}/awg-server-public-key.txt"
  chmod 0600 "${STACK_DIR}/awg-server-public-key.txt"

  cat >/etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = ${server_private}
Jc = ${jc}
Jmin = ${jmin}
Jmax = ${jmax}
S1 = ${s1}
S2 = ${s2}
S3 = ${s3}
S4 = ${s4}
H1 = ${h1}
H2 = ${h2}
H3 = ${h3}
H4 = ${h4}
I1 = ${i1}
I2 = ${i2}
I3 = ${i3}
I4 = ${i4}
I5 = ${i5}
PostUp = iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o ${EXT_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT
PostUp = iptables -A FORWARD -o awg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o ${EXT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT
PostDown = iptables -D FORWARD -o awg0 -j ACCEPT

[Peer]
PublicKey = ${client_public}
PresharedKey = ${psk}
AllowedIPs = 10.66.66.2/32
EOF
  chmod 0600 /etc/amnezia/amneziawg/awg0.conf

  write_awg_client_config "main-awg" "${client_private}" "10.66.66.2" "${server_public}" "${psk}" >/dev/null

  cat >/usr/local/sbin/amneziawg-ensure-module.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! modprobe amneziawg 2>/dev/null; then
  dkms autoinstall || true
  modprobe amneziawg
fi
EOF
  chmod 0755 /usr/local/sbin/amneziawg-ensure-module.sh

  cat >/etc/systemd/system/amneziawg-ensure-module.service <<'EOF'
[Unit]
Description=Ensure AmneziaWG kernel module is available
DefaultDependencies=no
After=systemd-modules-load.service
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/amneziawg-ensure-module.sh

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/amneziawg-ensure-module.service

  if [[ ! -f /etc/systemd/system/awg-quick@.service && ! -f /lib/systemd/system/awg-quick@.service && ! -f /usr/lib/systemd/system/awg-quick@.service ]]; then
    cat >/etc/systemd/system/awg-quick@.service <<'EOF'
[Unit]
Description=AmneziaWG via awg-quick for %i
After=network-online.target amneziawg-ensure-module.service
Wants=network-online.target
Requires=amneziawg-ensure-module.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity
ExecStart=/bin/sh -c 'exec "$(command -v awg-quick)" up %i'
ExecStop=/bin/sh -c 'exec "$(command -v awg-quick)" down %i'

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/awg-quick@.service
  fi

  install -d -m 0755 /etc/systemd/system/awg-quick@awg0.service.d
  cat >/etc/systemd/system/awg-quick@awg0.service.d/override.conf <<'EOF'
[Unit]
Requires=amneziawg-ensure-module.service
After=network-online.target amneziawg-ensure-module.service
Wants=network-online.target
EOF
  chmod 0644 /etc/systemd/system/awg-quick@awg0.service.d/override.conf
}

configure_swap() {
  log "Configuring swap policy."
  if ! swapon --show | awk 'NR>1 {found=1} END {exit found ? 0 : 1}'; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    chmod 0600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    SWAP_RESULT="created /swapfile 2G"
  else
    SWAP_RESULT="existing swap left in place"
  fi

  cat >/etc/sysctl.d/99-vpn-swap.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
  chmod 0644 /etc/sysctl.d/99-vpn-swap.conf
  sysctl --system >/dev/null || true
}

configure_firewall() {
  log "Configuring UFW firewall."
  ufw default deny incoming
  ufw default allow outgoing
  ensure_ssh_firewall_access
  ufw allow 443/tcp
  ufw allow 8443/udp
  ufw allow 51820/udp
  ufw --force enable
}

install_helper_trojan() {
  cat >/usr/local/bin/vpn-trojan <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/opt/vpn-stack/xray/config.json"
STACK_DIR="/opt/vpn-stack"
KEY_DIR="/root/vpn-keys/trojan"
SERVICE="xray-trojan-xhttp-tls.service"

die() { echo "ERROR: $*" >&2; exit 1; }
uri_encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
print_qr() {
  local payload="$1"
  if command -v qrencode >/dev/null 2>&1; then
    printf '\nQR code:\n'
    if ! printf '%s' "${payload}" | qrencode -t ANSIUTF8 -l L -m 1; then
      echo "QR code render failed; use the text below." >&2
    fi
    printf '\n'
  else
    echo "QR code skipped: qrencode is not installed." >&2
  fi
}
label_name() {
  local prefix="$1"
  local name="$2"
  if [[ "${name}" == "${prefix}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s' "${prefix}" "${name}"
  fi
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ $# -eq 1 ]] || die "Usage: vpn-trojan <name>"
name="$1"
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CONFIG}" ]] || die "Missing ${CONFIG}"
label="$(label_name "TROJAN" "${name}")"

if jq -e --arg email "${name}" '.inbounds[] | select(.tag=="trojan-xhttp-tls") | .settings.clients[]? | select(.email==$email)' "${CONFIG}" >/dev/null; then
  die "Client already exists: ${name}"
fi
if [[ -f "${KEY_DIR}/${label}.txt" ]]; then
  die "Client key file already exists: ${KEY_DIR}/${label}.txt"
fi

password="$(openssl rand -hex 24)"
tmp="$(mktemp)"
backup="$(mktemp)"
cp "${CONFIG}" "${backup}"
jq --arg password "${password}" --arg email "${name}" \
  '(.inbounds[] | select(.tag=="trojan-xhttp-tls") | .settings.clients) += [{password: $password, email: $email}]' \
  "${CONFIG}" >"${tmp}"
install -m 0600 "${tmp}" "${CONFIG}"
rm -f "${tmp}"

if ! /usr/local/bin/xray run -test -config "${CONFIG}"; then
  install -m 0600 "${backup}" "${CONFIG}"
  rm -f "${backup}"
  die "Xray config test failed; restored previous config."
fi
rm -f "${backup}"
systemctl restart "${SERVICE}"

domain="$(<"${STACK_DIR}/domain.txt")"
path="$(<"${STACK_DIR}/trojan-xhttp-path.txt")"
encoded_path="$(uri_encode "${path}")"
fragment="$(uri_encode "${label}")"
link="trojan://${password}@${domain}:443?security=tls&type=xhttp&path=${encoded_path}&mode=stream-one&sni=${domain}&host=${domain}&fp=chrome&alpn=h2%2Chttp%2F1.1#${fragment}"

install -d -m 0700 "${KEY_DIR}"
printf '%s\n' "${link}" >"${KEY_DIR}/${label}.txt"
chmod 0600 "${KEY_DIR}/${label}.txt"
printf 'Client: %s\n' "${label}"
print_qr "${link}"
printf 'Link:\n%s\n' "${link}"
printf 'Saved: %s\n' "${KEY_DIR}/${label}.txt"
EOF
  chmod 0755 /usr/local/bin/vpn-trojan
}

install_helper_hysteria() {
  cat >/usr/local/bin/vpn-hysteria <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="/opt/vpn-stack"
CONFIG="/opt/vpn-stack/hysteria/config.yaml"
CLIENTS="/opt/vpn-stack/hysteria-clients.json"
KEY_DIR="/root/vpn-keys/hysteria"
SERVICE="hysteria2.service"

die() { echo "ERROR: $*" >&2; exit 1; }
uri_encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
rand_hex() { openssl rand -hex "$1"; }
print_qr() {
  local payload="$1"
  if command -v qrencode >/dev/null 2>&1; then
    printf '\nQR code:\n'
    if ! printf '%s' "${payload}" | qrencode -t ANSIUTF8 -l L -m 1; then
      echo "QR code render failed; use the text below." >&2
    fi
    printf '\n'
  else
    echo "QR code skipped: qrencode is not installed." >&2
  fi
}
label_name() {
  local prefix="$1"
  local name="$2"
  if [[ "${name}" == "${prefix}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s' "${prefix}" "${name}"
  fi
}

render_config() {
  local obfs
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
  {
    printf 'listen: :8443\n'
    printf 'tls:\n'
    printf '  cert: /etc/letsencrypt/live/%s/fullchain.pem\n' "$(<"${STACK_DIR}/domain.txt")"
    printf '  key: /etc/letsencrypt/live/%s/privkey.pem\n' "$(<"${STACK_DIR}/domain.txt")"
    printf 'auth:\n'
    printf '  type: userpass\n'
    printf '  userpass:\n'
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "${CLIENTS}"
    printf 'obfs:\n'
    printf '  type: salamander\n'
    printf '  salamander:\n'
    printf '    password: %s\n' "${obfs}"
  } >"${CONFIG}"
  chmod 0600 "${CONFIG}"
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ $# -eq 1 ]] || die "Usage: vpn-hysteria <name>"
name="$1"
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CLIENTS}" ]] || die "Missing ${CLIENTS}"
label="$(label_name "HYSTERIA" "${name}")"

if jq -e --arg name "${name}" 'has($name)' "${CLIENTS}" >/dev/null; then
  die "Client already exists: ${name}"
fi
if [[ -f "${KEY_DIR}/${label}.txt" ]]; then
  die "Client key file already exists: ${KEY_DIR}/${label}.txt"
fi

password="$(rand_hex 18)"
tmp="$(mktemp)"
jq --arg name "${name}" --arg password "${password}" '.[$name] = $password' "${CLIENTS}" >"${tmp}"
install -m 0600 "${tmp}" "${CLIENTS}"
rm -f "${tmp}"
render_config
systemctl restart "${SERVICE}"

domain="$(<"${STACK_DIR}/domain.txt")"
obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
tag="$(uri_encode "${label}")"
link="hysteria2://${name}:${password}@${domain}:8443?obfs=salamander&obfs-password=${obfs}&sni=${domain}#${tag}"
install -d -m 0700 "${KEY_DIR}"
printf '%s\n' "${link}" >"${KEY_DIR}/${label}.txt"
chmod 0600 "${KEY_DIR}/${label}.txt"
printf 'Client: %s\n' "${label}"
print_qr "${link}"
printf 'Link:\n%s\n' "${link}"
printf 'Saved: %s\n' "${KEY_DIR}/${label}.txt"
EOF
  chmod 0755 /usr/local/bin/vpn-hysteria
}

install_helper_awg() {
  cat >/usr/local/bin/vpn-awg <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="/opt/vpn-stack"
CONFIG="/etc/amnezia/amneziawg/awg0.conf"
KEY_DIR="/root/vpn-keys/awg"

die() { echo "ERROR: $*" >&2; exit 1; }
awg_genpsk() {
  if awg genpsk >/dev/null 2>&1; then
    awg genpsk
  else
    openssl rand -base64 32
  fi
}
print_qr() {
  local payload="$1"
  if command -v qrencode >/dev/null 2>&1; then
    printf '\nQR code:\n'
    if ! printf '%s' "${payload}" | qrencode -t ANSIUTF8 -l L -m 1; then
      echo "QR code render failed; use the text below." >&2
    fi
    printf '\n'
  else
    echo "QR code skipped: qrencode is not installed." >&2
  fi
}
label_name() {
  local prefix="$1"
  local name="$2"
  if [[ "${name}" == "${prefix}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s' "${prefix}" "${name}"
  fi
}

show_usage() {
  cat <<'USAGE'
Usage:
  vpn-awg <name>          Create a new AmneziaWG client
  vpn-awg analyze [sec]   Print AWG status; if sec > 0, also capture UDP/51820 for sec seconds
  vpn-awg capture [sec]   Save a tcpdump pcap for UDP/51820, default 20 seconds
USAGE
}

next_ip() {
  local i ip
  for i in $(seq 2 254); do
    ip="10.66.66.${i}"
    if ! grep -q "${ip}/32" "${CONFIG}"; then
      printf '%s\n' "${ip}"
      return 0
    fi
  done
  return 1
}

capture_awg_udp() {
  local seconds="${1:-20}"
  local iface out
  [[ "${seconds}" =~ ^[0-9]+$ && "${seconds}" -ge 1 && "${seconds}" -le 300 ]] || die "Capture duration must be 1..300 seconds."
  command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed."
  iface="$(cat "${STACK_DIR}/external-interface.txt" 2>/dev/null || true)"
  [[ -n "${iface}" ]] || iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "${iface}" ]] || die "Could not determine external interface."
  install -d -m 0700 /var/log/vpn-stack/awg-captures
  out="/var/log/vpn-stack/awg-captures/awg-udp-51820-$(date +%Y%m%d-%H%M%S).pcap"
  echo "Capturing UDP/51820 on ${iface} for ${seconds}s -> ${out}"
  echo "The pcap contains encrypted UDP metadata; keep it private."
  timeout "${seconds}" tcpdump -ni "${iface}" -s 192 -w "${out}" udp port 51820 || true
  chmod 0600 "${out}" 2>/dev/null || true
  echo "Saved: ${out}"
  echo "Packet size summary:"
  tcpdump -nn -tt -r "${out}" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "length") {
          n = $(i + 1)
          gsub(/[^0-9]/, "", n)
          if (n != "") {
            n += 0
            count++
            if (min == "" || n < min) min = n
            if (n > max) max = n
            bucket[int(n / 100) * 100]++
          }
        }
      }
    }
    END {
      if (!count) {
        print "  no packets captured"
        exit
      }
      printf "  packets=%d min=%d max=%d\n", count, min, max
      for (b in bucket) printf "  size %d-%d: %d\n", b, b + 99, bucket[b]
    }
  ' | sort -n -k2 2>/dev/null || true
}

analyze_awg() {
  local seconds="${1:-0}"
  local iface
  iface="$(cat "${STACK_DIR}/external-interface.txt" 2>/dev/null || true)"
  echo "AmneziaWG diagnostics"
  echo
  echo "Services:"
  systemctl is-active awg-quick@awg0.service 2>/dev/null | sed 's/^/  awg-quick@awg0 active: /' || true
  systemctl is-enabled awg-quick@awg0.service 2>/dev/null | sed 's/^/  awg-quick@awg0 enabled: /' || true
  systemctl is-active amneziawg-ensure-module.service 2>/dev/null | sed 's/^/  amneziawg-ensure-module active: /' || true
  echo
  echo "Kernel/module:"
  lsmod | awk '$1 ~ /^(amneziawg|wireguard)$/ {print "  " $0}' || true
  echo
  echo "Listening socket:"
  ss -lunp | awk '$5 ~ /:51820$/ {print "  " $0}' || true
  echo
  echo "Routing/sysctl:"
  printf '  net.ipv4.ip_forward = '; sysctl -n net.ipv4.ip_forward 2>/dev/null || true
  printf '  external interface = '; printf '%s\n' "${iface:-unknown}"
  echo
  echo "Firewall:"
  ufw status 2>/dev/null | sed 's/^/  /' || true
  iptables -t nat -S POSTROUTING 2>/dev/null | grep '10.66.66.0/24' | sed 's/^/  /' || true
  echo
  echo "AWG interface:"
  awg show awg0 2>/dev/null | sed 's/^/  /' || true
  echo
  echo "AWG obfuscation profile:"
  if [[ -f "${STACK_DIR}/awg-params.env" ]]; then
    grep -E '^AWG_(OBFS_PROFILE|JC|JMIN|JMAX|S[1-4]|H[1-4]|I[1-5])=' "${STACK_DIR}/awg-params.env" | sed 's/^/  /'
  else
    echo "  missing ${STACK_DIR}/awg-params.env"
  fi
  if [[ "${seconds}" =~ ^[0-9]+$ && "${seconds}" -gt 0 ]]; then
    echo
    capture_awg_udp "${seconds}"
  fi
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."
[[ $# -ge 1 ]] || { show_usage; exit 1; }
case "${1}" in
  -h|--help|help)
    show_usage
    exit 0
    ;;
  analyze|diagnose|diag)
    analyze_awg "${2:-0}"
    exit 0
    ;;
  capture|tcpdump)
    capture_awg_udp "${2:-20}"
    exit 0
    ;;
esac
[[ $# -eq 1 ]] || die "Usage: vpn-awg <name>"
name="$1"
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CONFIG}" ]] || die "Missing ${CONFIG}"
[[ -f "${STACK_DIR}/awg-params.env" ]] || die "Missing ${STACK_DIR}/awg-params.env"
label="$(label_name "AWG" "${name}")"
if [[ -f "${KEY_DIR}/${label}.conf" || -f "${KEY_DIR}/${name}.conf" ]]; then
  die "Client config already exists for: ${label}"
fi

# shellcheck disable=SC1091
source "${STACK_DIR}/awg-params.env"
domain="$(<"${STACK_DIR}/domain.txt")"
server_public="$(<"${STACK_DIR}/awg-server-public-key.txt")"
client_ip="$(next_ip)" || die "No free IP left in 10.66.66.0/24."
client_private="$(awg genkey)"
client_public="$(printf '%s\n' "${client_private}" | awg pubkey)"
psk="$(awg_genpsk)"

cat >>"${CONFIG}" <<EOF_PEER

[Peer]
PublicKey = ${client_public}
PresharedKey = ${psk}
AllowedIPs = ${client_ip}/32
EOF_PEER
chmod 0600 "${CONFIG}"

if awg show awg0 >/dev/null 2>&1; then
  psk_file="$(mktemp)"
  chmod 0600 "${psk_file}"
  printf '%s\n' "${psk}" >"${psk_file}"
  awg set awg0 peer "${client_public}" preshared-key "${psk_file}" allowed-ips "${client_ip}/32"
  rm -f "${psk_file}"
else
  systemctl restart awg-quick@awg0.service
fi

install -d -m 0700 "${KEY_DIR}"
out="${KEY_DIR}/${label}.conf"
cat >"${out}" <<EOF_CLIENT
# ${label}
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = 1.1.1.1, 8.8.8.8
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
I1 = ${AWG_I1}
I2 = ${AWG_I2}
I3 = ${AWG_I3}
I4 = ${AWG_I4}
I5 = ${AWG_I5}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${domain}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF_CLIENT
chmod 0600 "${out}"
printf 'Client: %s\n' "${label}"
print_qr "$(cat "${out}")"
printf 'Config:\n'
cat "${out}"
printf 'Saved: %s\n' "${out}"
EOF
  chmod 0755 /usr/local/bin/vpn-awg
}

install_helper_help() {
  cat >/usr/local/bin/vpn-help <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

show_key_if_exists() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    echo "No saved key yet: ${file}"
  fi
}

label_name() {
  local prefix="$1"
  local name="$2"
  if [[ "${name}" == "${prefix}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s' "${prefix}" "${name}"
  fi
}

proto="${1:-}"
name="${2:-}"

case "${proto}" in
  trojan|tls|xhttp)
    [[ -n "${name}" ]] && show_key_if_exists "/root/vpn-keys/trojan/$(label_name "TROJAN" "${name}").txt" && exit 0
    echo "Create: vpn-trojan <name>"
    exit 0
    ;;
  vless)
    echo "VLESS was replaced by Trojan XHTTP TLS."
    echo "Create: vpn-trojan <name>"
    exit 0
    ;;
  hysteria)
    [[ -n "${name}" ]] && show_key_if_exists "/root/vpn-keys/hysteria/$(label_name "HYSTERIA" "${name}").txt" && exit 0
    echo "Create: vpn-hysteria <name>"
    exit 0
    ;;
  awg)
    [[ -n "${name}" ]] && show_key_if_exists "/root/vpn-keys/awg/$(label_name "AWG" "${name}").conf" && exit 0
    echo "Create: vpn-awg <name>"
    exit 0
    ;;
esac

cat <<'HELP'
Golden VPN helper commands

Create clients:
  vpn-trojan phone1
  vpn-hysteria phone1
  vpn-awg phone1

AmneziaWG diagnostics:
  vpn-awg analyze
  vpn-awg analyze 20
  vpn-awg capture 30

Saved keys:
  /root/vpn-keys/trojan/TROJAN-<name>.txt
  /root/vpn-keys/hysteria/HYSTERIA-<name>.txt
  /root/vpn-keys/awg/AWG-<name>.conf

Show saved client material:
  vpn-help trojan phone1
  vpn-help tls phone1
  vpn-help xhttp phone1
  vpn-help hysteria phone1
  vpn-help awg phone1

Check services:
  systemctl status nginx --no-pager
  systemctl status xray-trojan-xhttp-tls --no-pager
  systemctl status hysteria2 --no-pager
  systemctl status awg-quick@awg0 --no-pager -l
  systemctl status prometheus --no-pager
  systemctl status prometheus-node-exporter --no-pager
  systemctl status grafana-server --no-pager

Grafana SSH tunnel:
  ssh -L 3000:127.0.0.1:3000 root@SERVER_IP
  Open http://localhost:3000
  Default login: admin / admin

Dashboard:
  Node Exporter Full dashboard ID 1860 is provisioned when download succeeds.
  Manual import path: Grafana -> Dashboards -> New -> Import -> 1860 -> datasource Prometheus
HELP
EOF
  chmod 0755 /usr/local/bin/vpn-help
}

install_helpers() {
  log "Installing helper commands."
  rm -f /usr/local/bin/vpn /usr/local/bin/vpn-vless /usr/local/bin/vpn-vless-xhttp /usr/local/bin/vpn-vless-reality
  install_helper_trojan
  install_helper_hysteria
  install_helper_awg
  install_helper_help
}

configure_monitoring() {
  log "Configuring Prometheus, Node Exporter, and Grafana localhost-only monitoring."

  cat >/etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090
  - job_name: node
    static_configs:
      - targets:
          - 127.0.0.1:9100
EOF
  chmod 0644 /etc/prometheus/prometheus.yml

  install -d -m 0755 /etc/systemd/system/prometheus.service.d
  cat >/etc/systemd/system/prometheus.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/metrics2 --web.console.templates=/usr/share/prometheus/consoles --web.console.libraries=/usr/share/prometheus/console_libraries --web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=7d --storage.tsdb.retention.size=1GB
EOF
  chmod 0644 /etc/systemd/system/prometheus.service.d/override.conf

  install -d -m 0755 /etc/systemd/system/prometheus-node-exporter.service.d
  cat >/etc/systemd/system/prometheus-node-exporter.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=127.0.0.1:9100
EOF
  chmod 0644 /etc/systemd/system/prometheus-node-exporter.service.d/override.conf

  if [[ -f /etc/grafana/grafana.ini ]]; then
    sed -i -E 's/^[;[:space:]]*http_addr[[:space:]]*=.*/http_addr = 127.0.0.1/' /etc/grafana/grafana.ini
    sed -i -E 's/^[;[:space:]]*http_port[[:space:]]*=.*/http_port = 3000/' /etc/grafana/grafana.ini
  fi

  install -d -m 0755 /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
  cat >/etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: true
EOF
  chmod 0644 /etc/grafana/provisioning/datasources/prometheus.yaml

  cat >/etc/grafana/provisioning/dashboards/node-exporter-full.yaml <<'EOF'
apiVersion: 1

providers:
  - name: Node Exporter Full
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 60
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF
  chmod 0644 /etc/grafana/provisioning/dashboards/node-exporter-full.yaml

  if curl -fsSL https://grafana.com/api/dashboards/1860/revisions/latest/download \
    -o /var/lib/grafana/dashboards/node-exporter-full-1860.json; then
    chmod 0644 /var/lib/grafana/dashboards/node-exporter-full-1860.json
    chown -R grafana:grafana /var/lib/grafana/dashboards || true
  else
    warn "Could not download Grafana dashboard 1860; vpn-help includes manual import instructions."
  fi
}

configure_log_limits() {
  log "Configuring log retention limits."
  install -d -m 0755 /etc/systemd/journald.conf.d "${LOG_DIR}"
  cat >/etc/systemd/journald.conf.d/limits.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF
  chmod 0644 /etc/systemd/journald.conf.d/limits.conf

  cat >/etc/logrotate.d/vpn-stack <<'EOF'
/var/log/vpn-stack/*.log /var/log/vpn-soft-reboot.log /var/log/vpn-stack-healthcheck.log {
    daily
    rotate 7
    compress
    copytruncate
    missingok
    notifempty
}
EOF
  chmod 0644 /etc/logrotate.d/vpn-stack
}

configure_timers() {
  log "Configuring soft reboot and boot healthcheck timers."

  cat >/usr/local/sbin/vpn-soft-reboot.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s soft reboot requested\n' "$(date -Is)" >>/var/log/vpn-soft-reboot.log
systemctl reboot
EOF
  chmod 0755 /usr/local/sbin/vpn-soft-reboot.sh

  cat >/etc/systemd/system/vpn-soft-reboot.service <<'EOF'
[Unit]
Description=Daily soft reboot for VPN stack

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-soft-reboot.sh
EOF
  chmod 0644 /etc/systemd/system/vpn-soft-reboot.service

  cat >/etc/systemd/system/vpn-soft-reboot.timer <<'EOF'
[Unit]
Description=Run VPN soft reboot daily at 04:00 Europe/Moscow

[Timer]
OnCalendar=*-*-* 04:00:00 Europe/Moscow
Persistent=false
Unit=vpn-soft-reboot.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-soft-reboot.timer

  cat >/usr/local/sbin/vpn-stack-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file="/var/log/vpn-stack-healthcheck.log"
services=(
  nginx
  xray-trojan-xhttp-tls
  hysteria2
  prometheus
  prometheus-node-exporter
  grafana-server
  amneziawg-ensure-module
  awg-quick@awg0
)

printf '%s healthcheck start\n' "$(date -Is)" >>"${log_file}"
for svc in "${services[@]}"; do
  if ! systemctl is-active --quiet "${svc}"; then
    printf '%s restarting %s\n' "$(date -Is)" "${svc}" >>"${log_file}"
    systemctl restart "${svc}" >>"${log_file}" 2>&1 || true
  fi
done
printf '%s healthcheck done\n' "$(date -Is)" >>"${log_file}"
EOF
  chmod 0755 /usr/local/sbin/vpn-stack-healthcheck.sh

  cat >/etc/systemd/system/vpn-stack-healthcheck.service <<'EOF'
[Unit]
Description=VPN stack boot healthcheck
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-stack-healthcheck.sh
EOF
  chmod 0644 /etc/systemd/system/vpn-stack-healthcheck.service

  cat >/etc/systemd/system/vpn-stack-healthcheck.timer <<'EOF'
[Unit]
Description=Run VPN stack healthcheck after boot

[Timer]
OnBootSec=2min
Persistent=false
Unit=vpn-stack-healthcheck.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-stack-healthcheck.timer
}

enable_and_start_services() {
  log "Enabling and starting services."
  systemctl daemon-reload

  systemctl enable nginx
  systemctl enable xray-trojan-xhttp-tls
  systemctl enable hysteria2
  systemctl enable amneziawg-ensure-module
  systemctl enable awg-quick@awg0
  systemctl enable prometheus
  systemctl enable prometheus-node-exporter
  systemctl enable grafana-server
  systemctl enable vpn-soft-reboot.timer
  systemctl enable vpn-stack-healthcheck.timer

  systemctl restart systemd-journald || true
  systemctl restart xray-trojan-xhttp-tls
  systemctl restart nginx
  systemctl restart hysteria2
  systemctl restart amneziawg-ensure-module
  systemctl restart awg-quick@awg0
  systemctl restart prometheus
  systemctl restart prometheus-node-exporter
  systemctl restart grafana-server
  systemctl restart vpn-soft-reboot.timer
  systemctl restart vpn-stack-healthcheck.timer
}

service_summary() {
  local unit="$1"
  local active enabled
  active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
  [[ -n "${active}" ]] || active="unknown"
  [[ -n "${enabled}" ]] || enabled="unknown"
  printf '%s/%s' "${active}" "${enabled}"
}

listen_any_port() {
  local proto="$1"
  local port="$2"
  ss -H -lntup 2>/dev/null | awk -v proto="${proto}" -v port=":${port}" \
    'tolower($1) == proto && $5 ~ (port "$") { found=1 } END { exit found ? 0 : 1 }'
}

listen_local_port() {
  local proto="$1"
  local port="$2"
  ss -H -lntup 2>/dev/null | awk -v proto="${proto}" -v port=":${port}" '
    tolower($1) == proto && ($5 == "127.0.0.1" port || $5 == "[::1]" port) { found=1 }
    END { exit found ? 0 : 1 }
  '
}

listen_label() {
  local scope="$1"
  local proto="$2"
  local port="$3"
  if [[ "${scope}" == "local" ]]; then
    if listen_local_port "${proto}" "${port}"; then
      printf 'OK'
    else
      printf 'MISSING'
    fi
  else
    if listen_any_port "${proto}" "${port}"; then
      printf 'OK'
    else
      printf 'MISSING'
    fi
  fi
}

socket_label() {
  local path="$1"
  if [[ -S "${path}" ]]; then
    printf 'OK'
  else
    printf 'MISSING'
  fi
}

wait_for_expected_listeners() {
  local timeout="${1:-90}"
  local deadline=$((SECONDS + timeout))
  local -a missing

  log "Waiting up to ${timeout}s for expected listening ports."
  while true; do
    missing=()

    listen_any_port tcp 443 || missing+=("443/tcp")
    listen_any_port udp 8443 || missing+=("8443/udp")
    listen_any_port udp 51820 || missing+=("51820/udp")
    [[ -S "${TROJAN_XHTTP_SOCKET}" ]] || missing+=("${TROJAN_XHTTP_SOCKET}")
    listen_local_port tcp 3000 || missing+=("127.0.0.1:3000")
    listen_local_port tcp 9090 || missing+=("127.0.0.1:9090")
    listen_local_port tcp 9100 || missing+=("127.0.0.1:9100")

    if ((${#missing[@]} == 0)); then
      log "All expected listening ports are up."
      return 0
    fi

    if ((SECONDS >= deadline)); then
      warn "Timed out waiting for listening ports: ${missing[*]}"
      return 0
    fi

    sleep 2
  done
}

print_install_summary() {
  local dashboard_status
  if [[ -s /var/lib/grafana/dashboards/node-exporter-full-1860.json ]]; then
    dashboard_status="provisioned from local JSON"
  else
    dashboard_status="not provisioned; import dashboard ID 1860 manually"
  fi

  cat <<EOF

============================================================
Golden VPN stack summary
============================================================
Domain: ${DOMAIN}
Server IPv4: ${PUBLIC_IPV4}
External interface: ${EXT_IFACE}

Contours:
  Trojan XHTTP TLS   : service $(service_summary xray-trojan-xhttp-tls); external 443/tcp via nginx $(listen_label any tcp 443); backend ${TROJAN_XHTTP_SOCKET} $(socket_label "${TROJAN_XHTTP_SOCKET}")
  Hysteria2 Salamander: service $(service_summary hysteria2); external 8443/udp $(listen_label any udp 8443)
  AmneziaWG 2.0       : service $(service_summary awg-quick@awg0); external 51820/udp $(listen_label any udp 51820); interface awg0
  Decoy HTTPS site    : nginx $(service_summary nginx); https://${DOMAIN}/; randomized static site on 443/tcp

Monitoring, localhost only:
  Grafana       : service $(service_summary grafana-server); 127.0.0.1:3000 $(listen_label local tcp 3000)
  Prometheus    : service $(service_summary prometheus); 127.0.0.1:9090 $(listen_label local tcp 9090)
  Node Exporter : service $(service_summary prometheus-node-exporter); 127.0.0.1:9100 $(listen_label local tcp 9100)
  Dashboard 1860: ${dashboard_status}

Grafana SSH tunnel:
  ssh -L 3000:127.0.0.1:3000 root@${PUBLIC_IPV4}
  Open: http://localhost:3000
  Default login: admin / admin

AmneziaWG diagnostics:
  Obfuscation profile: $(grep -E '^AWG_OBFS_PROFILE=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')
  Full status: vpn-awg analyze
  Status + short sniff: vpn-awg analyze 20
  Save pcap: vpn-awg capture 30

Swap:
  Install decision: ${SWAP_RESULT}
EOF

  if swapon --show | awk 'NR>1 {found=1} END {exit found ? 0 : 1}'; then
    swapon --show
  else
    printf '  Active swap: none\n'
  fi

  cat <<EOF

Storage limits:
  journald: /etc/systemd/journald.conf.d/limits.conf
  logrotate: /etc/logrotate.d/vpn-stack
  Prometheus retention: 7d / 1GB

Initial client files:
  ${KEY_DIR}/trojan/TROJAN-main-trojan.txt
  ${KEY_DIR}/hysteria/HYSTERIA-main-hysteria-client.txt
  ${KEY_DIR}/awg/AWG-main-awg.conf

Create more clients:
  vpn-trojan phone1
  vpn-hysteria phone1
  vpn-awg phone1
  vpn-help
============================================================
EOF
}

final_checks() {
  log "Final listening socket check."
  set +e
  ss -lntup | grep -E ':443|:8443|:51820|:3000|:9090|:9100'
  ls -l "${TROJAN_XHTTP_SOCKET}"

  systemctl status nginx --no-pager
  systemctl status xray-trojan-xhttp-tls --no-pager
  systemctl status hysteria2 --no-pager
  systemctl status awg-quick@awg0 --no-pager -l
  systemctl status prometheus --no-pager
  systemctl status prometheus-node-exporter --no-pager
  systemctl status grafana-server --no-pager

  curl -vk "https://${DOMAIN}/"
  vpn-help
  set -e

  log "Initial client files:"
  printf '  %s\n' \
    "${KEY_DIR}/trojan/TROJAN-main-trojan.txt" \
    "${KEY_DIR}/hysteria/HYSTERIA-main-hysteria-client.txt" \
    "${KEY_DIR}/awg/AWG-main-awg.conf"
  log "Optional helper smoke tests create extra clients:"
  printf '  vpn-trojan test-trojan\n  vpn-hysteria test-hy2\n  vpn-awg test-awg\n'
  print_install_summary
}

main() {
  progress "Checking input variables and kernel readiness"
  require_root_and_env
  check_dkms_kernel_ready
  progress "Installing APT repositories"
  install_apt_repositories
  progress "Installing base packages"
  install_base_packages
  progress "Checking required commands"
  need_command ip
  need_command getent
  need_command curl
  need_command jq
  need_command openssl
  progress "Detecting server network"
  detect_public_ipv4
  detect_external_iface
  progress "Verifying DNS"
  verify_domain_dns
  progress "Issuing TLS certificate"
  install_acme_certificate
  progress "Installing Xray"
  install_xray
  progress "Configuring Trojan XHTTP TLS"
  configure_xray
  progress "Configuring nginx decoy and router"
  configure_nginx
  progress "Installing Hysteria2"
  install_hysteria
  progress "Configuring Hysteria2"
  configure_hysteria
  progress "Installing AmneziaWG"
  install_amneziawg
  progress "Configuring AmneziaWG"
  configure_amneziawg
  progress "Configuring swap"
  configure_swap
  progress "Configuring firewall"
  configure_firewall
  progress "Installing VPN helper commands"
  install_helpers
  progress "Configuring monitoring"
  configure_monitoring
  progress "Configuring log retention"
  configure_log_limits
  progress "Configuring timers"
  configure_timers
  progress "Enabling and starting services"
  enable_and_start_services
  progress "Waiting for listeners"
  wait_for_expected_listeners 90
  progress "Running final checks"
  final_checks
  progress "Cleaning one-time resume state"
  cleanup_resume_install_state
  progress "Installation complete"
  log "Golden VPN stack installation complete."
}

run_with_install_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 200>"${INSTALL_LOCK}"
    if ! flock -n 200; then
      warn "Another Golden VPN installation is already running."
      warn "Do not start a second installer while apt/dpkg is active."
      if [[ -x "${INSTALL_STATUS_HELPER}" ]]; then
        warn "Watch progress with: vpn-install-status follow"
      else
        warn "Watch progress with: journalctl -fu ${RESUME_INSTALL_SERVICE}"
        warn "Or: tail -f ${RESUME_INSTALL_LOG}"
      fi
      exit 75
    fi
  else
    warn "flock is not available; continuing without installer concurrency guard."
  fi

  main "$@"
}

run_with_install_lock "$@"
