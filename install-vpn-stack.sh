#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
export APT_LISTCHANGES_FRONTEND="${APT_LISTCHANGES_FRONTEND:-none}"

: "${APT_LOCK_TIMEOUT:=1800}"

STACK_DIR="/opt/vpn-stack"
KEY_DIR="/root/vpn-keys"
XRAY_DIR="${STACK_DIR}/xray"
HYSTERIA_DIR="${STACK_DIR}/hysteria"
LOG_DIR="/var/log/vpn-stack"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN:-}"
SUBSCRIPTION_DIR="${STACK_DIR}/subscriptions"
SUBSCRIPTION_WEB_DIR="/var/www/subscriptions"
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
INSTALL_REPORT_TXT="${KEY_DIR}/install-report.txt"
INSTALL_REPORT_JSON="${KEY_DIR}/install-report.json"
DECOY_MANIFEST="${STACK_DIR}/decoy-manifest.json"
AWG_TUNING_REPORT="${STACK_DIR}/awg-tuning-report.json"
AWG_DEFAULT_PORT=51820
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
  iproute2
  iputils-ping
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

BOOTSTRAP_PACKAGES=(
  curl
  wget
  ca-certificates
  openssh-server
  ufw
  gnupg
  lsb-release
  iproute2
  iptables
  psmisc
  software-properties-common
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

package_lock_holders() {
  local lock

  command -v fuser >/dev/null 2>&1 || return 0

  for lock in \
    /var/lib/dpkg/lock-frontend \
    /var/lib/dpkg/lock \
    /var/cache/apt/archives/lock \
    /var/lib/apt/lists/lock; do
    [[ -e "${lock}" ]] || continue
    (fuser "${lock}" 2>/dev/null || true) | tr ' ' '\n' | awk 'NF'
  done | sort -n -u
}

describe_package_lock_holders() {
  local pids pid_csv
  mapfile -t pids < <(package_lock_holders)
  [[ "${#pids[@]}" -gt 0 ]] || return 0

  pid_csv="$(IFS=,; printf '%s' "${pids[*]}")"
  ps -o pid,ppid,stat,etime,cmd -p "${pid_csv}" 2>/dev/null || true
}

wait_for_package_locks() {
  local start now elapsed timeout next_log pids
  timeout="${APT_LOCK_TIMEOUT:-1800}"
  start="$(date +%s)"
  next_log=0

  command -v fuser >/dev/null 2>&1 || return 0

  while true; do
    mapfile -t pids < <(package_lock_holders)
    [[ "${#pids[@]}" -gt 0 ]] || return 0

    now="$(date +%s)"
    elapsed=$((now - start))
    if ((elapsed >= timeout)); then
      warn "Timed out after ${timeout}s waiting for apt/dpkg locks."
      describe_package_lock_holders >&2
      return 1
    fi

    if ((elapsed >= next_log)); then
      warn "Waiting for first-boot apt/dpkg work to finish (${elapsed}/${timeout}s). Lock holders:"
      describe_package_lock_holders >&2
      next_log=$((elapsed + 30))
    fi

    sleep 5
  done
}

apt_get() {
  wait_for_package_locks
  apt-get -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT:-1800}" "$@"
}

progress() {
  local message="$1"
  local width=24
  local filled empty percent bar color reset tty_lines

  INSTALL_STEP=$((INSTALL_STEP + 1))
  if [[ "${INSTALL_STEP}" -gt "${INSTALL_TOTAL_STEPS}" ]]; then
    INSTALL_STEP="${INSTALL_TOTAL_STEPS}"
  fi

  percent=$((INSTALL_STEP * 100 / INSTALL_TOTAL_STEPS))
  filled=$((INSTALL_STEP * width / INSTALL_TOTAL_STEPS))
  empty=$((width - filled))
  bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')$(printf '%*s' "${empty}" '' | tr ' ' '-')"
  log "[${bar}] ${percent}% (${INSTALL_STEP}/${INSTALL_TOTAL_STEPS}) ${message}"

  if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
    if ((percent < 34)); then
      color=$'\033[31m'
    elif ((percent < 67)); then
      color=$'\033[33m'
    else
      color=$'\033[32m'
    fi
    reset=$'\033[0m'
    tty_lines="$(tput lines 2>/dev/null || printf '999')"
    printf '\0337\033[%s;1H\033[2K%s[%s]%s %s%% (%s/%s) %s\0338' \
      "${tty_lines}" "${color}" "${bar}" "${reset}" "${percent}" "${INSTALL_STEP}" "${INSTALL_TOTAL_STEPS}" "${message}"
  fi

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

valid_ascii_email() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]
}

normalize_server_location() {
  local value="$1"
  value="$(trim_value "${value}")"
  value="$(printf '%s' "${value}" | tr '[:lower:]' '[:upper:]')"
  printf '%s' "${value}"
}

valid_server_location() {
  local value="$1"
  [[ "${value}" =~ ^[A-Z]{2}$ ]]
}

ensure_valid_server_location() {
  while true; do
    SERVER_LOCATION="$(normalize_server_location "${SERVER_LOCATION:-}")"
    export SERVER_LOCATION

    if valid_server_location "${SERVER_LOCATION}"; then
      return 0
    fi

    if have_tty; then
      printf 'SERVER_LOCATION must be exactly two ASCII letters, example EE, NL, DE.\n' >/dev/tty
      unset SERVER_LOCATION
      prompt_required_var SERVER_LOCATION "SERVER_LOCATION, two letters, example EE"
    else
      die "SERVER_LOCATION must be exactly two ASCII letters, example EE, NL, DE."
    fi
  done
}

ensure_valid_email() {
  while true; do
    EMAIL="$(trim_value "${EMAIL:-}")"
    export EMAIL

    if valid_ascii_email "${EMAIL}"; then
      return 0
    fi

    if have_tty; then
      printf 'EMAIL must be plain ASCII, example user@example.com. Non-ASCII or hidden characters are not accepted.\n' >/dev/tty
      unset EMAIL
      prompt_required_var EMAIL "EMAIL for ACME, ASCII only, example user@example.com"
    else
      die "EMAIL must be plain ASCII, example user@example.com. Current EMAIL contains invalid or non-ASCII characters."
    fi
  done
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

prompt_yes_no_default_no() {
  local prompt="$1"
  local answer

  have_tty || return 1
  while true; do
    printf '%s [y/N]: ' "${prompt}" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    answer="$(trim_value "${answer}")"
    case "${answer}" in
      ""|n|N|no|NO|No)
        return 1
        ;;
      y|Y|yes|YES|Yes)
        return 0
        ;;
      *)
        printf 'Please answer y or n.\n' >/dev/tty
        ;;
    esac
  done
}

prompt_optional_var() {
  local var="$1"
  local label="$2"
  local default_value="$3"
  local value

  [[ -z "${!var:-}" ]] || return 0
  have_tty || return 0

  printf '%s [%s]: ' "${label}" "${default_value}" >/dev/tty
  IFS= read -r value </dev/tty || return 0
  value="$(trim_value "${value}")"
  [[ -n "${value}" ]] || value="${default_value}"
  printf -v "${var}" '%s' "${value}"
  export "${var}"
}

prompt_advanced_tuning() {
  [[ "${VPN_STACK_ASSUME_DEFAULTS:-0}" != "1" ]] || return 0
  [[ "${VPN_STACK_RESUMED:-0}" != "1" ]] || return 0
  prompt_yes_no_default_no "Advanced tuning?" || return 0

  prompt_optional_var AWG_OBFS_PROFILE "AWG_OBFS_PROFILE" "${AWG_OBFS_PROFILE:-random-balanced}"
  prompt_optional_var AWG_MTU "AWG_MTU" "${AWG_MTU:-auto}"
  prompt_optional_var DECOY_PROFILE "DECOY_PROFILE" "${DECOY_PROFILE:-random}"
  prompt_optional_var DECOY_SEED "DECOY_SEED" "${DECOY_SEED:-}"
}

require_root_and_env() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
  load_saved_resume_env
  prompt_required_var DOMAIN "DOMAIN, without https://, example s5.example.com"
  prompt_required_var EMAIL "EMAIL for ZeroSSL/acme.sh"
  ensure_valid_email
  prompt_required_var SERVER_LOCATION "SERVER_LOCATION, two letters, example EE"
  ensure_valid_server_location
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
  if [[ "${VPN_STACK_IGNORE_SAVED_ENV:-0}" == "1" ]]; then
    log "Ignoring saved installer environment because VPN_STACK_IGNORE_SAVED_ENV=1."
    return 0
  fi

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
    printf 'SERVER_LOCATION=%q\n' "${SERVER_LOCATION}"
    printf 'CF_Token=%q\n' "${CF_Token}"
    [[ -n "${CF_Zone_ID:-}" ]] && printf 'CF_Zone_ID=%q\n' "${CF_Zone_ID}"
    [[ -n "${CF_Account_ID:-}" ]] && printf 'CF_Account_ID=%q\n' "${CF_Account_ID}"
    [[ -n "${ZEROSSL_EAB_KID:-}" ]] && printf 'ZEROSSL_EAB_KID=%q\n' "${ZEROSSL_EAB_KID}"
    [[ -n "${ZEROSSL_EAB_HMAC_KEY:-}" ]] && printf 'ZEROSSL_EAB_HMAC_KEY=%q\n' "${ZEROSSL_EAB_HMAC_KEY}"
    [[ -n "${VPN_STACK_DISABLE_LE_FALLBACK:-}" ]] && printf 'VPN_STACK_DISABLE_LE_FALLBACK=%q\n' "${VPN_STACK_DISABLE_LE_FALLBACK}"
    [[ -n "${VPN_STACK_NO_AUTO_REBOOT:-}" ]] && printf 'VPN_STACK_NO_AUTO_REBOOT=%q\n' "${VPN_STACK_NO_AUTO_REBOOT}"
    [[ -n "${VPN_STACK_ALLOW_REBOOT_PROMPT:-}" ]] && printf 'VPN_STACK_ALLOW_REBOOT_PROMPT=%q\n' "${VPN_STACK_ALLOW_REBOOT_PROMPT}"
    for opt in \
      AWG_OBFS_PROFILE AWG_MTU AWG_DNS AWG_ALLOWED_IPS AWG_KEEPALIVE AWG_ENDPOINT_PORT \
      AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 \
      AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5 \
      DECOY_PROFILE DECOY_SEED DECOY_BRAND DECOY_REGION; do
      [[ -n "${!opt:-}" ]] && printf '%s=%q\n' "${opt}" "${!opt}"
    done
    printf 'VPN_STACK_RESUMED=1\n'
    printf 'DEBIAN_FRONTEND=noninteractive\n'
  } >"${RESUME_INSTALL_ENV}"
  chmod 0600 "${RESUME_INSTALL_ENV}"
}

ensure_ssh_firewall_access() {
  local mode="${1:-best-effort}"
  local ssh_port current_ssh_port="" listener_ok=0 had_errexit=0 had_errtrace=0 old_err_trap

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    current_ssh_port="$(awk '{print $4}' <<<"${SSH_CONNECTION}" 2>/dev/null || true)"
  fi
  old_err_trap="$(trap -p ERR || true)"
  case $- in
    *e*)
      had_errexit=1
      ;;
  esac
  case $- in
    *E*)
      had_errtrace=1
      ;;
  esac
  set +e
  set +E
  trap - ERR

  log "Ensuring SSH remains reachable before firewall/reboot changes."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp comment 'SSH default' || true
    ufw allow OpenSSH || true

    if [[ "${current_ssh_port}" =~ ^[0-9]+$ ]]; then
      ufw allow "${current_ssh_port}/tcp" comment 'Current SSH session' || true
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
    apt_get update >/dev/null 2>&1 || true
    apt_get install -y openssh-server >/dev/null 2>&1 || true
  fi

  ssh-keygen -A >/dev/null 2>&1 || true
  systemctl unmask ssh sshd ssh.service sshd.service ssh.socket >/dev/null 2>&1 || true
  systemctl enable --now ssh.service >/dev/null 2>&1 \
    || systemctl enable --now sshd.service >/dev/null 2>&1 \
    || systemctl enable --now ssh.socket >/dev/null 2>&1 \
    || true
  systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart sshd.service >/dev/null 2>&1 || true

  if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:22[[:space:]]'; then
    listener_ok=1
  elif [[ "${current_ssh_port}" =~ ^[0-9]+$ ]] && ss -lntp 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]*:${current_ssh_port}[[:space:]]"; then
    listener_ok=1
  fi

  if [[ -n "${old_err_trap}" ]]; then
    eval "${old_err_trap}"
  else
    trap - ERR
  fi
  [[ "${had_errtrace}" == "1" ]] && set -E
  [[ "${had_errexit}" == "1" ]] && set -e
  if [[ "${mode}" == "require-listener" && "${listener_ok}" != "1" ]]; then
    warn "SSH daemon is not listening on 22/tcp or the current SSH session port; refusing automatic reboot."
    return 1
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
set -u

log_file="/var/log/vpn-stack-ssh-guard.log"
current_ssh_port="${current_ssh_port}"

apt_get() {
  apt-get -o DPkg::Lock::Timeout="\${APT_LOCK_TIMEOUT:-600}" "\$@"
}

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
    apt_get update || true
    apt_get install -y openssh-server || true
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
Wants=network-online.target
After=network-online.target
Before=${RESUME_INSTALL_SERVICE}

[Service]
Type=oneshot
ExecStart=${SSH_GUARD_SCRIPT}
TimeoutStartSec=5min

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${SSH_GUARD_UNIT}"

  systemctl daemon-reload
  systemctl enable "${SSH_GUARD_SERVICE}" >/dev/null 2>&1 || true
}

install_resume_status_helper() {
  cat >"${INSTALL_STATUS_HELPER}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

service="vpn-stack-resume-install.service"
timer="vpn-stack-resume-install.timer"
log_file="/var/log/vpn-stack-resume-install.log"
progress_file="/var/log/vpn-stack/install-progress.env"
lock_file="/run/golden-vpn-install.lock"

load_progress() {
  STEP="?"
  TOTAL="?"
  PERCENT="?"
  MESSAGE="waiting for installer"
  UPDATED_AT="unknown"
  if [[ -r "${progress_file}" ]]; then
    # shellcheck disable=SC1090
    source "${progress_file}" || true
  fi
}

render_bar() {
  local width=28 filled empty bar color reset
  load_progress
  if [[ "${PERCENT}" =~ ^[0-9]+$ ]]; then
    filled=$((PERCENT * width / 100))
  else
    filled=0
  fi
  ((filled > width)) && filled="${width}"
  empty=$((width - filled))
  bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')$(printf '%*s' "${empty}" '' | tr ' ' '-')"
  if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
    if [[ "${PERCENT}" =~ ^[0-9]+$ ]] && ((PERCENT >= 67)); then
      color=$'\033[32m'
    elif [[ "${PERCENT}" =~ ^[0-9]+$ ]] && ((PERCENT >= 34)); then
      color=$'\033[33m'
    else
      color=$'\033[31m'
    fi
    reset=$'\033[0m'
    printf '%s[%s]%s %s%% (%s/%s) %s\n' "${color}" "${bar}" "${reset}" "${PERCENT}" "${STEP}" "${TOTAL}" "${MESSAGE}"
  else
    printf '[%s] %s%% (%s/%s) %s\n' "${bar}" "${PERCENT}" "${STEP}" "${TOTAL}" "${MESSAGE}"
  fi
}

show_status() {
  echo "Golden VPN installer status"
  echo
  render_bar
  printf 'Updated: %s\n\n' "${UPDATED_AT:-unknown}"
  systemctl status "${service}" --no-pager -l || true
  echo
  systemctl list-timers "${timer}" --no-pager || true
  echo
  if command -v fuser >/dev/null 2>&1 && fuser "${lock_file}" >/dev/null 2>&1; then
    echo "Installer lock is held: another install/resume run is active."
  fi
  echo
  if [[ -r "${log_file}" ]]; then
    echo "Last log lines:"
    tail -n 80 "${log_file}" || true
  else
    echo "No log file yet: ${log_file}"
  fi
}

watch_status() {
  local lines="${1:-22}"
  [[ "${lines}" =~ ^[0-9]+$ ]] || lines=22
  if [[ ! -t 1 || "${TERM:-}" == "dumb" ]]; then
    show_status
    [[ -r "${log_file}" ]] && tail -f "${log_file}"
    exit 0
  fi

  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true; printf "\n"' EXIT INT TERM
  while true; do
    clear
    echo "Golden VPN installer watch"
    echo
    render_bar
    printf 'Updated: %s\n' "${UPDATED_AT:-unknown}"
    printf 'Service: '
    systemctl is-active "${service}" 2>/dev/null || true
    printf 'Log: %s\n\n' "${log_file}"
    if [[ -r "${log_file}" ]]; then
      tail -n "${lines}" "${log_file}" || true
    else
      echo "Waiting for log file..."
    fi
    sleep 1
  done
}

case "${1:-status}" in
  watch|-w)
    watch_status "${2:-22}"
    ;;
  follow|-f)
    echo "Following ${service}. Press Ctrl+C to stop watching."
    journalctl -fu "${service}"
    ;;
  log)
    tail -n "${2:-200}" "${log_file}" || true
    ;;
  status|"")
    show_status
    ;;
  *)
    echo "Usage: vpn-install-status [status|watch [lines]|follow|log [lines]]" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "${INSTALL_STATUS_HELPER}"
}

cleanup_resume_install_state() {
  local had_state=0
  for path in "${RESUME_INSTALL_UNIT}" "${RESUME_INSTALL_TIMER_UNIT}" "${RESUME_INSTALL_RUNNER}" "${RESUME_INSTALL_SCRIPT}" "${RESUME_INSTALL_ENV}" "${SSH_GUARD_UNIT}" "${SSH_GUARD_SCRIPT}"; do
    [[ -e "${path}" ]] && had_state=1
  done

  systemctl disable "${RESUME_INSTALL_SERVICE}" "${RESUME_INSTALL_TIMER}" "${SSH_GUARD_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${RESUME_INSTALL_UNIT}" "${RESUME_INSTALL_TIMER_UNIT}" "${RESUME_INSTALL_RUNNER}" "${RESUME_INSTALL_SCRIPT}" "${RESUME_INSTALL_ENV}" "${SSH_GUARD_UNIT}" "${SSH_GUARD_SCRIPT}"
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
  ensure_ssh_firewall_access require-listener || die "SSH listener check failed before reboot. Start openssh-server manually, then rerun the installer."

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
printf 'Use "vpn-install-status watch" to watch this installation.\n'
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
bash "\${installer}" install
status="\$?"
set -e

if [[ "\${status}" -eq 0 ]]; then
  printf '%s resume install succeeded; removing one-time unit and saved env\n' "\$(date -Is)"
  systemctl disable "\${service}" "\${timer}" "\${ssh_guard_service}" >/dev/null 2>&1 || true
  rm -f "\${unit}" "\${timer_unit}" "\${env_file}" "\${installer}" "\${runner}" "\${ssh_guard_unit}" "\${ssh_guard_script}"
  rmdir "\${resume_dir}" 2>/dev/null || true
  rmdir "\${env_dir}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
else
  printf '%s resume install failed; disabling one-time unit and keeping env/log for manual retry\n' "\$(date -Is)"
  systemctl disable "\${service}" "\${timer}" "\${ssh_guard_service}" >/dev/null 2>&1 || true
  rm -f "\${unit}" "\${timer_unit}" "\${runner}" "\${ssh_guard_unit}" "\${ssh_guard_script}"
  systemctl daemon-reload >/dev/null 2>&1 || true
  printf 'Saved env: %s\n' "\${env_file}"
  printf 'Saved installer copy: %s\n' "\${installer}"
  printf 'Manual retry: bash %s install\n' "\${installer}"
fi

printf '%s resume exit status=%s\n' "\$(date -Is)" "\${status}"
exit "\${status}"
EOF
  chmod 0700 "${RESUME_INSTALL_RUNNER}"

  cat >"${RESUME_INSTALL_UNIT}" <<EOF
[Unit]
Description=Resume Golden VPN installer once after reboot
After=network-online.target ${SSH_GUARD_SERVICE} ssh.service sshd.service ssh.socket
Wants=network-online.target ${SSH_GUARD_SERVICE}
ConditionPathExists=${RESUME_INSTALL_SCRIPT}
ConditionPathExists=${RESUME_INSTALL_ENV}

[Service]
Type=oneshot
EnvironmentFile=${RESUME_INSTALL_ENV}
ExecStartPre=/bin/sleep 30
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
OnBootSec=2min
AccuracySec=15s
Persistent=false
Unit=${RESUME_INSTALL_SERVICE}

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "${RESUME_INSTALL_TIMER_UNIT}"

  systemctl daemon-reload
  systemctl enable "${RESUME_INSTALL_TIMER}"
  log "One-time resume service installed for timer start only: ${RESUME_INSTALL_SERVICE}"
  log "One-time resume timer installed: ${RESUME_INSTALL_TIMER}"
  log "SSH guard installed for the reboot: ${SSH_GUARD_SERVICE}"
  log "Resume env saved: ${RESUME_INSTALL_ENV}"
  log "Resume log after reboot: ${RESUME_INSTALL_LOG}"
  log "Resume journal after reboot: journalctl -u ${RESUME_INSTALL_SERVICE} -b --no-pager"
  log "Resume timer after reboot: systemctl list-timers ${RESUME_INSTALL_TIMER} --no-pager"
  log "Live resume output after reboot: vpn-install-status watch"
}

auto_reboot_resume_enabled() {
  [[ "${VPN_STACK_NO_AUTO_REBOOT:-0}" != "1" ]] \
    && [[ "${VPN_STACK_AUTO_REBOOT_RESUME:-}" == "1" || "${AUTO_REBOOT_RESUME:-}" == "1" ]]
}

reboot_prompt_enabled() {
  [[ "${VPN_STACK_NO_AUTO_REBOOT:-0}" != "1" ]] && [[ "${VPN_STACK_ALLOW_REBOOT_PROMPT:-0}" == "1" ]]
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

    if [[ "${mode}" == "prompt" && "${DKMS_KERNEL_REBOOT_PROMPTED}" != "1" && reboot_prompt_enabled ]]; then
      DKMS_KERNEL_REBOOT_PROMPTED=1
      if prompt_yes_no "Reboot now and resume installer once after boot?"; then
        schedule_resume_install_once
        log "Rebooting now. The installer will continue once after the VPS comes back."
        systemctl reboot
        exit 0
      fi
    else
      warn "Kernel reboot is required before AmneziaWG DKMS can continue."
    fi

    cat >&2 <<EOF

[vpn-stack] Automatic reboot/resume is disabled by default to avoid losing SSH access.
[vpn-stack] Reboot manually, then run the installer again from Git after SSH is reachable:

  reboot

After the VPS comes back:

  export VPN_STACK_NO_AUTO_REBOOT=1
  ./install-vpn-stack.sh

If you really want the old interactive reboot/resume prompt, set:

  export VPN_STACK_ALLOW_REBOOT_PROMPT=1

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
  apt_get update
  apt_get install -y apt-transport-https curl wget ca-certificates gnupg lsb-release iproute2 software-properties-common

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

  apt_get update
}

install_bootstrap_packages() {
  log "Installing bootstrap packages only."
  apt_get update
  apt_get install -y "${BOOTSTRAP_PACKAGES[@]}"
}

install_base_packages() {
  log "Installing base packages."
  apt_get install -y "${BASE_PACKAGES[@]}" software-properties-common python3-launchpadlib
  apt_get install -y "linux-headers-$(uname -r)" || warn "linux-headers-$(uname -r) was not installable; AmneziaWG DKMS may need manual kernel headers."
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

json_escape() {
  local value="$1"
  local escaped
  if command -v jq >/dev/null 2>&1 && escaped="$(jq -Rn --arg value "${value}" '$value' 2>/dev/null)"; then
    printf '%s\n' "${escaped}"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && escaped="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "${value}" 2>/dev/null)"; then
    printf '%s\n' "${escaped}"
    return 0
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"\n' "${value}"
}

label_name() {
  local prefix="$1"
  local name="$2"
  local location="${SERVER_LOCATION:-}"
  if [[ -z "${location}" && -r "${STACK_DIR}/server-location.txt" ]]; then
    location="$(<"${STACK_DIR}/server-location.txt")"
  fi
  location="$(normalize_server_location "${location}")"
  if ! valid_server_location "${location}"; then
    location="XX"
  fi

  if [[ "${name}" == "${prefix}-${location}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s-%s' "${prefix}" "${location}" "${name}"
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

decoy_hash_index() {
  local seed="$1"
  local slot="$2"
  local count="$3"
  local hex
  if command -v sha256sum >/dev/null 2>&1; then
    hex="$(printf '%s' "${seed}:${slot}" | sha256sum | awk '{print substr($1, 1, 8)}')"
  else
    hex="$(printf '%s' "${seed}:${slot}" | openssl dgst -sha256 -r | awk '{print substr($1, 1, 8)}')"
  fi
  printf '%s\n' $((16#${hex} % count + 1))
}

decoy_digest8() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print substr($1, 1, 8)}'
  else
    printf '%s' "${value}" | openssl dgst -sha256 -r | awk '{print substr($1, 1, 8)}'
  fi
}

pick_seeded_value() {
  local seed="$1"
  local slot="$2"
  local count idx
  shift 2
  count="$#"
  [[ "${count}" -gt 0 ]] || return 1
  idx="$(decoy_hash_index "${seed}" "${slot}" "${count}")"
  while ((idx > 1)); do
    shift
    idx=$((idx - 1))
  done
  printf '%s' "$1"
}

normalize_decoy_profile() {
  local value="$1"
  value="$(trim_value "${value}")"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    ""|random)
      printf 'random'
      ;;
    network-monitor|software-status|edge-docs|availability-lab)
      printf '%s' "${value}"
      ;;
    monitoring)
      printf 'network-monitor'
      ;;
    software|status)
      printf 'software-status'
      ;;
    docs)
      printf 'edge-docs'
      ;;
    lab)
      printf 'availability-lab'
      ;;
    *)
      die "Unsupported DECOY_PROFILE='${value}'. Use network-monitor, software-status, edge-docs, availability-lab, or random."
      ;;
  esac
}

scan_decoy_tree() {
  local root="$1"
  local forbidden_pattern='(vpn|proxy|tunnel|wireguard|trojan|hysteria|amnezia|xray)'
  if grep -RInEi --include='*.html' --include='*.css' --include='*.txt' "${forbidden_pattern}" "${root}" >/tmp/golden-vpn-decoy-forbidden.$$ 2>/dev/null; then
    cat /tmp/golden-vpn-decoy-forbidden.$$ >&2 || true
    rm -f /tmp/golden-vpn-decoy-forbidden.$$
    die "Decoy content contains forbidden public terms."
  fi
  rm -f /tmp/golden-vpn-decoy-forbidden.$$ 2>/dev/null || true

  if grep -RInE --include='*.html' --include='*.css' 'https?://|//' "${root}" >/tmp/golden-vpn-decoy-urls.$$ 2>/dev/null; then
    cat /tmp/golden-vpn-decoy-urls.$$ >&2 || true
    rm -f /tmp/golden-vpn-decoy-urls.$$
    die "Decoy content contains external URL references."
  fi
  rm -f /tmp/golden-vpn-decoy-urls.$$ 2>/dev/null || true
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

render_decoy_site() {
  local target_dir="$1"
  local manifest_path="${2:-}"
  local requested_profile profile seed brand tagline focus region primary accent bg surface build_id status_note docs_title
  local card_one card_two card_three card_one_text card_two_text card_three_text

  requested_profile="$(normalize_decoy_profile "${DECOY_PROFILE:-random}")"
  seed="${DECOY_SEED:-$(rand_hex 8)}"
  if [[ "${requested_profile}" == "random" ]]; then
    profile="$(pick_seeded_value "${seed}" "profile" "network-monitor" "software-status" "edge-docs" "availability-lab")"
  else
    profile="${requested_profile}"
  fi

  case "${profile}" in
    network-monitor)
      brand="$(pick_seeded_value "${seed}" "brand" "Netwatch" "Pulsegrid" "Signal Harbor" "Lattice Monitor")"
      tagline="$(pick_seeded_value "${seed}" "tagline" "Lightweight availability checks for distributed teams." "Quiet visibility for public service surfaces." "Simple availability signals for operations teams.")"
      focus="$(pick_seeded_value "${seed}" "focus" "availability checks" "route samples" "latency snapshots" "maintenance windows")"
      docs_title="Check catalog"
      status_note="$(pick_seeded_value "${seed}" "status" "All public endpoints are responding normally." "Regional checks are within normal operating range." "No active maintenance windows are scheduled.")"
      card_one="Endpoint checks"; card_one_text="Small availability checks help teams confirm that public service surfaces are reachable."
      card_two="Maintenance notes"; card_two_text="Planned work and operational windows are recorded as concise status updates."
      card_three="Route samples"; card_three_text="Regional signal snapshots make routine behavior easier to compare over time."
      ;;
    software-status)
      brand="$(pick_seeded_value "${seed}" "brand" "Northstar Systems" "Uplink Labs" "Clearboard" "Beacon Desk")"
      tagline="$(pick_seeded_value "${seed}" "tagline" "A compact status surface for service operators." "Public notes for software availability and maintenance." "Small status pages for practical operations.")"
      focus="$(pick_seeded_value "${seed}" "focus" "release windows" "service checks" "operator notes" "status updates")"
      docs_title="Operator notes"
      status_note="$(pick_seeded_value "${seed}" "status" "Application surfaces are operating normally." "No scheduled work is active right now." "Routine checks are passing.")"
      card_one="Status updates"; card_one_text="Short updates keep availability and planned work easy to scan."
      card_two="Release windows"; card_two_text="Maintenance windows are listed clearly and kept separate from routine notes."
      card_three="Public reference"; card_three_text="Static pages provide a stable reference without visitor accounts."
      ;;
    edge-docs)
      brand="$(pick_seeded_value "${seed}" "brand" "Edgebook" "Atlas Reference" "Relay Notes" "Field Manual")"
      tagline="$(pick_seeded_value "${seed}" "tagline" "Operational references for public availability checks." "A static reference for edge status and maintenance notes." "Clear documentation for lightweight service checks.")"
      focus="$(pick_seeded_value "${seed}" "focus" "reference pages" "check definitions" "status summaries" "regional notes")"
      docs_title="Reference notes"
      status_note="$(pick_seeded_value "${seed}" "status" "Reference pages are online." "Check definitions are available." "No documentation maintenance is active.")"
      card_one="Reference pages"; card_one_text="Documentation is kept static, brief, and easy to mirror."
      card_two="Check definitions"; card_two_text="Each check has a plain description and a small status summary."
      card_three="Change notes"; card_three_text="Operational changes are recorded as compact public notes."
      ;;
    availability-lab)
      brand="$(pick_seeded_value "${seed}" "brand" "Signal Lab" "Northline Lab" "Open Cadence" "Metric Yard")"
      tagline="$(pick_seeded_value "${seed}" "tagline" "Availability sampling for small public services." "Practical service signals without account collection." "A simple public surface for operational sampling.")"
      focus="$(pick_seeded_value "${seed}" "focus" "sampling cadence" "incident notes" "availability summaries" "public checks")"
      docs_title="Availability guide"
      status_note="$(pick_seeded_value "${seed}" "status" "Sampling is operating normally." "The incident feed is clear." "Availability summaries are current.")"
      card_one="Sampling cadence"; card_one_text="Short sampling intervals keep public status information fresh."
      card_two="Incident notes"; card_two_text="Incident records are written in a concise operator-friendly format."
      card_three="Retention"; card_three_text="Older public notes are rotated to keep the surface compact."
      ;;
    *)
      die "Internal decoy profile error: ${profile}"
      ;;
  esac

  brand="${DECOY_BRAND:-${brand}}"
  region="${DECOY_REGION:-$(pick_seeded_value "${seed}" "region" "EU-West" "North Atlantic" "Central Europe" "Edge Group 7" "Global Relay")}"
  primary="$(pick_seeded_value "${seed}" "primary" "#0f766e" "#2563eb" "#334155" "#047857" "#475569")"
  accent="$(pick_seeded_value "${seed}" "accent" "#f59e0b" "#06b6d4" "#22c55e" "#64748b" "#f97316")"
  bg="$(pick_seeded_value "${seed}" "bg" "#f8fafc" "#f5f7fb" "#f7f7f2" "#f4f7f5")"
  surface="$(pick_seeded_value "${seed}" "surface" "#ffffff" "#fbfdff" "#fffdf7")"
  build_id="$(decoy_digest8 "${seed}:${profile}")"

  install -d -m 0755 "${target_dir}/assets"
  cat >"${target_dir}/assets/style.css" <<EOF
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

  cat >"${target_dir}/index.html" <<EOF
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
  <section class="section"><div class="wrap cards"><article class="card"><h3>${card_one}</h3><p>${card_one_text}</p></article><article class="card"><h3>${card_two}</h3><p>${card_two_text}</p></article><article class="card"><h3>${card_three}</h3><p>${card_three_text}</p></article></div></section>
  <footer class="footer"><div class="wrap">(c) 2026 ${brand}. Operational reference ${build_id}.</div></footer>
</body>
</html>
EOF

  cat >"${target_dir}/status.html" <<EOF
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

  cat >"${target_dir}/docs.html" <<EOF
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

  cat >"${target_dir}/privacy.html" <<EOF
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

  cat >"${target_dir}/404.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Not found - ${brand}</title><link rel="stylesheet" href="/assets/style.css"></head>
<body><main class="section"><div class="wrap"><div class="eyebrow">404</div><h1>Page not found</h1><p class="lead">The requested reference page is not available.</p><p><a href="/">Return to ${brand}</a></p></div></main></body>
</html>
EOF

  cat >"${target_dir}/robots.txt" <<'EOF'
User-agent: *
Allow: /
Disallow: /assets/
EOF
  chmod 0644 "${target_dir}/assets/style.css" "${target_dir}/index.html" "${target_dir}/status.html" "${target_dir}/docs.html" "${target_dir}/privacy.html" "${target_dir}/404.html" "${target_dir}/robots.txt"
  scan_decoy_tree "${target_dir}"

  if [[ -n "${manifest_path}" ]]; then
    mkdir -p "$(dirname "${manifest_path}")"
    chmod 0700 "$(dirname "${manifest_path}")" 2>/dev/null || true
    cat >"${manifest_path}" <<EOF
{
  "generated_at": $(json_escape "$(date -Is)"),
  "profile": $(json_escape "${profile}"),
  "requested_profile": $(json_escape "${requested_profile}"),
  "seed": $(json_escape "${seed}"),
  "brand": $(json_escape "${brand}"),
  "region": $(json_escape "${region}"),
  "build_id": $(json_escape "${build_id}"),
  "palette": {
    "primary": $(json_escape "${primary}"),
    "accent": $(json_escape "${accent}"),
    "background": $(json_escape "${bg}"),
    "surface": $(json_escape "${surface}")
  },
  "pages": [
    "index.html",
    "status.html",
    "docs.html",
    "privacy.html",
    "404.html",
    "robots.txt",
    "assets/style.css"
  ]
}
EOF
    chmod 0600 "${manifest_path}"
  fi

  if [[ -d "${STACK_DIR}" && -w "${STACK_DIR}" ]]; then
    printf '%s\n' "${brand}" >"${STACK_DIR}/decoy-brand.txt"
    printf '%s\n' "${build_id}" >"${STACK_DIR}/decoy-build-id.txt"
    chmod 0600 "${STACK_DIR}/decoy-brand.txt" "${STACK_DIR}/decoy-build-id.txt"
  fi
}

configure_xray() {
  log "Configuring Trojan XHTTP TLS backend."
  install -d -m 0700 "${STACK_DIR}" "${XRAY_DIR}" "${LOG_DIR}" "${KEY_DIR}/trojan"
  printf '%s\n' "${DOMAIN}" >"${STACK_DIR}/domain.txt"
  printf '%s\n' "${SERVER_LOCATION}" >"${STACK_DIR}/server-location.txt"
  printf '%s\n' "${PUBLIC_IPV4}" >"${STACK_DIR}/public-ipv4.txt"
  printf '%s\n' "${EXT_IFACE}" >"${STACK_DIR}/external-interface.txt"
  chmod 0600 "${STACK_DIR}/server-location.txt"

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
  install -d -m 0755 /var/www/decoy/assets "${SUBSCRIPTION_WEB_DIR}" /etc/nginx/stream-conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled

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

  render_decoy_site "/var/www/decoy" "${DECOY_MANIFEST}"

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

    location ~ "^/s/([A-Za-z0-9]{32,64})/?$" {
        root /var/www;
        access_log off;
        add_header X-Robots-Tag "noindex, nofollow" always;
        set \$sub_entry "/subscriptions/\$1/index.html";
        if (\$http_user_agent ~* "(Hiddify|Clash|sing-box|v2ray|Neko|Streisand|Shadowrocket|FoXray|SFI|Nekoray)") {
            set \$sub_entry "/subscriptions/\$1/sub.txt";
        }
        try_files \$sub_entry =404;
    }

    location ~ "^/s/([A-Za-z0-9]{32,64})/(sub\.txt|sub\.base64|awg\.conf)$" {
        root /var/www;
        access_log off;
        add_header X-Robots-Tag "noindex, nofollow" always;
        default_type text/plain;
        try_files /subscriptions/\$1/\$2 =404;
    }

    location ~ "^/s/([A-Za-z0-9]{32,64})/awg/?$" {
        root /var/www;
        access_log off;
        add_header X-Robots-Tag "noindex, nofollow" always;
        try_files /subscriptions/\$1/awg.html =404;
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
  apt_get update
  if ! apt_get install -y amneziawg; then
    warn "amneziawg meta package install failed; trying amneziawg-dkms and amneziawg-tools directly."
    if ! apt_get install -y amneziawg-dkms amneziawg-tools; then
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
    apt_get install -y git make golang-go
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

validate_int_range() {
  local name="$1"
  local value="$2"
  local min="$3"
  local max="$4"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be an integer from ${min} to ${max}."
  [[ "${value}" -ge "${min}" && "${value}" -le "${max}" ]] || die "${name} must be from ${min} to ${max}."
}

detect_awg_auto_mtu() {
  local target payload best=0 path_mtu awg_mtu
  local -a targets=(1.1.1.1 8.8.8.8)
  [[ -n "${DOMAIN:-}" ]] && targets+=("${DOMAIN}")

  command -v ping >/dev/null 2>&1 || {
    printf '1280\n'
    return 0
  }

  for target in "${targets[@]}"; do
    for payload in 1372 1352 1332 1312 1292 1272 1252 1232 1212 1172; do
      if ping -4 -c 1 -W 1 -M do -s "${payload}" "${target}" >/dev/null 2>&1; then
        ((payload > best)) && best="${payload}"
        break
      fi
    done
  done

  if ((best <= 0)); then
    printf '1280\n'
    return 0
  fi

  path_mtu=$((best + 28))
  awg_mtu=$((path_mtu - 80))
  ((awg_mtu < 1200)) && awg_mtu=1200
  ((awg_mtu > 1420)) && awg_mtu=1420
  printf '%s\n' "${awg_mtu}"
}

generate_awg_tuning() {
  local requested_profile effective_profile awg_mtu awg_mtu_requested awg_port awg_dns awg_allowed_ips awg_keepalive
  local jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 source_note mtu_source

  requested_profile="$(printf '%s' "${AWG_OBFS_PROFILE:-random-balanced}" | tr '[:upper:]' '[:lower:]')"
  case "${requested_profile}" in
    dns|quic-lite|video-call|mobile-low-mtu|random-balanced|custom)
      ;;
    random)
      requested_profile="random-balanced"
      ;;
    *)
      die "Unsupported AWG_OBFS_PROFILE='${requested_profile}'. Use dns, quic-lite, video-call, mobile-low-mtu, random-balanced, or custom."
      ;;
  esac

  if [[ "${requested_profile}" == "random-balanced" || "${requested_profile}" == "custom" ]]; then
    effective_profile="$(pick_decoy_value "dns" "quic-lite" "video-call" "mobile-low-mtu")"
  else
    effective_profile="${requested_profile}"
  fi

  case "${effective_profile}" in
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
    video-call)
      jc="$(rand_between 7 12)"
      jmin="$(rand_between 120 220)"
      jmax="$(rand_between 820 1320)"
      s1="$(rand_between 112 220)"
      s2="$(rand_between 96 180)"
      s3="$(rand_between 80 160)"
      s4="$(rand_between 112 220)"
      i1="<r 32><t><r 96>"
      i2="<r 64><t><r 48>"
      i3="<r 112>"
      i4="<t><r 72>"
      i5="<r 96><t>"
      ;;
    mobile-low-mtu)
      jc="$(rand_between 4 7)"
      jmin="$(rand_between 36 84)"
      jmax="$(rand_between 360 680)"
      s1="$(rand_between 48 112)"
      s2="$(rand_between 36 88)"
      s3="$(rand_between 28 72)"
      s4="$(rand_between 48 112)"
      i1="<r 8><t><r 24>"
      i2="<r 18><t><r 18>"
      i3="<r 32>"
      i4="<t><r 22>"
      i5="<rc 8><r 12>"
      ;;
    *)
      die "Internal AWG profile error: ${effective_profile}"
      ;;
  esac

  h1="$(rand_range 100000000 499999999 25000000 90000000)"
  h2="$(rand_range 600000000 999999999 25000000 90000000)"
  h3="$(rand_range 1100000000 1499999999 25000000 90000000)"
  h4="$(rand_range 1600000000 2100000000 25000000 90000000)"

  [[ -n "${AWG_JC:-}" ]] && jc="${AWG_JC}"
  [[ -n "${AWG_JMIN:-}" ]] && jmin="${AWG_JMIN}"
  [[ -n "${AWG_JMAX:-}" ]] && jmax="${AWG_JMAX}"
  [[ -n "${AWG_S1:-}" ]] && s1="${AWG_S1}"
  [[ -n "${AWG_S2:-}" ]] && s2="${AWG_S2}"
  [[ -n "${AWG_S3:-}" ]] && s3="${AWG_S3}"
  [[ -n "${AWG_S4:-}" ]] && s4="${AWG_S4}"
  [[ -n "${AWG_H1:-}" ]] && h1="${AWG_H1}"
  [[ -n "${AWG_H2:-}" ]] && h2="${AWG_H2}"
  [[ -n "${AWG_H3:-}" ]] && h3="${AWG_H3}"
  [[ -n "${AWG_H4:-}" ]] && h4="${AWG_H4}"
  [[ -n "${AWG_I1:-}" ]] && i1="${AWG_I1}"
  [[ -n "${AWG_I2:-}" ]] && i2="${AWG_I2}"
  [[ -n "${AWG_I3:-}" ]] && i3="${AWG_I3}"
  [[ -n "${AWG_I4:-}" ]] && i4="${AWG_I4}"
  [[ -n "${AWG_I5:-}" ]] && i5="${AWG_I5}"

  validate_int_range AWG_JC "${jc}" 1 128
  validate_int_range AWG_JMIN "${jmin}" 1 4096
  validate_int_range AWG_JMAX "${jmax}" 1 4096
  ((jmin <= jmax)) || die "AWG_JMIN must be less than or equal to AWG_JMAX."
  validate_int_range AWG_S1 "${s1}" 1 4096
  validate_int_range AWG_S2 "${s2}" 1 4096
  validate_int_range AWG_S3 "${s3}" 1 4096
  validate_int_range AWG_S4 "${s4}" 1 4096

  awg_mtu_requested="${AWG_MTU:-}"
  if [[ -z "${awg_mtu_requested}" ]]; then
    if [[ "${effective_profile}" == "mobile-low-mtu" ]]; then
      awg_mtu="1240"
      mtu_source="profile"
    else
      awg_mtu="1280"
      mtu_source="default"
    fi
  elif [[ "${awg_mtu_requested}" == "auto" ]]; then
    awg_mtu="$(detect_awg_auto_mtu)"
    mtu_source="auto-pmtu"
  else
    awg_mtu="${awg_mtu_requested}"
    mtu_source="user"
  fi
  validate_int_range AWG_MTU "${awg_mtu}" 1200 1420

  awg_port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}"
  validate_int_range AWG_ENDPOINT_PORT "${awg_port}" 1 65535
  awg_dns="${AWG_DNS:-1.1.1.1, 8.8.8.8}"
  awg_allowed_ips="${AWG_ALLOWED_IPS:-0.0.0.0/0, ::/0}"
  awg_keepalive="${AWG_KEEPALIVE:-25}"
  validate_int_range AWG_KEEPALIVE "${awg_keepalive}" 0 65535

  source_note="profile=${requested_profile}; effective=${effective_profile}; overrides are applied from AWG_* env when present"

  {
    printf 'AWG_OBFS_PROFILE=%q\n' "${requested_profile}"
    printf 'AWG_EFFECTIVE_PROFILE=%q\n' "${effective_profile}"
    printf 'AWG_TUNING_SOURCE=%q\n' "${source_note}"
    printf 'AWG_MTU=%q\n' "${awg_mtu}"
    printf 'AWG_MTU_SOURCE=%q\n' "${mtu_source}"
    printf 'AWG_ENDPOINT_PORT=%q\n' "${awg_port}"
    printf 'AWG_DNS=%q\n' "${awg_dns}"
    printf 'AWG_ALLOWED_IPS=%q\n' "${awg_allowed_ips}"
    printf 'AWG_KEEPALIVE=%q\n' "${awg_keepalive}"
    printf 'AWG_JC=%q\n' "${jc}"
    printf 'AWG_JMIN=%q\n' "${jmin}"
    printf 'AWG_JMAX=%q\n' "${jmax}"
    printf 'AWG_S1=%q\n' "${s1}"
    printf 'AWG_S2=%q\n' "${s2}"
    printf 'AWG_S3=%q\n' "${s3}"
    printf 'AWG_S4=%q\n' "${s4}"
    printf 'AWG_H1=%q\n' "${h1}"
    printf 'AWG_H2=%q\n' "${h2}"
    printf 'AWG_H3=%q\n' "${h3}"
    printf 'AWG_H4=%q\n' "${h4}"
    printf 'AWG_I1=%q\n' "${i1}"
    printf 'AWG_I2=%q\n' "${i2}"
    printf 'AWG_I3=%q\n' "${i3}"
    printf 'AWG_I4=%q\n' "${i4}"
    printf 'AWG_I5=%q\n' "${i5}"
  } >"${STACK_DIR}/awg-params.env"
  chmod 0600 "${STACK_DIR}/awg-params.env"

  cat >"${AWG_TUNING_REPORT}" <<EOF
{
  "generated_at": $(json_escape "$(date -Is)"),
  "requested_profile": $(json_escape "${requested_profile}"),
  "effective_profile": $(json_escape "${effective_profile}"),
  "mtu": ${awg_mtu},
  "mtu_source": $(json_escape "${mtu_source}"),
  "endpoint_port": ${awg_port},
  "dns": $(json_escape "${awg_dns}"),
  "allowed_ips": $(json_escape "${awg_allowed_ips}"),
  "keepalive": ${awg_keepalive},
  "params_path": $(json_escape "${STACK_DIR}/awg-params.env"),
  "note": $(json_escape "Values are randomized per install unless overridden through AWG_* environment variables. Tcpdump is never started automatically.")
}
EOF
  chmod 0600 "${AWG_TUNING_REPORT}"
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
# GeneratedAt = $(date -Is)
# ObfuscationProfile = ${AWG_OBFS_PROFILE:-unknown}
# EffectiveProfile = ${AWG_EFFECTIVE_PROFILE:-unknown}
# MTU = ${AWG_MTU:-1280}
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = ${AWG_DNS:-1.1.1.1, 8.8.8.8}
MTU = ${AWG_MTU:-1280}
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
Endpoint = ${DOMAIN}:${AWG_ENDPOINT_PORT:-51820}
AllowedIPs = ${AWG_ALLOWED_IPS:-0.0.0.0/0, ::/0}
PersistentKeepalive = ${AWG_KEEPALIVE:-25}
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

  generate_awg_tuning
  # shellcheck disable=SC1091
  source "${STACK_DIR}/awg-params.env"

  local awg_profile awg_effective_profile awg_mtu awg_port jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5
  awg_profile="${AWG_OBFS_PROFILE}"
  awg_effective_profile="${AWG_EFFECTIVE_PROFILE}"
  awg_mtu="${AWG_MTU}"
  awg_port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}"
  jc="${AWG_JC}"
  jmin="${AWG_JMIN}"
  jmax="${AWG_JMAX}"
  s1="${AWG_S1}"
  s2="${AWG_S2}"
  s3="${AWG_S3}"
  s4="${AWG_S4}"
  h1="${AWG_H1}"
  h2="${AWG_H2}"
  h3="${AWG_H3}"
  h4="${AWG_H4}"
  i1="${AWG_I1}"
  i2="${AWG_I2}"
  i3="${AWG_I3}"
  i4="${AWG_I4}"
  i5="${AWG_I5}"
  log "AWG profile: ${awg_profile} (effective ${awg_effective_profile}), MTU ${awg_mtu}, UDP port ${awg_port}."
  printf '%s\n' "${server_public}" >"${STACK_DIR}/awg-server-public-key.txt"
  chmod 0600 "${STACK_DIR}/awg-server-public-key.txt"

  cat >/etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = ${awg_port}
PrivateKey = ${server_private}
MTU = ${awg_mtu}
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

swap_report_label() {
  if [[ "${SWAP_RESULT}" != "not checked" ]]; then
    printf '%s' "${SWAP_RESULT}"
  elif swapon --show --noheadings 2>/dev/null | awk '$1 == "/swapfile" {found=1} END {exit found ? 0 : 1}'; then
    printf 'active /swapfile present'
  elif swapon --show | awk 'NR>1 {found=1} END {exit found ? 0 : 1}'; then
    printf 'active swap present'
  else
    printf 'none active'
  fi
}

configure_firewall() {
  local awg_port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}"
  if [[ -f "${STACK_DIR}/awg-params.env" ]]; then
    # shellcheck disable=SC1091
    source "${STACK_DIR}/awg-params.env"
    awg_port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}"
  fi
  log "Configuring UFW firewall."
  ufw default deny incoming
  ufw default allow outgoing
  ensure_ssh_firewall_access
  ufw allow 443/tcp
  ufw allow 8443/udp
  ufw allow "${awg_port}/udp"
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
  local location="XX"
  if [[ -r "${STACK_DIR}/server-location.txt" ]]; then
    location="$(<"${STACK_DIR}/server-location.txt")"
  fi
  location="$(printf '%s' "${location}" | tr '[:lower:]' '[:upper:]')"
  if [[ ! "${location}" =~ ^[A-Z]{2}$ ]]; then
    location="XX"
  fi

  if [[ "${name}" == "${prefix}-${location}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s-%s' "${prefix}" "${location}" "${name}"
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
  local location="XX"
  if [[ -r "${STACK_DIR}/server-location.txt" ]]; then
    location="$(<"${STACK_DIR}/server-location.txt")"
  fi
  location="$(printf '%s' "${location}" | tr '[:lower:]' '[:upper:]')"
  if [[ ! "${location}" =~ ^[A-Z]{2}$ ]]; then
    location="XX"
  fi

  if [[ "${name}" == "${prefix}-${location}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s-%s' "${prefix}" "${location}" "${name}"
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
PARAMS="${STACK_DIR}/awg-params.env"
DEFAULT_PORT=51820

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
  local location="XX"
  if [[ -r "${STACK_DIR}/server-location.txt" ]]; then
    location="$(<"${STACK_DIR}/server-location.txt")"
  fi
  location="$(printf '%s' "${location}" | tr '[:lower:]' '[:upper:]')"
  if [[ ! "${location}" =~ ^[A-Z]{2}$ ]]; then
    location="XX"
  fi

  if [[ "${name}" == "${prefix}-${location}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s-%s' "${prefix}" "${location}" "${name}"
  fi
}

load_params() {
  [[ -f "${PARAMS}" ]] || die "Missing ${PARAMS}"
  # shellcheck disable=SC1090
  source "${PARAMS}"
  AWG_ENDPOINT_PORT="${AWG_ENDPOINT_PORT:-${DEFAULT_PORT}}"
  AWG_DNS="${AWG_DNS:-1.1.1.1, 8.8.8.8}"
  AWG_ALLOWED_IPS="${AWG_ALLOWED_IPS:-0.0.0.0/0, ::/0}"
  AWG_KEEPALIVE="${AWG_KEEPALIVE:-25}"
}

show_usage() {
  cat <<'USAGE'
Usage:
  vpn-awg <name>          Create a new AmneziaWG client
  vpn-awg list            List saved AmneziaWG client configs
  vpn-awg show <name>     Print saved client config and QR
  vpn-awg revoke <name>   Remove a client peer and archive its config
  vpn-awg rotate <name>   Revoke and recreate a client
  vpn-awg profile         Show selected obfuscation profile and tuning report
  vpn-awg show-config     Show sanitized server config
  vpn-awg explain         Explain tuning and capture policy
  vpn-awg analyze [sec]   Print AWG status; if sec > 0, explicitly capture UDP packets
  vpn-awg capture [sec]   Save a tcpdump pcap, default 20 seconds
  vpn-awg analyze-live [packets]  Print a live tcpdump summary without saving pcap
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
  local iface out port
  [[ "${seconds}" =~ ^[0-9]+$ && "${seconds}" -ge 1 && "${seconds}" -le 300 ]] || die "Capture duration must be 1..300 seconds."
  command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed."
  load_params
  port="${AWG_ENDPOINT_PORT:-${DEFAULT_PORT}}"
  iface="$(cat "${STACK_DIR}/external-interface.txt" 2>/dev/null || true)"
  [[ -n "${iface}" ]] || iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "${iface}" ]] || die "Could not determine external interface."
  install -d -m 0700 /var/log/vpn-stack/awg-captures
  out="/var/log/vpn-stack/awg-captures/awg-udp-${port}-$(date +%Y%m%d-%H%M%S).pcap"
  echo "Capturing UDP/${port} on ${iface} for ${seconds}s -> ${out}"
  echo "The pcap contains encrypted UDP metadata; keep it private."
  timeout "${seconds}" tcpdump -ni "${iface}" -s 192 -w "${out}" udp port "${port}" || true
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

analyze_live_awg() {
  local packets="${1:-20}"
  local iface port
  [[ "${packets}" =~ ^[0-9]+$ && "${packets}" -ge 1 && "${packets}" -le 200 ]] || die "Packet count must be 1..200."
  command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed."
  load_params
  port="${AWG_ENDPOINT_PORT:-${DEFAULT_PORT}}"
  iface="$(cat "${STACK_DIR}/external-interface.txt" 2>/dev/null || true)"
  [[ -n "${iface}" ]] || iface="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "${iface}" ]] || die "Could not determine external interface."
  echo "Live UDP/${port} summary on ${iface}, ${packets} packets max. No pcap will be saved."
  tcpdump -ni "${iface}" -c "${packets}" -tt -nn udp port "${port}" 2>/dev/null | awk '
    /length/ {
      for (i = 1; i <= NF; i++) if ($i == "length") {
        n = $(i + 1); gsub(/[^0-9]/, "", n)
        if (n != "") print "  packet length=" n
      }
    }
  '
}

analyze_awg() {
  local seconds="${1:-0}"
  local iface port
  load_params
  port="${AWG_ENDPOINT_PORT:-${DEFAULT_PORT}}"
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
  ss -lunp | awk -v port=":${port}" '$5 ~ (port "$") {print "  " $0}' || true
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
  if [[ -f "${PARAMS}" ]]; then
    grep -E '^AWG_(OBFS_PROFILE|EFFECTIVE_PROFILE|TUNING_SOURCE|MTU|MTU_SOURCE|ENDPOINT_PORT|DNS|ALLOWED_IPS|KEEPALIVE|JC|JMIN|JMAX|S[1-4]|H[1-4]|I[1-5])=' "${PARAMS}" | sed 's/^/  /'
  else
    echo "  missing ${PARAMS}"
  fi
  [[ -f "${STACK_DIR}/awg-tuning-report.json" ]] && echo "  report: ${STACK_DIR}/awg-tuning-report.json"
  if [[ "${seconds}" =~ ^[0-9]+$ && "${seconds}" -gt 0 ]]; then
    echo
    capture_awg_udp "${seconds}"
  fi
}

client_file_for() {
  local name="$1"
  local label
  label="$(label_name "AWG" "${name}")"
  if [[ -f "${KEY_DIR}/${label}.conf" ]]; then
    printf '%s\n' "${KEY_DIR}/${label}.conf"
  elif [[ -f "${KEY_DIR}/${name}.conf" ]]; then
    printf '%s\n' "${KEY_DIR}/${name}.conf"
  else
    return 1
  fi
}

list_clients() {
  install -d -m 0700 "${KEY_DIR}"
  find "${KEY_DIR}" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//' | sort
}

show_client() {
  local name="$1"
  local file
  file="$(client_file_for "${name}")" || die "Client not found: ${name}"
  printf 'Client file: %s\n' "${file}"
  print_qr "$(cat "${file}")"
  cat "${file}"
}

revoke_client() {
  local name="$1"
  local file label private public tmp archive
  file="$(client_file_for "${name}")" || die "Client not found: ${name}"
  label="$(basename "${file}" .conf)"
  private="$(awk -F'= *' '$1 ~ /^PrivateKey/ {print $2; exit}' "${file}")"
  [[ -n "${private}" ]] || die "Could not read client private key from ${file}."
  public="$(printf '%s\n' "${private}" | awg pubkey)"

  tmp="$(mktemp)"
  awk -v pub="${public}" '
    function flush_peer() {
      if (peer) {
        if (!drop) printf "%s", block
        peer = 0
        block = ""
        drop = 0
      }
    }
    /^\[Peer\][[:space:]]*$/ {
      flush_peer()
      peer = 1
      block = $0 ORS
      next
    }
    peer {
      block = block $0 ORS
      line = $0
      if (line ~ /^[[:space:]]*PublicKey[[:space:]]*=/) {
        sub(/^[^=]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]*$/, "", line)
        if (line == pub) drop = 1
      }
      next
    }
    {
      flush_peer()
      print
    }
    END {
      flush_peer()
    }
  ' "${CONFIG}" >"${tmp}"
  install -m 0600 "${tmp}" "${CONFIG}"
  rm -f "${tmp}"

  if awg show awg0 >/dev/null 2>&1; then
    awg set awg0 peer "${public}" remove || true
  else
    systemctl restart awg-quick@awg0.service || true
  fi

  install -d -m 0700 "${KEY_DIR}/revoked"
  archive="${KEY_DIR}/revoked/$(date +%Y%m%d-%H%M%S)-${label}.conf"
  mv "${file}" "${archive}"
  chmod 0600 "${archive}"
  printf 'Revoked: %s\nArchived: %s\n' "${label}" "${archive}"
}

profile_report() {
  load_params
  echo "AmneziaWG profile"
  echo
  grep -E '^AWG_(OBFS_PROFILE|EFFECTIVE_PROFILE|TUNING_SOURCE|MTU|MTU_SOURCE|ENDPOINT_PORT|DNS|ALLOWED_IPS|KEEPALIVE|JC|JMIN|JMAX|S[1-4]|H[1-4]|I[1-5])=' "${PARAMS}" | sed 's/^/  /'
  echo
  if [[ -f "${STACK_DIR}/awg-tuning-report.json" ]]; then
    echo "Report: ${STACK_DIR}/awg-tuning-report.json"
    if command -v jq >/dev/null 2>&1; then
      jq . "${STACK_DIR}/awg-tuning-report.json"
    else
      cat "${STACK_DIR}/awg-tuning-report.json"
    fi
  fi
}

show_sanitized_config() {
  [[ -f "${CONFIG}" ]] || die "Missing ${CONFIG}"
  sed -E 's/^(PrivateKey|PresharedKey)[[:space:]]*=.*/\1 = [hidden]/' "${CONFIG}"
}

explain_tuning() {
  cat <<'EXPLAIN'
AmneziaWG tuning notes

Values are generated at install time from AWG_OBFS_PROFILE and saved in /opt/vpn-stack/awg-params.env.
Supported profiles: dns, quic-lite, video-call, mobile-low-mtu, random-balanced, custom.
Use AWG_MTU=auto to run a PMTU probe; if ICMP is blocked, the fallback is 1280.
Use AWG_* environment variables before install to override generated values.

Tcpdump is never started by the installer. Explicit commands:
  vpn-awg analyze 20
  vpn-awg capture 30
  vpn-awg analyze-live 20

Saved pcap files contain encrypted UDP metadata and should remain private.
EXPLAIN
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
  analyze-live|live)
    analyze_live_awg "${2:-20}"
    exit 0
    ;;
  capture|tcpdump)
    capture_awg_udp "${2:-20}"
    exit 0
    ;;
  list)
    list_clients
    exit 0
    ;;
  show)
    [[ -n "${2:-}" ]] || die "Usage: vpn-awg show <name>"
    show_client "${2}"
    exit 0
    ;;
  revoke)
    [[ -n "${2:-}" ]] || die "Usage: vpn-awg revoke <name>"
    revoke_client "${2}"
    exit 0
    ;;
  rotate)
    [[ -n "${2:-}" ]] || die "Usage: vpn-awg rotate <name>"
    revoke_client "${2}"
    exec "$0" "${2}"
    ;;
  profile)
    profile_report
    exit 0
    ;;
  show-config)
    show_sanitized_config
    exit 0
    ;;
  explain)
    explain_tuning
    exit 0
    ;;
esac
[[ $# -eq 1 ]] || die "Usage: vpn-awg <name>"
name="$1"
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CONFIG}" ]] || die "Missing ${CONFIG}"
load_params
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
# GeneratedAt = $(date -Is)
# ObfuscationProfile = ${AWG_OBFS_PROFILE:-unknown}
# EffectiveProfile = ${AWG_EFFECTIVE_PROFILE:-unknown}
# MTU = ${AWG_MTU:-1280}
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = ${AWG_DNS:-1.1.1.1, 8.8.8.8}
MTU = ${AWG_MTU:-1280}
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
Endpoint = ${domain}:${AWG_ENDPOINT_PORT:-51820}
AllowedIPs = ${AWG_ALLOWED_IPS:-0.0.0.0/0, ::/0}
PersistentKeepalive = ${AWG_KEEPALIVE:-25}
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

install_helper_subscriptions() {
  cat >/usr/local/bin/vpn-sub <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="/opt/vpn-stack"
SUB_DIR="${STACK_DIR}/subscriptions"
WEB_ROOT="/var/www/subscriptions"
KEY_ROOT="/root/vpn-keys"
XRAY_CONFIG="${STACK_DIR}/xray/config.json"
XRAY_SERVICE="xray-trojan-xhttp-tls.service"
HYSTERIA_CONFIG="${STACK_DIR}/hysteria/config.yaml"
HYSTERIA_CLIENTS="${STACK_DIR}/hysteria-clients.json"
HYSTERIA_SERVICE="hysteria2.service"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  vpn-sub create <name>   Create Trojan + Hysteria2 + AmneziaWG subscription bundle
  vpn-sub list            List active subscriptions
  vpn-sub show <name>     Show subscription URLs and QR
  vpn-sub revoke <name>   Remove served files and disable protocol credentials
  vpn-sub rotate <name>   Revoke and recreate with a new token and credentials
USAGE
}

print_qr() {
  local payload="$1"
  if command -v qrencode >/dev/null 2>&1; then
    printf '\nQR code:\n'
    printf '%s' "${payload}" | qrencode -t ANSIUTF8 -l L -m 1 || true
    printf '\n'
  fi
}

domain_name() {
  [[ -r "${STACK_DIR}/domain.txt" ]] || die "Missing ${STACK_DIR}/domain.txt"
  cat "${STACK_DIR}/domain.txt"
}

server_location() {
  local location="XX"
  [[ -r "${STACK_DIR}/server-location.txt" ]] && location="$(<"${STACK_DIR}/server-location.txt")"
  location="$(printf '%s' "${location}" | tr '[:lower:]' '[:upper:]')"
  [[ "${location}" =~ ^[A-Z]{2}$ ]] || location="XX"
  printf '%s' "${location}"
}

label_name() {
  local prefix="$1"
  local name="$2"
  local location
  location="$(server_location)"
  if [[ "${name}" == "${prefix}-${location}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s-%s' "${prefix}" "${location}" "${name}"
  fi
}

validate_name() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
}

html_escape() {
  python3 -c 'import html, sys; print(html.escape(sys.argv[1], quote=True))' "$1"
}

b64_nowrap() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

resolve_token() {
  local key="$1"
  local meta token
  [[ "${key}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if [[ -f "${SUB_DIR}/${key}/meta.json" ]]; then
    printf '%s\n' "${key}"
    return 0
  fi
  for meta in "${SUB_DIR}"/*/meta.json; do
    [[ -e "${meta}" ]] || continue
    if jq -e --arg key "${key}" '.name == $key or .label == $key' "${meta}" >/dev/null; then
      token="$(basename "$(dirname "${meta}")")"
      printf '%s\n' "${token}"
      return 0
    fi
  done
  return 1
}

subscription_exists() {
  resolve_token "$1" >/dev/null 2>&1
}

publish_permissions() {
  local pubdir="$1"
  chmod 0755 "${WEB_ROOT}" 2>/dev/null || true
  if getent group www-data >/dev/null 2>&1; then
    chgrp -R www-data "${pubdir}"
    chmod 0750 "${pubdir}"
    find "${pubdir}" -type f -exec chmod 0640 {} +
  else
    chmod 0755 "${pubdir}"
    find "${pubdir}" -type f -exec chmod 0644 {} +
  fi
}

render_hysteria_config() {
  local obfs
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
  {
    printf 'listen: :8443\n'
    printf 'tls:\n'
    printf '  cert: /etc/letsencrypt/live/%s/fullchain.pem\n' "$(domain_name)"
    printf '  key: /etc/letsencrypt/live/%s/privkey.pem\n' "$(domain_name)"
    printf 'auth:\n'
    printf '  type: userpass\n'
    printf '  userpass:\n'
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "${HYSTERIA_CLIENTS}"
    printf 'obfs:\n'
    printf '  type: salamander\n'
    printf '  salamander:\n'
    printf '    password: %s\n' "${obfs}"
  } >"${HYSTERIA_CONFIG}"
  chmod 0600 "${HYSTERIA_CONFIG}"
}

write_portal_files() {
  local name="$1" token="$2" trojan_link="$3" hysteria_link="$4" awg_file="$5"
  local pubdir base domain label safe_name safe_label
  domain="$(domain_name)"
  label="$(label_name "SUB" "${name}")"
  safe_name="$(html_escape "${name}")"
  safe_label="$(html_escape "${label}")"
  base="https://${domain}/s/${token}"
  pubdir="${WEB_ROOT}/${token}"

  install -d -m 0755 "${WEB_ROOT}"
  install -d -m 0750 "${pubdir}"
  {
    printf '%s\n' "${trojan_link}"
    printf '%s\n' "${hysteria_link}"
  } >"${pubdir}/sub.txt"
  b64_nowrap <"${pubdir}/sub.txt" >"${pubdir}/sub.base64"
  cp "${awg_file}" "${pubdir}/awg.conf"

  cat >"${pubdir}/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>${safe_label}</title>
  <style>
    :root { color-scheme: light; --bg:#f6f8fb; --text:#172033; --muted:#637083; --line:#d9e2ec; --surface:#fff; --primary:#0f766e; }
    * { box-sizing: border-box; }
    body { margin:0; min-height:100vh; font-family:Arial,Helvetica,sans-serif; background:var(--bg); color:var(--text); }
    main { width:min(780px, calc(100% - 32px)); margin:0 auto; padding:56px 0; }
    h1 { margin:0 0 10px; font-size:32px; letter-spacing:0; }
    p { color:var(--muted); line-height:1.6; }
    .panel { border:1px solid var(--line); border-radius:8px; background:var(--surface); padding:22px; margin-top:18px; }
    .grid { display:grid; gap:12px; grid-template-columns:repeat(2,minmax(0,1fr)); }
    a { display:block; border:1px solid var(--line); border-radius:8px; padding:14px 16px; color:var(--text); text-decoration:none; background:#fff; }
    a strong { display:block; color:var(--primary); margin-bottom:4px; }
    code { display:block; overflow-wrap:anywhere; padding:12px; border-radius:8px; background:#eef3f7; color:#26364a; }
    @media (max-width:640px) { .grid { grid-template-columns:1fr; } }
  </style>
</head>
<body>
  <main>
    <h1>${safe_label}</h1>
    <p>Private subscription bundle for ${safe_name}. Use the import URL in compatible clients, or download individual files below.</p>
    <div class="panel">
      <p>Import URL</p>
      <code>${base}</code>
    </div>
    <div class="panel grid">
      <a href="${base}/sub.txt"><strong>Client subscription</strong>Trojan TLS and Hysteria2 links</a>
      <a href="${base}/sub.base64"><strong>Base64 subscription</strong>Encoded subscription payload</a>
      <a href="${base}/awg.conf"><strong>AmneziaWG config</strong>Download configuration file</a>
      <a href="${base}/awg"><strong>AmneziaWG preview</strong>View configuration text</a>
    </div>
  </main>
</body>
</html>
HTML

  python3 - "${awg_file}" "${pubdir}/awg.html" "${safe_label}" "${base}" <<'PY'
import html
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
label = sys.argv[3]
base = sys.argv[4]
conf = html.escape(source.read_text())
target.write_text(f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>{label} AmneziaWG</title>
  <style>
    body {{ margin:0; font-family:Arial,Helvetica,sans-serif; background:#f6f8fb; color:#172033; }}
    main {{ width:min(900px, calc(100% - 32px)); margin:0 auto; padding:42px 0; }}
    pre {{ overflow:auto; white-space:pre-wrap; border:1px solid #d9e2ec; border-radius:8px; background:#fff; padding:18px; }}
    a {{ color:#0f766e; }}
  </style>
</head>
<body>
  <main>
    <h1>{label} AmneziaWG</h1>
    <p><a href="{base}/awg.conf">Download awg.conf</a></p>
    <pre>{conf}</pre>
  </main>
</body>
</html>
""")
PY

  publish_permissions "${pubdir}"
}

create_subscription() {
  local name="$1" token private_dir domain base trojan_label hysteria_label awg_label
  local trojan_file hysteria_file awg_file trojan_link hysteria_link label created_at

  validate_name "${name}"
  subscription_exists "${name}" && die "Subscription already exists: ${name}"
  command -v vpn-trojan >/dev/null 2>&1 || die "Missing vpn-trojan helper."
  command -v vpn-hysteria >/dev/null 2>&1 || die "Missing vpn-hysteria helper."
  command -v vpn-awg >/dev/null 2>&1 || die "Missing vpn-awg helper."

  install -d -m 0700 "${SUB_DIR}"
  install -d -m 0755 "${WEB_ROOT}"

  echo "Creating Trojan client..."
  vpn-trojan "${name}"
  echo "Creating Hysteria2 client..."
  vpn-hysteria "${name}"
  echo "Creating AmneziaWG client..."
  vpn-awg "${name}"

  trojan_label="$(label_name "TROJAN" "${name}")"
  hysteria_label="$(label_name "HYSTERIA" "${name}")"
  awg_label="$(label_name "AWG" "${name}")"
  label="$(label_name "SUB" "${name}")"
  trojan_file="${KEY_ROOT}/trojan/${trojan_label}.txt"
  hysteria_file="${KEY_ROOT}/hysteria/${hysteria_label}.txt"
  awg_file="${KEY_ROOT}/awg/${awg_label}.conf"
  [[ -r "${trojan_file}" ]] || die "Missing ${trojan_file}"
  [[ -r "${hysteria_file}" ]] || die "Missing ${hysteria_file}"
  [[ -r "${awg_file}" ]] || die "Missing ${awg_file}"
  trojan_link="$(<"${trojan_file}")"
  hysteria_link="$(<"${hysteria_file}")"

  token="$(openssl rand -hex 24)"
  while [[ -e "${SUB_DIR}/${token}" || -e "${WEB_ROOT}/${token}" ]]; do
    token="$(openssl rand -hex 24)"
  done
  private_dir="${SUB_DIR}/${token}"
  install -d -m 0700 "${private_dir}"

  write_portal_files "${name}" "${token}" "${trojan_link}" "${hysteria_link}" "${awg_file}"

  domain="$(domain_name)"
  base="https://${domain}/s/${token}"
  created_at="$(date -Is)"
  jq -n \
    --arg version "1" \
    --arg name "${name}" \
    --arg label "${label}" \
    --arg token "${token}" \
    --arg created_at "${created_at}" \
    --arg portal "${base}" \
    --arg sub_txt "${base}/sub.txt" \
    --arg sub_base64 "${base}/sub.base64" \
    --arg awg_conf "${base}/awg.conf" \
    --arg awg_preview "${base}/awg" \
    --arg trojan_label "${trojan_label}" \
    --arg hysteria_label "${hysteria_label}" \
    --arg awg_label "${awg_label}" \
    '{
      version: ($version|tonumber),
      name: $name,
      label: $label,
      token: $token,
      status: "active",
      created_at: $created_at,
      labels: {trojan: $trojan_label, hysteria: $hysteria_label, awg: $awg_label},
      urls: {portal: $portal, sub_txt: $sub_txt, sub_base64: $sub_base64, awg_conf: $awg_conf, awg_preview: $awg_preview}
    }' >"${private_dir}/meta.json"
  chmod 0600 "${private_dir}/meta.json"

  printf '\nSubscription: %s\n' "${label}"
  printf 'Portal/import URL: %s\n' "${base}"
  printf 'Plain payload: %s/sub.txt\n' "${base}"
  printf 'AmneziaWG config: %s/awg.conf\n' "${base}"
  print_qr "${base}"
}

archive_file() {
  local file="$1" bucket="$2"
  [[ -e "${file}" ]] || return 0
  install -d -m 0700 "${bucket}"
  mv "${file}" "${bucket}/$(date +%Y%m%d-%H%M%S)-$(basename "${file}")"
}

revoke_trojan() {
  local name="$1" tmp backup
  [[ -f "${XRAY_CONFIG}" ]] || return 0
  if ! jq -e --arg email "${name}" '.inbounds[] | select(.tag=="trojan-xhttp-tls") | .settings.clients[]? | select(.email==$email)' "${XRAY_CONFIG}" >/dev/null; then
    return 0
  fi
  tmp="$(mktemp)"
  backup="$(mktemp)"
  cp "${XRAY_CONFIG}" "${backup}"
  jq --arg email "${name}" \
    '(.inbounds[] | select(.tag=="trojan-xhttp-tls") | .settings.clients) |= map(select(.email != $email))' \
    "${XRAY_CONFIG}" >"${tmp}"
  install -m 0600 "${tmp}" "${XRAY_CONFIG}"
  rm -f "${tmp}"
  if ! /usr/local/bin/xray run -test -config "${XRAY_CONFIG}"; then
    install -m 0600 "${backup}" "${XRAY_CONFIG}"
    rm -f "${backup}"
    die "Xray config test failed; restored previous config."
  fi
  rm -f "${backup}"
  systemctl restart "${XRAY_SERVICE}" || true
}

revoke_hysteria() {
  local name="$1" tmp
  [[ -f "${HYSTERIA_CLIENTS}" ]] || return 0
  if ! jq -e --arg name "${name}" 'has($name)' "${HYSTERIA_CLIENTS}" >/dev/null; then
    return 0
  fi
  tmp="$(mktemp)"
  jq --arg name "${name}" 'del(.[$name])' "${HYSTERIA_CLIENTS}" >"${tmp}"
  install -m 0600 "${tmp}" "${HYSTERIA_CLIENTS}"
  rm -f "${tmp}"
  render_hysteria_config
  systemctl restart "${HYSTERIA_SERVICE}" || true
}

revoke_subscription() {
  local key="$1" token meta name label trojan_label hysteria_label awg_label archive_dir
  token="$(resolve_token "${key}")" || die "Subscription not found: ${key}"
  meta="${SUB_DIR}/${token}/meta.json"
  name="$(jq -r '.name' "${meta}")"
  label="$(jq -r '.label' "${meta}")"
  trojan_label="$(jq -r '.labels.trojan' "${meta}")"
  hysteria_label="$(jq -r '.labels.hysteria' "${meta}")"
  awg_label="$(jq -r '.labels.awg' "${meta}")"

  revoke_trojan "${name}"
  revoke_hysteria "${name}"
  if command -v vpn-awg >/dev/null 2>&1; then
    vpn-awg revoke "${name}" || true
  fi

  rm -rf "${WEB_ROOT:?}/${token}"
  archive_file "${KEY_ROOT}/trojan/${trojan_label}.txt" "${KEY_ROOT}/trojan/revoked"
  archive_file "${KEY_ROOT}/hysteria/${hysteria_label}.txt" "${KEY_ROOT}/hysteria/revoked"
  archive_file "${KEY_ROOT}/awg/${awg_label}.conf" "${KEY_ROOT}/awg/revoked"

  archive_dir="${SUB_DIR}/revoked/$(date +%Y%m%d-%H%M%S)-${token}"
  install -d -m 0700 "$(dirname "${archive_dir}")"
  mv "${SUB_DIR}/${token}" "${archive_dir}"
  jq '.status = "revoked" | .revoked_at = now | .revoked_at_iso = (now | todateiso8601)' \
    "${archive_dir}/meta.json" >"${archive_dir}/meta.json.tmp" && mv "${archive_dir}/meta.json.tmp" "${archive_dir}/meta.json"
  chmod 0600 "${archive_dir}/meta.json"

  printf 'Revoked: %s\n' "${label}"
  printf 'Removed public files: %s/%s\n' "${WEB_ROOT}" "${token}"
  printf 'Archived metadata: %s\n' "${archive_dir}/meta.json"
}

show_subscription() {
  local key="$1" token meta
  token="$(resolve_token "${key}")" || die "Subscription not found: ${key}"
  meta="${SUB_DIR}/${token}/meta.json"
  jq -r '
    "Subscription: \(.label)",
    "Name: \(.name)",
    "Status: \(.status)",
    "Created: \(.created_at)",
    "Portal/import URL: \(.urls.portal)",
    "Plain payload: \(.urls.sub_txt)",
    "Base64 payload: \(.urls.sub_base64)",
    "AmneziaWG config: \(.urls.awg_conf)",
    "AmneziaWG preview: \(.urls.awg_preview)"
  ' "${meta}"
  print_qr "$(jq -r '.urls.portal' "${meta}")"
}

list_subscriptions() {
  local meta
  install -d -m 0700 "${SUB_DIR}"
  printf 'NAME\tLABEL\tSTATUS\tCREATED\tPORTAL\n'
  for meta in "${SUB_DIR}"/*/meta.json; do
    [[ -e "${meta}" ]] || continue
    jq -r '[.name, .label, .status, .created_at, .urls.portal] | @tsv' "${meta}"
  done
}

rotate_subscription() {
  local key="$1" token name
  token="$(resolve_token "${key}")" || die "Subscription not found: ${key}"
  name="$(jq -r '.name' "${SUB_DIR}/${token}/meta.json")"
  revoke_subscription "${token}"
  create_subscription "${name}"
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."
cmd="${1:-help}"
case "${cmd}" in
  create)
    [[ -n "${2:-}" ]] || die "Usage: vpn-sub create <name>"
    create_subscription "${2}"
    ;;
  list)
    list_subscriptions
    ;;
  show)
    [[ -n "${2:-}" ]] || die "Usage: vpn-sub show <name>"
    show_subscription "${2}"
    ;;
  revoke)
    [[ -n "${2:-}" ]] || die "Usage: vpn-sub revoke <name>"
    revoke_subscription "${2}"
    ;;
  rotate)
    [[ -n "${2:-}" ]] || die "Usage: vpn-sub rotate <name>"
    rotate_subscription "${2}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "Unknown command: ${cmd}"
    ;;
esac
EOF
  chmod 0755 /usr/local/bin/vpn-sub
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
  local location="XX"
  if [[ -r "/opt/vpn-stack/server-location.txt" ]]; then
    location="$(</opt/vpn-stack/server-location.txt)"
  fi
  location="$(printf '%s' "${location}" | tr '[:lower:]' '[:upper:]')"
  if [[ ! "${location}" =~ ^[A-Z]{2}$ ]]; then
    location="XX"
  fi

  if [[ "${name}" == "${prefix}-${location}-"* ]]; then
    printf '%s' "${name}"
  else
    printf '%s-%s-%s' "${prefix}" "${location}" "${name}"
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

Create Hiddify-style static subscription bundle:
  vpn-sub create phone1
  vpn-sub list
  vpn-sub show phone1
  vpn-sub revoke phone1
  vpn-sub rotate phone1

AmneziaWG diagnostics:
  vpn-awg analyze
  vpn-awg analyze 20
  vpn-awg capture 30
  vpn-awg analyze-live 20
  vpn-awg profile
  vpn-awg explain
  vpn-awg show-config

Saved keys:
  /root/vpn-keys/trojan/TROJAN-<LOCATION>-<name>.txt
  /root/vpn-keys/hysteria/HYSTERIA-<LOCATION>-<name>.txt
  /root/vpn-keys/awg/AWG-<LOCATION>-<name>.conf

Show saved client material:
  vpn-help trojan phone1
  vpn-help tls phone1
  vpn-help xhttp phone1
  vpn-help hysteria phone1
  vpn-help awg phone1

AmneziaWG lifecycle:
  vpn-awg list
  vpn-awg show phone1
  vpn-awg revoke phone1
  vpn-awg rotate phone1

Install reports:
  /root/vpn-keys/install-report.txt
  /root/vpn-keys/install-report.json
  /opt/vpn-stack/awg-tuning-report.json
  /opt/vpn-stack/decoy-manifest.json

Subscription files:
  metadata: /opt/vpn-stack/subscriptions/<token>/meta.json
  public: /var/www/subscriptions/<token>/
  browser/import URL: https://DOMAIN/s/<token>

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
  install_helper_subscriptions
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

load_installed_context() {
  [[ -n "${DOMAIN:-}" ]] || DOMAIN="$(cat "${STACK_DIR}/domain.txt" 2>/dev/null || true)"
  [[ -n "${SERVER_LOCATION:-}" ]] || SERVER_LOCATION="$(cat "${STACK_DIR}/server-location.txt" 2>/dev/null || true)"
  [[ -n "${PUBLIC_IPV4:-}" ]] || PUBLIC_IPV4="$(cat "${STACK_DIR}/public-ipv4.txt" 2>/dev/null || true)"
  [[ -n "${EXT_IFACE:-}" ]] || EXT_IFACE="$(cat "${STACK_DIR}/external-interface.txt" 2>/dev/null || true)"
  SERVER_LOCATION="$(normalize_server_location "${SERVER_LOCATION:-XX}")"
  valid_server_location "${SERVER_LOCATION}" || SERVER_LOCATION="XX"
  [[ -n "${DOMAIN:-}" ]] && CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
}

current_awg_port() {
  local port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}"
  if [[ -f "${STACK_DIR}/awg-params.env" ]]; then
    # shellcheck disable=SC1091
    source "${STACK_DIR}/awg-params.env"
    port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}"
  fi
  printf '%s\n' "${port}"
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

listen_nonlocal_port() {
  local proto="$1"
  local port="$2"
  ss -H -lntup 2>/dev/null | awk -v proto="${proto}" -v port=":${port}" '
    tolower($1) == proto && $5 ~ (port "$") &&
      $5 !~ /^127\.0\.0\.1:/ && $5 !~ /^\[::1\]:/ && $5 !~ /^::1:/ { found=1 }
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
  local awg_port
  local -a missing
  awg_port="$(current_awg_port)"

  log "Waiting up to ${timeout}s for expected listening ports."
  while true; do
    missing=()

    listen_any_port tcp 443 || missing+=("443/tcp")
    listen_any_port udp 8443 || missing+=("8443/udp")
    listen_any_port udp "${awg_port}" || missing+=("${awg_port}/udp")
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
  local dashboard_status awg_port awg_profile awg_effective awg_mtu decoy_profile decoy_seed cert_issuer cert_expiry swap_result
  load_installed_context
  awg_port="$(current_awg_port)"
  swap_result="$(swap_report_label)"
  if [[ -s /var/lib/grafana/dashboards/node-exporter-full-1860.json ]]; then
    dashboard_status="provisioned from local JSON"
  else
    dashboard_status="not provisioned; import dashboard ID 1860 manually"
  fi
  awg_profile="$(grep -E '^AWG_OBFS_PROFILE=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')"
  awg_effective="$(grep -E '^AWG_EFFECTIVE_PROFILE=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')"
  awg_mtu="$(grep -E '^AWG_MTU=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')"
  decoy_profile="$(jq -r '.profile // "unknown"' "${DECOY_MANIFEST}" 2>/dev/null || printf 'unknown')"
  decoy_seed="$(jq -r '.seed // "unknown"' "${DECOY_MANIFEST}" 2>/dev/null || printf 'unknown')"
  cert_issuer="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || printf 'unknown')"
  cert_expiry="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || printf 'unknown')"

  cat <<EOF

============================================================
Golden VPN stack summary
============================================================
Domain: ${DOMAIN}
Server IPv4: ${PUBLIC_IPV4}
Server location: ${SERVER_LOCATION}
External interface: ${EXT_IFACE}

Contours:
  Trojan XHTTP TLS   : service $(service_summary xray-trojan-xhttp-tls); external 443/tcp via nginx $(listen_label any tcp 443); backend ${TROJAN_XHTTP_SOCKET} $(socket_label "${TROJAN_XHTTP_SOCKET}")
  Hysteria2 Salamander: service $(service_summary hysteria2); external 8443/udp $(listen_label any udp 8443)
  AmneziaWG 2.0       : service $(service_summary awg-quick@awg0); external ${awg_port}/udp $(listen_label any udp "${awg_port}"); interface awg0
  Decoy HTTPS site    : nginx $(service_summary nginx); https://${DOMAIN}/; randomized static site on 443/tcp

TLS certificate:
  Issuer: ${cert_issuer}
  Expires: ${cert_expiry}

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
  Obfuscation profile: ${awg_profile}
  Effective profile: ${awg_effective}
  MTU: ${awg_mtu}
  Tuning report: ${AWG_TUNING_REPORT}
  Full status: vpn-awg analyze
  Status + explicit short capture: vpn-awg analyze 20
  Save pcap: vpn-awg capture 30

Decoy:
  Profile: ${decoy_profile}
  Seed: ${decoy_seed}
  Manifest: ${DECOY_MANIFEST}

Swap:
  Status: ${swap_result}
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
  ${KEY_DIR}/trojan/TROJAN-${SERVER_LOCATION}-main-trojan.txt
  ${KEY_DIR}/hysteria/HYSTERIA-${SERVER_LOCATION}-main-hysteria-client.txt
  ${KEY_DIR}/awg/AWG-${SERVER_LOCATION}-main-awg.conf

Create more clients:
  vpn-trojan phone1
  vpn-hysteria phone1
  vpn-awg phone1

Subscription bundles:
  Create: vpn-sub create phone1
  Show: vpn-sub show phone1
  Browser/import URL shape: https://${DOMAIN}/s/<token>
  Plain payload: https://${DOMAIN}/s/<token>/sub.txt
  AmneziaWG download: https://${DOMAIN}/s/<token>/awg.conf
  Metadata root: ${SUBSCRIPTION_DIR}
  Public root: ${SUBSCRIPTION_WEB_DIR}

  vpn-help

Install reports:
  ${INSTALL_REPORT_TXT}
  ${INSTALL_REPORT_JSON}
============================================================
EOF
}

generate_install_report() {
  local awg_port awg_profile awg_effective awg_mtu decoy_profile decoy_seed cert_issuer cert_expiry swap_active dashboard_status swap_result
  load_installed_context
  awg_port="$(current_awg_port)"
  swap_result="$(swap_report_label)"
  awg_profile="$(grep -E '^AWG_OBFS_PROFILE=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')"
  awg_effective="$(grep -E '^AWG_EFFECTIVE_PROFILE=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')"
  awg_mtu="$(grep -E '^AWG_MTU=' "${STACK_DIR}/awg-params.env" 2>/dev/null | cut -d= -f2- || printf 'unknown')"
  decoy_profile="$(jq -r '.profile // "unknown"' "${DECOY_MANIFEST}" 2>/dev/null || printf 'unknown')"
  decoy_seed="$(jq -r '.seed // "unknown"' "${DECOY_MANIFEST}" 2>/dev/null || printf 'unknown')"
  cert_issuer="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || printf 'unknown')"
  cert_expiry="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || printf 'unknown')"
  if swapon --show | awk 'NR>1 {found=1} END {exit found ? 0 : 1}'; then
    swap_active="true"
  else
    swap_active="false"
  fi
  if [[ -s /var/lib/grafana/dashboards/node-exporter-full-1860.json ]]; then
    dashboard_status="provisioned"
  else
    dashboard_status="manual-import"
  fi

  install -d -m 0700 "${KEY_DIR}"
  print_install_summary >"${INSTALL_REPORT_TXT}"
  chmod 0600 "${INSTALL_REPORT_TXT}"

  cat >"${INSTALL_REPORT_JSON}" <<EOF
{
  "generated_at": $(json_escape "$(date -Is)"),
  "domain": $(json_escape "${DOMAIN:-unknown}"),
  "server_ipv4": $(json_escape "${PUBLIC_IPV4:-unknown}"),
  "server_location": $(json_escape "${SERVER_LOCATION:-XX}"),
  "external_interface": $(json_escape "${EXT_IFACE:-unknown}"),
  "contours": {
    "trojan_xhttp_tls": {
      "external": "443/tcp",
      "service": $(json_escape "$(service_summary xray-trojan-xhttp-tls)"),
      "backend_socket": $(json_escape "${TROJAN_XHTTP_SOCKET}")
    },
    "hysteria2_salamander": {
      "external": "8443/udp",
      "service": $(json_escape "$(service_summary hysteria2)")
    },
    "amneziawg": {
      "external": $(json_escape "${awg_port}/udp"),
      "service": $(json_escape "$(service_summary awg-quick@awg0)"),
      "profile": $(json_escape "${awg_profile}"),
      "effective_profile": $(json_escape "${awg_effective}"),
      "mtu": $(json_escape "${awg_mtu}"),
      "params_path": $(json_escape "${STACK_DIR}/awg-params.env"),
      "tuning_report": $(json_escape "${AWG_TUNING_REPORT}")
    }
  },
  "monitoring": {
    "grafana": "127.0.0.1:3000",
    "prometheus": "127.0.0.1:9090",
    "node_exporter": "127.0.0.1:9100",
    "grafana_tunnel": $(json_escape "ssh -L 3000:127.0.0.1:3000 root@${PUBLIC_IPV4:-SERVER_IP}"),
    "dashboard_1860": $(json_escape "${dashboard_status}")
  },
  "tls_certificate": {
    "issuer": $(json_escape "${cert_issuer}"),
    "expires": $(json_escape "${cert_expiry}")
  },
  "decoy": {
    "url": $(json_escape "https://${DOMAIN:-DOMAIN}/"),
    "profile": $(json_escape "${decoy_profile}"),
    "seed": $(json_escape "${decoy_seed}"),
    "manifest": $(json_escape "${DECOY_MANIFEST}")
  },
  "swap": {
    "active": ${swap_active},
    "status": $(json_escape "${swap_result}")
  },
  "key_paths": {
    "trojan": $(json_escape "${KEY_DIR}/trojan"),
    "hysteria": $(json_escape "${KEY_DIR}/hysteria"),
    "awg": $(json_escape "${KEY_DIR}/awg")
  },
  "subscriptions": {
    "helper": "vpn-sub",
    "metadata_root": $(json_escape "${SUBSCRIPTION_DIR}"),
    "public_root": $(json_escape "${SUBSCRIPTION_WEB_DIR}"),
    "url_shape": $(json_escape "https://${DOMAIN:-DOMAIN}/s/<token>"),
    "payload": "sub.txt contains Trojan and Hysteria2 links; awg.conf is downloadable separately",
    "token_policy": "unguessable per-subscription tokens are never included in install reports"
  }
}
EOF
  chmod 0600 "${INSTALL_REPORT_JSON}"
  log "Install reports saved: ${INSTALL_REPORT_TXT}, ${INSTALL_REPORT_JSON}"
}

validate_stack() {
  local failed=0 awg_port
  load_installed_context
  awg_port="$(current_awg_port)"

  check_pass() {
    local label="$1"
    shift
    if "$@"; then
      printf 'PASS %s\n' "${label}"
    else
      printf 'FAIL %s\n' "${label}"
      failed=1
    fi
  }

  check_absent() {
    local label="$1"
    shift
    if "$@"; then
      printf 'FAIL %s\n' "${label}"
      failed=1
    else
      printf 'PASS %s\n' "${label}"
    fi
  }

  printf 'Golden VPN validation\n\n'
  check_pass "443/tcp public listener" listen_any_port tcp 443
  check_pass "8443/udp public listener" listen_any_port udp 8443
  check_pass "${awg_port}/udp public listener" listen_any_port udp "${awg_port}"
  check_pass "Trojan XHTTP unix socket" test -S "${TROJAN_XHTTP_SOCKET}"
  check_pass "Grafana localhost 3000" listen_local_port tcp 3000
  check_pass "Prometheus localhost 9090" listen_local_port tcp 9090
  check_pass "Node Exporter localhost 9100" listen_local_port tcp 9100
  check_absent "Grafana not public" listen_nonlocal_port tcp 3000
  check_absent "Prometheus not public" listen_nonlocal_port tcp 9090
  check_absent "Node Exporter not public" listen_nonlocal_port tcp 9100
  check_pass "nginx active" systemctl is-active --quiet nginx
  check_pass "xray-trojan-xhttp-tls active" systemctl is-active --quiet xray-trojan-xhttp-tls
  check_pass "hysteria2 active" systemctl is-active --quiet hysteria2
  check_pass "awg-quick@awg0 active" systemctl is-active --quiet awg-quick@awg0
  check_pass "prometheus active" systemctl is-active --quiet prometheus
  check_pass "node exporter active" systemctl is-active --quiet prometheus-node-exporter
  check_pass "grafana active" systemctl is-active --quiet grafana-server
  check_pass "decoy forbidden-word scan" scan_decoy_tree /var/www/decoy
  check_pass "certificate readable" openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout
  check_pass "private key readable" openssl pkey -in "${CERT_DIR}/privkey.pem" -noout
  if [[ -n "${DOMAIN:-}" ]]; then
    check_pass "decoy HTTPS responds" curl -fsSk -o /dev/null "https://${DOMAIN}/"
  fi

  printf '\n'
  if [[ "${failed}" -eq 0 ]]; then
    log "Validation passed."
  else
    die "Validation failed."
  fi
}

final_checks() {
  local awg_port
  awg_port="$(current_awg_port)"
  log "Final listening socket check."
  set +e
  ss -lntup | grep -E ":443|:8443|:${awg_port}|:3000|:9090|:9100"
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
    "${KEY_DIR}/trojan/TROJAN-${SERVER_LOCATION}-main-trojan.txt" \
    "${KEY_DIR}/hysteria/HYSTERIA-${SERVER_LOCATION}-main-hysteria-client.txt" \
    "${KEY_DIR}/awg/AWG-${SERVER_LOCATION}-main-awg.conf"
  log "Optional helper smoke tests create extra clients:"
  printf '  vpn-trojan test-trojan\n  vpn-hysteria test-hy2\n  vpn-awg test-awg\n'
  generate_install_report
  print_install_summary
}

bootstrap_install() {
  INSTALL_TOTAL_STEPS=6
  INSTALL_STEP=0

  progress "Clearing stale one-time resume state"
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
  cleanup_resume_install_state

  progress "Collecting installer variables"
  export VPN_STACK_IGNORE_SAVED_ENV=1
  require_root_and_env
  prompt_advanced_tuning

  progress "Installing bootstrap packages"
  install_bootstrap_packages

  progress "Preparing SSH and firewall access"
  install_resume_status_helper
  ensure_ssh_firewall_access require-listener || die "SSH listener check failed before reboot. Start openssh-server manually, then rerun bootstrap."

  progress "Scheduling one-shot stage2 install"
  export VPN_STACK_NO_AUTO_REBOOT=1
  schedule_resume_install_once

  progress "Rebooting into stage2"
  log "The installer will continue once after reboot."
  log "After SSH returns, watch it with: vpn-install-status watch"
  systemctl reboot
  exit 0
}

main() {
  progress "Checking input variables and kernel readiness"
  require_root_and_env
  install_resume_status_helper
  prompt_advanced_tuning
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

preflight_check() {
  local failed=0

  pass() { printf 'PASS %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; failed=1; }
  warn_check() { printf 'WARN %s\n' "$1"; }

  printf 'Golden VPN preflight\n\n'

  if [[ "${EUID}" -eq 0 ]]; then pass "running as root"; else fail "run as root"; fi
  if [[ -n "${DOMAIN:-}" ]]; then pass "DOMAIN is set"; else fail "DOMAIN is empty"; fi
  if [[ -n "${EMAIL:-}" ]] && valid_ascii_email "$(trim_value "${EMAIL:-}")"; then pass "EMAIL is valid ASCII"; else fail "EMAIL is missing or invalid"; fi
  if [[ -n "${SERVER_LOCATION:-}" ]] && valid_server_location "$(normalize_server_location "${SERVER_LOCATION:-}")"; then pass "SERVER_LOCATION is valid"; else fail "SERVER_LOCATION must be two ASCII letters"; fi
  if [[ -n "${CF_Token:-}" ]]; then pass "CF_Token is set"; else fail "CF_Token is empty"; fi

  if command -v curl >/dev/null 2>&1; then pass "curl is available"; else fail "curl is missing"; fi
  if command -v jq >/dev/null 2>&1; then pass "jq is available"; else warn_check "jq is not installed yet; installer will install it"; fi
  if command -v ss >/dev/null 2>&1; then pass "ss is available"; else warn_check "ss is not installed yet"; fi

  if [[ -n "${DOMAIN:-}" ]] && command -v getent >/dev/null 2>&1; then
    if getent ahostsv4 "${DOMAIN}" >/dev/null 2>&1; then pass "DOMAIN resolves"; else fail "DOMAIN does not resolve"; fi
  fi

  if command -v curl >/dev/null 2>&1; then
    if PUBLIC_IPV4="$(curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null)" && [[ "${PUBLIC_IPV4}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      pass "public IPv4 detected: ${PUBLIC_IPV4}"
    else
      fail "public IPv4 was not detected"
    fi
  fi

  if EXT_IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')" && [[ -n "${EXT_IFACE}" ]]; then
    pass "external interface detected: ${EXT_IFACE}"
  else
    fail "external interface was not detected"
  fi

  if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
    fail "apt/dpkg lock is currently held"
  else
    pass "apt/dpkg locks are free"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    warn_check "kernel/package reboot is already required"
  else
    pass "no pending reboot marker"
  fi

  if ss -lntp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:22[[:space:]]'; then
    pass "SSH listener on 22/tcp is present"
  else
    warn_check "SSH listener on 22/tcp was not detected"
  fi

  printf '\n'
  if [[ "${failed}" -eq 0 ]]; then
    log "Preflight passed."
  else
    die "Preflight failed."
  fi
}

run_with_install_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 200>"${INSTALL_LOCK}"
    if ! flock -n 200; then
      warn "Another Golden VPN installation is already running."
      warn "Do not start a second installer while apt/dpkg is active."
      if [[ -x "${INSTALL_STATUS_HELPER}" ]]; then
        warn "Watch progress with: vpn-install-status watch"
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

show_installer_usage() {
  cat <<'USAGE'
Usage:
  ./install-vpn-stack.sh                 Run two-stage bootstrap, schedule stage2, and reboot once
  ./install-vpn-stack.sh bootstrap       Same as default two-stage bootstrap
  ./install-vpn-stack.sh install         Run stage2/full install now
  ./install-vpn-stack.sh preflight       Check inputs and host readiness without changing VPN configs
  ./install-vpn-stack.sh validate        Validate installed listeners, services, cert, and decoy
  ./install-vpn-stack.sh verify          Alias for validate
  ./install-vpn-stack.sh report          Write and print install reports
  ./install-vpn-stack.sh render-decoy [dir]  Render decoy site into dir without touching nginx

During stage2:
  vpn-install-status watch
USAGE
}

dispatch() {
  local cmd="${1:-bootstrap}"
  local out_dir
  case "${cmd}" in
    bootstrap|stage1|"")
      shift || true
      run_with_bootstrap_lock() {
        if command -v flock >/dev/null 2>&1; then
          exec 200>"${INSTALL_LOCK}"
          if ! flock -n 200; then
            warn "Another Golden VPN installation is already running."
            [[ -x "${INSTALL_STATUS_HELPER}" ]] && warn "Watch progress with: vpn-install-status watch"
            exit 75
          fi
        fi
        bootstrap_install "$@"
      }
      run_with_bootstrap_lock "$@"
      ;;
    install|stage2)
      shift || true
      run_with_install_lock "$@"
      ;;
    preflight|preflight-only|--preflight)
      preflight_check
      ;;
    validate|verify|--validate-only)
      validate_stack
      ;;
    report)
      generate_install_report
      cat "${INSTALL_REPORT_TXT}"
      ;;
    render-decoy|--render-only)
      out_dir="${2:-/tmp/golden-vpn-decoy-render}"
      render_decoy_site "${out_dir}" "${out_dir}/decoy-manifest.json"
      printf 'Rendered decoy site: %s\nManifest: %s\n' "${out_dir}" "${out_dir}/decoy-manifest.json"
      ;;
    help|-h|--help)
      show_installer_usage
      ;;
    *)
      show_installer_usage >&2
      die "Unknown command: ${cmd}"
      ;;
  esac
}

dispatch "$@"
