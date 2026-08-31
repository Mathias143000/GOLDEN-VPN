#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
export APT_LISTCHANGES_FRONTEND="${APT_LISTCHANGES_FRONTEND:-none}"

: "${APT_LOCK_TIMEOUT:=1800}"

GOLDEN_VPN_VERSION="2026.08.31-hiddify-json"

STACK_DIR="/opt/vpn-stack"
KEY_DIR="/root/vpn-keys"
XRAY_DIR="${STACK_DIR}/xray"
HYSTERIA_DIR="${STACK_DIR}/hysteria"
HYSTERIA_PROFILE_DIR="${STACK_DIR}/hysteria-profiles"
LOG_DIR="/var/log/vpn-stack"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN:-}"
SUBSCRIPTION_DIR="${STACK_DIR}/subscriptions"
SUBSCRIPTION_WEB_DIR="/var/www/subscriptions"
TROJAN_XHTTP_SOCKET="/dev/shm/xray-trojan-xhttp.sock"
TROJAN_HELPER_PATH="/usr/local/bin/vpn-trojan"
HIDDIFY_PROFILE_HELPER_PATH="/usr/local/bin/vpn-hiddify-profile"
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
UPGRADE_BACKUP_ROOT="${KEY_DIR}/upgrade-backups"
UPGRADE_REPORT="${KEY_DIR}/upgrade-report.json"
VLESS_TROJAN_MIGRATION_ROOT="/root/vpn-migration/vless-to-trojan"
VLESS_TROJAN_MIGRATION_REPORT="${KEY_DIR}/vless-to-trojan-report.json"
AWG_MTU_MIGRATION_ROOT="/root/vpn-migration/awg-mtu"
AWG_MTU_MIGRATION_REPORT="${KEY_DIR}/awg-mtu-migration-report.json"
INSTALLER_VERSION_FILE="${STACK_DIR}/installer-version.txt"
DECOY_MANIFEST="${STACK_DIR}/decoy-manifest.json"
AWG_TUNING_REPORT="${STACK_DIR}/awg-tuning-report.json"
AWG_CONFIG="/etc/amnezia/amneziawg/awg0.conf"
AWG_DEFAULT_PORT=443
AWG_INTERNAL_LISTEN_PORT=51820
AWG_PROTOCOL_VERSION="3.1"
AWG_TOOLS_SOURCE_TAG="v3.1.20260812"
HYSTERIA_SALAMANDER_PORT=8443
HYSTERIA_SALAMANDER_LISTEN="8443,20000-50000"
HYSTERIA_PORT_MIN=20000
HYSTERIA_PORT_MAX=59999
BOOTSTRAP_MIN_FREE_MB=1024
INSTALL_MIN_FREE_MB=5120
INSTALL_RESUME_MIN_FREE_MB=3072
UPGRADE_MIN_FREE_MB=256
MIN_FREE_INODE_PERCENT=5
INSTALL_TOTAL_STEPS=25
INSTALL_STEP=0
PUBLIC_IPV4=""
EXT_IFACE=""
SWAP_RESULT="not checked"
DKMS_KERNEL_REBOOT_PROMPTED=0
COMPACT_INSTALL_UI=0

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
  logrotate
  gnupg
  iptables
  iproute2
  iputils-ping
  util-linux
  tcpdump
  python3
  build-essential
  dkms
  nginx
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

root_free_mb() {
  df -Pk / | awk 'NR == 2 {print int($4 / 1024)}'
}

root_free_inode_percent() {
  df -Pi / | awk 'NR == 2 {gsub(/%/, "", $5); print 100 - $5}'
}

storage_hint() {
  local path="$1"
  {
    echo "Storage diagnostics for ${path}:"
    df -h "${path}" 2>/dev/null || true
    df -ih "${path}" 2>/dev/null || true
  } >&2
}

base_package_stage_complete() {
  local package status
  command -v dpkg-query >/dev/null 2>&1 || return 1
  for package in jq nginx grafana prometheus; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null || true)"
    [[ "${status}" == ii* ]] || return 1
  done
}

install_required_free_mb() {
  if base_package_stage_complete; then
    printf '%s\n' "${INSTALL_RESUME_MIN_FREE_MB}"
  else
    printf '%s\n' "${INSTALL_MIN_FREE_MB}"
  fi
}

require_install_storage() {
  local required_mb="$1" stage="$2" free_mb free_inode_percent
  free_mb="$(root_free_mb)"
  free_inode_percent="$(root_free_inode_percent)"

  if [[ ! "${free_mb}" =~ ^[0-9]+$ ]] || [[ ! "${free_inode_percent}" =~ ^[0-9]+$ ]]; then
    die "Could not determine free disk space and inode capacity on /."
  fi

  if ((free_mb < required_mb)); then
    storage_hint /
    die "${stage} requires at least ${required_mb} MB free on /; only ${free_mb} MB is available. Clean logs/cache or enlarge the disk, then retry."
  fi

  if ((free_inode_percent < MIN_FREE_INODE_PERCENT)); then
    storage_hint /
    die "${stage} requires at least ${MIN_FREE_INODE_PERCENT}% free inodes on /; only ${free_inode_percent}% is available."
  fi

  log "Storage gate passed for ${stage}: ${free_mb} MB and ${free_inode_percent}% inodes free on /."
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

  if ((percent < 34)); then
    color=$'\033[31m'
  elif ((percent < 67)); then
    color=$'\033[33m'
  else
    color=$'\033[32m'
  fi
  reset=$'\033[0m'

  if [[ "${COMPACT_INSTALL_UI}" == "1" ]] && have_tty; then
    {
      printf '\033[H'
      printf 'Golden VPN installer\n\n'
      printf '%s[%s]%s %s%% (%s/%s) %s\n' \
        "${color}" "${bar}" "${reset}" "${percent}" "${INSTALL_STEP}" "${INSTALL_TOTAL_STEPS}" "${message}"
      printf 'Updated: %s\n' "$(date -Is)"
      printf 'Full log: %s\n\n' "${RESUME_INSTALL_LOG}"
      printf 'Important messages:\n'
      important_log_tail "${RESUME_INSTALL_LOG}" 12
      printf '\033[J'
    } >/dev/tty
  elif [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
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

important_log_tail() {
  local file="$1" lines="${2:-12}" output
  if [[ ! -r "${file}" ]]; then
    printf 'None.\n'
    return 0
  fi
  output="$(awk '
    BEGIN { IGNORECASE=1 }
    /\[vpn-stack\] (WARNING|ERROR):/ ||
    /resume install (failed|succeeded)/ ||
    /(^|[^[:alpha:]])(error|failed|failure|fatal|giving up|could not|invalid)([^[:alpha:]]|$)/ { print }
  ' "${file}" | tail -n "${lines}" || true)"
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  else
    printf 'None.\n'
  fi
}

enable_compact_install_ui() {
  local mode="${1:-append}"
  [[ -t 1 && "${TERM:-}" != "dumb" ]] || return 0
  have_tty || return 0
  install -d -m 0755 "$(dirname "${RESUME_INSTALL_LOG}")"
  if [[ "${mode}" == "reset" ]]; then
    : >"${RESUME_INSTALL_LOG}"
  else
    touch "${RESUME_INSTALL_LOG}"
  fi
  chmod 0600 "${RESUME_INSTALL_LOG}" || true
  COMPACT_INSTALL_UI=1
  printf '\033[2J\033[H' >/dev/tty
  exec >>"${RESUME_INSTALL_LOG}" 2>&1
}

on_error() {
  local line="$1"
  warn "Installation failed near line ${line}. Check the messages above."
  if [[ "${COMPACT_INSTALL_UI}" == "1" ]] && have_tty; then
    important_log_tail "${RESUME_INSTALL_LOG}" 12 >/dev/tty
  fi
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
      export "${var?}"
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
  export "${var?}"
}

prompt_advanced_tuning() {
  [[ "${VPN_STACK_ASSUME_DEFAULTS:-0}" != "1" ]] || return 0
  [[ "${VPN_STACK_RESUMED:-0}" != "1" ]] || return 0
  prompt_yes_no_default_no "Advanced tuning?" || return 0

  prompt_optional_var AWG_OBFS_PROFILE "AWG_OBFS_PROFILE" "${AWG_OBFS_PROFILE:-random-balanced}"
  prompt_optional_var AWG_MTU "AWG_MTU" "${AWG_MTU:-1420}"
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
      AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5 AWG_HEADER_PROTECTION_KEY \
      AWG_CONTENT_PADDING_ADDITION AWG_REKEY_AFTER_TIME AWG_REKEY_TIMEOUT AWG_REJECT_AFTER_TIME \
      AWG_KEEPALIVE_TIMEOUT AWG_MAX_HANDSHAKE_ATTEMPTS AWG_RANDOM_TRAILERS AWG_DISABLE_COOKIES \
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
env_file="/etc/golden-vpn-installer/install.env"
installer="/root/vpn-stack-resume/install-vpn-stack.sh"
service_unit="/etc/systemd/system/vpn-stack-resume-install.service"
timer_unit="/etc/systemd/system/vpn-stack-resume-install.timer"
WATCH_SCREEN_INITIALIZED=0
WATCH_LAST_FRAME=""

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

lock_held() {
  command -v fuser >/dev/null 2>&1 && fuser "${lock_file}" >/dev/null 2>&1
}

service_active() {
  [[ -e "${service_unit}" ]] \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl is-active --quiet "${service}" 2>/dev/null
}

timer_active() {
  [[ -e "${timer_unit}" ]] \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl is-active --quiet "${timer}" 2>/dev/null
}

resume_units_present() {
  [[ -e "${service_unit}" || -e "${timer_unit}" ]]
}

has_state() {
  lock_held || resume_units_present || [[ -r "${env_file}" || -x "${installer}" ]]
}

auto_watch_needed() {
  lock_held || resume_units_present || service_active || timer_active
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

important_log_tail() {
  local lines="${1:-22}" output
  if [[ ! -r "${log_file}" ]]; then
    echo "No warnings or errors yet."
    return 0
  fi
  output="$(awk '
    BEGIN { IGNORECASE=1 }
    /\[vpn-stack\] (WARNING|ERROR):/ ||
    /resume install (failed|succeeded)/ ||
    /(^|[^[:alpha:]])(error|failed|failure|fatal|giving up|could not|invalid)([^[:alpha:]]|$)/ { print }
  ' "${log_file}" | tail -n "${lines}" || true)"
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  else
    echo "None."
  fi
}

render_watch_content() {
  local lines="${1:-22}"
  echo "Golden VPN installer watch"
  echo
  render_bar
  printf 'Updated: %s\n' "${UPDATED_AT:-unknown}"
  printf 'Service: '
  systemctl is-active "${service}" 2>/dev/null || true
  printf 'Timer: '
  systemctl is-active "${timer}" 2>/dev/null || true
  printf 'Full log: %s\n\n' "${log_file}"
  echo "Important messages:"
  important_log_tail "${lines}"
}

render_watch_screen() {
  local lines="${1:-22}" frame
  frame="$(render_watch_content "${lines}")"

  # Do not repaint an unchanged screen. Clearing the terminal every second
  # causes visible flashes in SSH clients, especially on slower links.
  if [[ "${frame}" == "${WATCH_LAST_FRAME}" ]]; then
    return 0
  fi

  if ((WATCH_SCREEN_INITIALIZED == 0)); then
    printf '\033[2J\033[H'
    WATCH_SCREEN_INITIALIZED=1
  else
    printf '\033[H'
  fi
  printf '%s\n' "${frame}"
  printf '\033[J'
  WATCH_LAST_FRAME="${frame}"
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

auto_status() {
  local lines="${1:-22}"
  [[ "${lines}" =~ ^[0-9]+$ ]] || lines=22

  if ! has_state; then
    return 1
  fi

  if [[ ! -t 1 || "${TERM:-}" == "dumb" ]]; then
    show_status
    return 0
  fi

  if ! auto_watch_needed; then
    show_status
    return 0
  fi

  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true; printf "\n"' EXIT INT TERM
  while auto_watch_needed; do
    render_watch_screen "${lines}"
    sleep 1
  done
  render_watch_screen "${lines}"
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
    render_watch_screen "${lines}"
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
  auto)
    auto_status "${2:-22}"
    ;;
  has-state)
    has_state
    ;;
  status|"")
    show_status
    ;;
  *)
    echo "Usage: vpn-install-status [status|watch [lines]|auto [lines]|follow|log [lines]|has-state]" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "${INSTALL_STATUS_HELPER}"
}

install_shell_startup_hook() {
  local bashrc="/root/.bashrc"
  local tmp

  install -d -m 0700 /root
  touch "${bashrc}"
  chmod 0600 "${bashrc}" || true

  tmp="$(mktemp /root/.bashrc.golden-vpn.XXXXXX)" || die "Could not create temporary /root/.bashrc file; check disk space and inodes."
  awk '
    $0 == "# >>> Golden VPN startup >>>" {skip=1; next}
    $0 == "# <<< Golden VPN startup <<<" {skip=0; next}
    skip != 1 {print}
  ' "${bashrc}" >"${tmp}"
  cat "${tmp}" >"${bashrc}"
  rm -f "${tmp}"

  cat >>"${bashrc}" <<'EOF'
# >>> Golden VPN startup >>>
if [[ $- == *i* ]] && [[ -t 1 ]] && [[ -z "${GOLDEN_VPN_STARTUP_SHOWN:-}" ]] && [[ "${GOLDEN_VPN_NO_STARTUP:-0}" != "1" ]]; then
  export GOLDEN_VPN_STARTUP_SHOWN=1
  if command -v vpn-install-status >/dev/null 2>&1 && vpn-install-status has-state >/dev/null 2>&1; then
    vpn-install-status auto 24 || true
  fi
  if command -v vpn-help >/dev/null 2>&1 && { ! command -v vpn-install-status >/dev/null 2>&1 || ! vpn-install-status has-state >/dev/null 2>&1; }; then
    vpn-help --login || true
  fi
fi
# <<< Golden VPN startup <<<
EOF
  chmod 0600 "${bashrc}" || true
}

cleanup_resume_install_state() {
  local had_state=0
  for path in "${RESUME_INSTALL_UNIT}" "${RESUME_INSTALL_TIMER_UNIT}" "${RESUME_INSTALL_RUNNER}" "${RESUME_INSTALL_SCRIPT}" "${RESUME_INSTALL_ENV}" "${SSH_GUARD_UNIT}" "${SSH_GUARD_SCRIPT}"; do
    [[ -e "${path}" ]] && had_state=1
  done

  # Never stop the currently running resume service from inside itself. Stop
  # only its timer/guard so systemd cannot retain a ghost active timer after
  # their unit files are removed.
  systemctl stop "${RESUME_INSTALL_TIMER}" "${SSH_GUARD_SERVICE}" >/dev/null 2>&1 || true
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
  systemctl stop "\${timer}" "\${ssh_guard_service}" >/dev/null 2>&1 || true
  systemctl disable "\${service}" "\${timer}" "\${ssh_guard_service}" >/dev/null 2>&1 || true
  rm -f "\${unit}" "\${timer_unit}" "\${env_file}" "\${installer}" "\${runner}" "\${ssh_guard_unit}" "\${ssh_guard_script}"
  rmdir "\${resume_dir}" 2>/dev/null || true
  rmdir "\${env_dir}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
else
  printf '%s resume install failed; disabling one-time unit and keeping env/log for manual retry\n' "\$(date -Is)"
  systemctl stop "\${timer}" "\${ssh_guard_service}" >/dev/null 2>&1 || true
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

    if [[ "${mode}" == "prompt" && "${DKMS_KERNEL_REBOOT_PROMPTED}" != "1" ]] && reboot_prompt_enabled; then
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

issue_acme_certificate_with_retries() {
  local server="$1"
  shift
  local max_attempts="${VPN_STACK_ACME_ISSUE_ATTEMPTS:-3}"
  local retry_delay="${VPN_STACK_ACME_RETRY_DELAY:-15}"
  local attempt
  local -a acme=("$@")

  [[ "${max_attempts}" =~ ^[1-9][0-9]*$ ]] || die "VPN_STACK_ACME_ISSUE_ATTEMPTS must be a positive integer."
  [[ "${retry_delay}" =~ ^[0-9]+$ ]] || die "VPN_STACK_ACME_RETRY_DELAY must be a non-negative integer."

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    if "${acme[@]}" --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256 --server "${server}"; then
      return 0
    fi
    ((attempt < max_attempts)) || break
    warn "Certificate issuance/download through ${server} failed (attempt ${attempt}/${max_attempts}); retrying the saved ACME order in ${retry_delay}s."
    sleep "${retry_delay}"
  done
  return 1
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

  if [[ -s "${CERT_DIR}/fullchain.pem" && -s "${CERT_DIR}/privkey.pem" ]] \
    && openssl x509 -checkend 2592000 -noout -in "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1 \
    && openssl pkey -check -noout -in "${CERT_DIR}/privkey.pem" >/dev/null 2>&1; then
    log "Existing certificate is valid for at least 30 days."
    return
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

  if ! issue_acme_certificate_with_retries "${acme_server}" "${acme[@]}"; then
    if [[ "${acme_server}" != "zerossl" || "${VPN_STACK_DISABLE_LE_FALLBACK:-0}" == "1" ]]; then
      die "Certificate issuance through ${acme_server} failed."
    fi

    warn "ZeroSSL certificate issuance failed. Retrying with Let's Encrypt DNS-01."
    acme_server="letsencrypt"
    "${acme[@]}" --set-default-ca --server letsencrypt
    "${acme[@]}" --register-account -m "${EMAIL}" --server letsencrypt \
      || warn "Explicit Let's Encrypt account registration failed; acme.sh will retry it during issuance."
    issue_acme_certificate_with_retries letsencrypt "${acme[@]}" \
      || die "Certificate issuance failed through both ZeroSSL and Let's Encrypt."
  fi
  "${acme[@]}" --install-cert -d "${DOMAIN}" --ecc \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --key-file "${CERT_DIR}/privkey.pem" \
    --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true; systemctl restart hysteria2 hysteria2-gecko hysteria2-mimic >/dev/null 2>&1 || true; /usr/local/bin/vpn-cert-notify renewed >/dev/null 2>&1 || true"

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
  link="trojan://${password}@${domain}:443?security=tls&type=xhttp&path=${encoded_path}&mode=auto&sni=${domain}&host=${domain}&alpn=h2#${fragment}"
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

  cat >"${target_dir}/assets/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="${brand}">
  <rect width="64" height="64" rx="14" fill="${primary}"/>
  <path d="M14 39h8l6-17 8 27 6-16h8" fill="none" stroke="${surface}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
EOF

  cat >"${target_dir}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${brand} - Availability Monitoring</title>
  <link rel="stylesheet" href="/assets/style.css">
  <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
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
  chmod 0644 "${target_dir}/assets/style.css" "${target_dir}/assets/favicon.svg" "${target_dir}/index.html" "${target_dir}/status.html" "${target_dir}/docs.html" "${target_dir}/privacy.html" "${target_dir}/404.html" "${target_dir}/robots.txt"
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
    "assets/style.css",
    "assets/favicon.svg"
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
  printf '%s\n' "xray-trojan-xhttp-tls.service" >"${STACK_DIR}/trojan-xhttp-service.txt"
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
              mode: "auto"
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

  cat >/var/www/decoy/assets/favicon.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="${brand}">
  <rect width="64" height="64" rx="14" fill="${primary}"/>
  <path d="M14 39h8l6-17 8 27 6-16h8" fill="none" stroke="${surface}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
EOF

  cat >/var/www/decoy/index.html <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${brand} - Availability Monitoring</title>
  <link rel="stylesheet" href="/assets/style.css">
  <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
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
  chmod 0644 /var/www/decoy/assets/style.css /var/www/decoy/assets/favicon.svg /var/www/decoy/index.html /var/www/decoy/status.html /var/www/decoy/docs.html /var/www/decoy/privacy.html /var/www/decoy/404.html /var/www/decoy/robots.txt

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

random_free_hysteria_port() {
  local candidate attempt
  for attempt in $(seq 1 200); do
    candidate="$(shuf -i "${HYSTERIA_PORT_MIN}-${HYSTERIA_PORT_MAX}" -n 1)"
    [[ "${candidate}" != "${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}" ]] || continue
    if ! ss -H -lntup 2>/dev/null | awk -v port=":${candidate}" '$5 ~ (port "$") {found=1} END {exit found ? 0 : 1}'; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  die "Could not select a free Hysteria profile port."
}

ensure_hysteria_profile_state() {
  local file port other
  install -d -m 0700 "${HYSTERIA_DIR}" "${HYSTERIA_PROFILE_DIR}"
  for file in hysteria-obfs-gecko.txt hysteria-obfs-mimic.txt; do
    [[ -s "${STACK_DIR}/${file}" ]] || rand_hex 24 >"${STACK_DIR}/${file}"
    chmod 0600 "${STACK_DIR}/${file}"
  done
  for file in hysteria-gecko-port.txt hysteria-mimic-port.txt; do
    if [[ -s "${STACK_DIR}/${file}" ]]; then
      port="$(<"${STACK_DIR}/${file}")"
      if [[ ! "${port}" =~ ^[0-9]+$ ]] || ((port < 1024 || port > 65535)); then
        die "Invalid saved Hysteria port in ${STACK_DIR}/${file}."
      fi
      continue
    fi
    port="$(random_free_hysteria_port)"
    if [[ "${file}" == "hysteria-mimic-port.txt" ]]; then
      other="$(cat "${STACK_DIR}/hysteria-gecko-port.txt" 2>/dev/null || true)"
      while [[ "${port}" == "${other}" ]]; do port="$(random_free_hysteria_port)"; done
    fi
    printf '%s\n' "${port}" >"${STACK_DIR}/${file}"
    chmod 0600 "${STACK_DIR}/${file}"
  done
}

hysteria_render_profile_config() {
  local profile="$1" output="$2" port obfs obfs_type
  case "${profile}" in
    salamander)
      port="${HYSTERIA_SALAMANDER_LISTEN}"
      obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
      ;;
    gecko)
      port="$(<"${STACK_DIR}/hysteria-gecko-port.txt")"
      obfs="$(<"${STACK_DIR}/hysteria-obfs-gecko.txt")"
      ;;
    mimic)
      port="$(<"${STACK_DIR}/hysteria-mimic-port.txt")"
      obfs="$(<"${STACK_DIR}/hysteria-obfs-mimic.txt")"
      ;;
    *) die "Unknown Hysteria profile: ${profile}" ;;
  esac
  [[ "${profile}" == gecko ]] && obfs_type=gecko || obfs_type=salamander
  {
    printf 'listen: :%s\n' "${port}"
    printf 'quic:\n  disablePathMTUDiscovery: true\n'
    printf 'tls:\n  cert: %s/fullchain.pem\n  key: %s/privkey.pem\n' "${CERT_DIR}" "${CERT_DIR}"
    printf 'auth:\n  type: userpass\n  userpass:\n'
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "${STACK_DIR}/hysteria-clients.json"
    printf 'obfs:\n  type: %s\n  %s:\n    password: %s\n' \
      "${obfs_type}" "${obfs_type}" "${obfs}"
    if [[ "${profile}" == gecko ]]; then
      printf '    minPacketSize: 512\n    maxPacketSize: 1200\n'
    elif [[ "${profile}" == mimic ]]; then
      printf 'mimic:\n  enabled: true\n  xdpMode: skb\n'
    fi
  } >"${output}"
  chmod 0600 "${output}"
}

install_mimic_optional() {
  local codename arch kernel api cli_name cli_url cli_sha_url dkms_name dkms_url dkms_sha_url tmp
  printf '0\n' >"${STACK_DIR}/hysteria-mimic-available.txt"
  chmod 0600 "${STACK_DIR}/hysteria-mimic-available.txt"

  if command -v mimic >/dev/null 2>&1 && modprobe mimic; then
    printf '1\n' >"${STACK_DIR}/hysteria-mimic-available.txt"
    return 0
  fi

  kernel="$(uname -r | sed 's/-.*//')"
  if [[ "$(printf '%s\n%s\n' 6.1 "${kernel}" | sort -V | head -n1)" != "6.1" ]]; then
    warn "Mimic requires Linux kernel 6.1 or newer; profile creation will remain unavailable."
    return 0
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  codename="${VERSION_CODENAME:-}"
  arch="$(dpkg --print-architecture)"
  case "${codename}:${arch}" in
    noble:amd64|bookworm:amd64|trixie:amd64) ;;
    *)
      warn "Mimic has no supported prebuilt package for ${codename:-unknown}/${arch}; profile creation will remain unavailable."
      return 0
      ;;
  esac

  api="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: Golden-VPN-installer' \
    https://api.github.com/repos/hack3ric/mimic/releases/latest)"
  cli_name="$(jq -r --arg prefix "${codename}_mimic_" --arg suffix "_${arch}.deb" \
    '[.assets[] | select(.name|startswith($prefix)) | select(.name|endswith($suffix)) |
      select((.name|contains("dkms"))|not) | select((.name|contains("dbgsym"))|not)][0].name // empty' <<<"${api}")"
  dkms_name="$(jq -r --arg prefix "${codename}_mimic-dkms_" --arg suffix "_${arch}.deb" \
    '[.assets[] | select(.name|startswith($prefix)) | select(.name|endswith($suffix)) |
      select((.name|contains("dbgsym"))|not)][0].name // empty' <<<"${api}")"
  [[ -n "${cli_name}" && -n "${dkms_name}" ]] || { warn "Could not locate official Mimic packages."; return 0; }
  cli_url="$(jq -r --arg name "${cli_name}" '.assets[] | select(.name==$name) | .browser_download_url' <<<"${api}")"
  cli_sha_url="$(jq -r --arg name "${cli_name}.sha256" '.assets[] | select(.name==$name) | .browser_download_url' <<<"${api}")"
  dkms_url="$(jq -r --arg name "${dkms_name}" '.assets[] | select(.name==$name) | .browser_download_url' <<<"${api}")"
  dkms_sha_url="$(jq -r --arg name "${dkms_name}.sha256" '.assets[] | select(.name==$name) | .browser_download_url' <<<"${api}")"
  [[ -n "${cli_url}" && -n "${cli_sha_url}" && -n "${dkms_url}" && -n "${dkms_sha_url}" ]] \
    || { warn "Official Mimic checksum assets are incomplete."; return 0; }

  tmp="$(mktemp -d)"
  if ! curl -fsSL "${cli_url}" -o "${tmp}/${cli_name}" \
    || ! curl -fsSL "${cli_sha_url}" -o "${tmp}/${cli_name}.sha256" \
    || ! curl -fsSL "${dkms_url}" -o "${tmp}/${dkms_name}" \
    || ! curl -fsSL "${dkms_sha_url}" -o "${tmp}/${dkms_name}.sha256" \
    || ! (cd "${tmp}" && sha256sum -c "${cli_name}.sha256" "${dkms_name}.sha256") \
    || ! apt_get install -y "${tmp}/${cli_name}" "${tmp}/${dkms_name}"; then
    warn "Mimic package installation or checksum verification failed; other VPN contours remain available."
    rm -rf "${tmp}"
    return 0
  fi
  rm -rf "${tmp}"
  if command -v mimic >/dev/null 2>&1 && modprobe mimic; then
    printf '1\n' >"${STACK_DIR}/hysteria-mimic-available.txt"
  else
    warn "Mimic binary/module activation failed; Mimic listener will remain disabled."
  fi
}

write_hysteria_additional_units() {
  local hysteria_bin
  hysteria_bin="$(command -v hysteria)"
  cat >/etc/systemd/system/hysteria2-gecko.service <<EOF
[Unit]
Description=Hysteria2 Gecko server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${hysteria_bin} server -c ${HYSTERIA_PROFILE_DIR}/config-gecko.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/hysteria2-gecko.service

  cat >/etc/systemd/system/hysteria2-mimic.service <<EOF
[Unit]
Description=Hysteria2 Mimic server
After=network-online.target
Wants=network-online.target
ConditionPathExists=${HYSTERIA_PROFILE_DIR}/config-mimic.yaml

[Service]
Type=simple
User=root
RuntimeDirectory=mimic
RuntimeDirectoryMode=0755
ExecStart=${hysteria_bin} server -c ${HYSTERIA_PROFILE_DIR}/config-mimic.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 /etc/systemd/system/hysteria2-mimic.service
}

hysteria_render_config() {
  hysteria_render_profile_config salamander "${HYSTERIA_DIR}/config.yaml"
}

write_hysteria_link() {
  local name="$1"
  local password="$2"
  local obfs domain label tag link
  domain="$(<"${STACK_DIR}/domain.txt")"
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
  label="$(label_name "HYSTERIA" "${name}")"
  tag="$(uri_encode "${label}")"
  link="hysteria2://${name}:${password}@${domain}:${HYSTERIA_SALAMANDER_LISTEN}/?obfs=salamander&obfs-password=${obfs}&sni=${domain}#${tag}"
  install -d -m 0700 "${KEY_DIR}/hysteria"
  printf '%s\n' "${link}" >"${KEY_DIR}/hysteria/${label}.txt"
  chmod 0600 "${KEY_DIR}/hysteria/${label}.txt"
  printf '%s\n' "${link}"
}

configure_hysteria() {
  log "Configuring Hysteria2 Salamander, Gecko, and optional Mimic listeners."
  install -d -m 0700 "${HYSTERIA_DIR}" "${KEY_DIR}/hysteria"
  local password obfs
  password="$(rand_hex 18)"
  obfs="$(rand_hex 24)"
  printf '%s\n' "${password}" >"${STACK_DIR}/hysteria-auth.txt"
  printf '%s\n' "${obfs}" >"${STACK_DIR}/hysteria-obfs.txt"
  jq -n --arg password "${password}" '{"main-hysteria-client": $password}' >"${STACK_DIR}/hysteria-clients.json"
  chmod 0600 "${STACK_DIR}/hysteria-auth.txt" "${STACK_DIR}/hysteria-obfs.txt" "${STACK_DIR}/hysteria-clients.json"

  ensure_hysteria_profile_state
  hysteria_render_config
  hysteria_render_profile_config gecko "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
  if [[ "$(<"${STACK_DIR}/hysteria-mimic-available.txt")" == "1" ]]; then
    hysteria_render_profile_config mimic "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
  fi
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

  write_hysteria_additional_units
}

install_amneziawg() {
  log "Installing AmneziaWG ${AWG_PROTOCOL_VERSION}."
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

  if ! command -v awg >/dev/null 2>&1 || ! command -v awg-quick >/dev/null 2>&1 \
    || ! awg --version 2>/dev/null | grep -Eq 'v3\.1\.'; then
    warn "AWG 3.1 tools were not found after package install; building the pinned official tools release ${AWG_TOOLS_SOURCE_TAG}."
    apt_get install -y git make golang-go
    local build_dir
    build_dir="$(mktemp -d)"
    git clone --depth=1 --branch "${AWG_TOOLS_SOURCE_TAG}" \
      https://github.com/amnezia-vpn/amneziawg-tools "${build_dir}/amneziawg-tools"
    make -C "${build_dir}/amneziawg-tools/src"
    make -C "${build_dir}/amneziawg-tools/src" install
    rm -rf "${build_dir}"
  fi

  need_command awg
  need_command awg-quick
  awg --version 2>/dev/null | grep -Eq 'v3\.1\.' \
    || die "AmneziaWG 3.1 tools are required; installed version: $(awg --version 2>/dev/null || printf unknown)."
  verify_awg31_runtime_support
}

verify_awg31_runtime_support() {
  local check_iface="awgv31check" check_dir check_private header_key
  check_dir="$(mktemp -d)"
  check_private="$(awg genkey)"
  header_key="$(awg genkey)"

  modprobe amneziawg || {
    rm -rf "${check_dir}"
    die "The installed AmneziaWG kernel module cannot be loaded. Reboot into the current kernel and rerun install."
  }
  ip link del "${check_iface}" >/dev/null 2>&1 || true
  ip link add "${check_iface}" type amneziawg || {
    rm -rf "${check_dir}"
    die "The installed kernel module cannot create an AmneziaWG interface."
  }

  cat >"${check_dir}/awg31.conf" <<EOF
[Interface]
PrivateKey = ${check_private}
ListenPort = 0
Jc = 4
Jmin = 32
Jmax = 96
S1 = 32
S2 = 48
S3 = 64
S4 = 80
H1 = 100000001-100000101
H2 = 600000001-600000101
H3 = 1100000001-1100000101
H4 = 1600000001-1600000101
HeaderProtectionKey = ${header_key}
ContentPaddingAddition = 16-64
RekeyAfterTime = 110-130
RekeyTimeout = 4-7
RejectAfterTime = 170-190
KeepaliveTimeout = 8-12
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = off
EOF
  chmod 0600 "${check_dir}/awg31.conf"

  if ! awg setconf "${check_iface}" "${check_dir}/awg31.conf"; then
    ip link del "${check_iface}" >/dev/null 2>&1 || true
    rm -rf "${check_dir}"
    die "The installed AmneziaWG kernel module rejected AWG 3.1 parameters. Update the official Amnezia PPA packages and rerun install."
  fi
  ip link del "${check_iface}" >/dev/null 2>&1 || true
  rm -rf "${check_dir}"
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

validate_u16_range() {
  local name="$1" value="$2" minimum="$3" maximum="$4" left right
  if [[ "${value}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    left="${BASH_REMATCH[1]}"
    right="${BASH_REMATCH[2]}"
  elif [[ "${value}" =~ ^[0-9]+$ ]]; then
    left="${value}"
    right="${value}"
  else
    die "${name} must be an integer or an ascending integer range (for example 16-64)."
  fi
  ((left >= minimum && right <= maximum && left <= right)) \
    || die "${name} must be within ${minimum}..${maximum} and must be ascending."
}

validate_on_off() {
  local name="$1" value="$2"
  [[ "${value}" == "on" || "${value}" == "off" ]] || die "${name} must be on or off."
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
      if ping -4 -c 1 -W 1 -M 'do' -s "${payload}" "${target}" >/dev/null 2>&1; then
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
  local header_protection_key content_padding rekey_after rekey_timeout reject_after keepalive_timeout
  local max_handshake_attempts random_trailers disable_cookies

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
      jmax="$(rand_between 820 1180)"
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
  validate_int_range AWG_S1 "${s1}" 12 4096
  validate_int_range AWG_S2 "${s2}" 12 4096
  validate_int_range AWG_S3 "${s3}" 12 4096
  validate_int_range AWG_S4 "${s4}" 12 4096

  header_protection_key="${AWG_HEADER_PROTECTION_KEY:-$(awg genkey)}"
  printf '%s\n' "${header_protection_key}" | awg pubkey >/dev/null 2>&1 \
    || die "AWG_HEADER_PROTECTION_KEY is not a valid 32-byte AmneziaWG key."
  content_padding="${AWG_CONTENT_PADDING_ADDITION:-16-96}"
  rekey_after="${AWG_REKEY_AFTER_TIME:-110-130}"
  rekey_timeout="${AWG_REKEY_TIMEOUT:-4-7}"
  reject_after="${AWG_REJECT_AFTER_TIME:-170-190}"
  keepalive_timeout="${AWG_KEEPALIVE_TIMEOUT:-8-12}"
  max_handshake_attempts="${AWG_MAX_HANDSHAKE_ATTEMPTS:-15-20}"
  random_trailers="${AWG_RANDOM_TRAILERS:-on}"
  disable_cookies="${AWG_DISABLE_COOKIES:-off}"
  validate_u16_range AWG_CONTENT_PADDING_ADDITION "${content_padding}" 0 1280
  validate_u16_range AWG_REKEY_AFTER_TIME "${rekey_after}" 1 65535
  validate_u16_range AWG_REKEY_TIMEOUT "${rekey_timeout}" 1 65535
  validate_u16_range AWG_REJECT_AFTER_TIME "${reject_after}" 1 65535
  validate_u16_range AWG_KEEPALIVE_TIMEOUT "${keepalive_timeout}" 1 65535
  validate_u16_range AWG_MAX_HANDSHAKE_ATTEMPTS "${max_handshake_attempts}" 1 65535
  validate_on_off AWG_RANDOM_TRAILERS "${random_trailers}"
  validate_on_off AWG_DISABLE_COOKIES "${disable_cookies}"

  awg_mtu_requested="${AWG_MTU:-}"
  if [[ -z "${awg_mtu_requested}" ]]; then
    if [[ "${effective_profile}" == "mobile-low-mtu" ]]; then
      awg_mtu="1240"
      mtu_source="profile"
    else
      awg_mtu="1420"
      mtu_source="standard-maximum"
    fi
  elif [[ "${awg_mtu_requested}" == "auto" ]]; then
    awg_mtu="$(detect_awg_auto_mtu)"
    mtu_source="auto-pmtu"
  else
    awg_mtu="${awg_mtu_requested}"
    mtu_source="user"
  fi
  validate_int_range AWG_MTU "${awg_mtu}" 1200 1420
  ((jmax < awg_mtu)) || die "AWG_JMAX must be lower than AWG_MTU to avoid fragmented junk packets."
  ((s1 <= awg_mtu - 148)) || die "AWG_S1 must not exceed AWG_MTU - 148."
  ((s2 <= awg_mtu - 92)) || die "AWG_S2 must not exceed AWG_MTU - 92."

  awg_port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}"
  validate_int_range AWG_ENDPOINT_PORT "${awg_port}" 1 65535
  [[ "${awg_port}" == "443" ]] || die "AWG_ENDPOINT_PORT is fixed at 443/udp in the Golden profile."
  awg_dns="${AWG_DNS:-1.1.1.1}"
  awg_allowed_ips="${AWG_ALLOWED_IPS:-0.0.0.0/0}"
  awg_keepalive="${AWG_KEEPALIVE:-25}"
  validate_int_range AWG_KEEPALIVE "${awg_keepalive}" 0 65535

  source_note="profile=${requested_profile}; effective=${effective_profile}; overrides are applied from AWG_* env when present"

  {
    printf 'AWG_PROTOCOL_VERSION=%q\n' "${AWG_PROTOCOL_VERSION}"
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
    printf 'AWG_HEADER_PROTECTION_KEY=%q\n' "${header_protection_key}"
    printf 'AWG_CONTENT_PADDING_ADDITION=%q\n' "${content_padding}"
    printf 'AWG_REKEY_AFTER_TIME=%q\n' "${rekey_after}"
    printf 'AWG_REKEY_TIMEOUT=%q\n' "${rekey_timeout}"
    printf 'AWG_REJECT_AFTER_TIME=%q\n' "${reject_after}"
    printf 'AWG_KEEPALIVE_TIMEOUT=%q\n' "${keepalive_timeout}"
    printf 'AWG_MAX_HANDSHAKE_ATTEMPTS=%q\n' "${max_handshake_attempts}"
    printf 'AWG_RANDOM_TRAILERS=%q\n' "${random_trailers}"
    printf 'AWG_DISABLE_COOKIES=%q\n' "${disable_cookies}"
  } >"${STACK_DIR}/awg-params.env"
  chmod 0600 "${STACK_DIR}/awg-params.env"

  cat >"${AWG_TUNING_REPORT}" <<EOF
{
  "generated_at": $(json_escape "$(date -Is)"),
  "protocol_version": $(json_escape "${AWG_PROTOCOL_VERSION}"),
  "requested_profile": $(json_escape "${requested_profile}"),
  "effective_profile": $(json_escape "${effective_profile}"),
  "mtu": ${awg_mtu},
  "mtu_source": $(json_escape "${mtu_source}"),
  "endpoint_port": ${awg_port},
  "dns": $(json_escape "${awg_dns}"),
  "allowed_ips": $(json_escape "${awg_allowed_ips}"),
  "keepalive": ${awg_keepalive},
  "params_path": $(json_escape "${STACK_DIR}/awg-params.env"),
  "header_protection": true,
  "content_padding": $(json_escape "${content_padding}"),
  "random_trailers": $(json_escape "${random_trailers}"),
  "cookies_disabled": $(json_escape "${disable_cookies}"),
  "note": $(json_escape "AWG 3.1 header protection, content padding, randomized timings and random trailers are enabled. Cookie replies remain enabled by default for DoS resistance. Tcpdump is never started automatically.")
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
# Protocol = AmneziaWG ${AWG_PROTOCOL_VERSION:-3.1}
# ObfuscationProfile = ${AWG_OBFS_PROFILE:-unknown}
# EffectiveProfile = ${AWG_EFFECTIVE_PROFILE:-unknown}
# MTU = ${AWG_MTU:-1420}
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = ${AWG_DNS:-1.1.1.1}
MTU = ${AWG_MTU:-1420}
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
HeaderProtectionKey = ${AWG_HEADER_PROTECTION_KEY}
ContentPaddingAddition = ${AWG_CONTENT_PADDING_ADDITION}
RekeyAfterTime = ${AWG_REKEY_AFTER_TIME}
RekeyTimeout = ${AWG_REKEY_TIMEOUT}
RejectAfterTime = ${AWG_REJECT_AFTER_TIME}
KeepaliveTimeout = ${AWG_KEEPALIVE_TIMEOUT}
MaxHandshakeAttempts = ${AWG_MAX_HANDSHAKE_ATTEMPTS}
RandomTrailers = ${AWG_RANDOM_TRAILERS}
DisableCookies = ${AWG_DISABLE_COOKIES}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${DOMAIN}:${AWG_ENDPOINT_PORT:-443}
AllowedIPs = ${AWG_ALLOWED_IPS:-0.0.0.0/0}
PersistentKeepalive = ${AWG_KEEPALIVE:-25}
EOF
  chmod 0600 "${out_file}"
  cat "${out_file}"
}

configure_amneziawg() {
  log "Configuring AmneziaWG ${AWG_PROTOCOL_VERSION} as the primary VPN contour."
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
  log "AWG profile: ${awg_profile} (effective ${awg_effective_profile}), MTU ${awg_mtu}, external UDP/${awg_port}, internal UDP/${AWG_INTERNAL_LISTEN_PORT}."
  printf '%s\n' "${server_public}" >"${STACK_DIR}/awg-server-public-key.txt"
  chmod 0600 "${STACK_DIR}/awg-server-public-key.txt"

  cat >/etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = ${AWG_INTERNAL_LISTEN_PORT}
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
HeaderProtectionKey = ${AWG_HEADER_PROTECTION_KEY}
ContentPaddingAddition = ${AWG_CONTENT_PADDING_ADDITION}
RekeyAfterTime = ${AWG_REKEY_AFTER_TIME}
RekeyTimeout = ${AWG_REKEY_TIMEOUT}
RejectAfterTime = ${AWG_REJECT_AFTER_TIME}
KeepaliveTimeout = ${AWG_KEEPALIVE_TIMEOUT}
MaxHandshakeAttempts = ${AWG_MAX_HANDSHAKE_ATTEMPTS}
RandomTrailers = ${AWG_RANDOM_TRAILERS}
DisableCookies = ${AWG_DISABLE_COOKIES}
PostUp = iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o ${EXT_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT
PostUp = iptables -A FORWARD -o awg0 -j ACCEPT
PostUp = iptables -t mangle -A FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1150
PostUp = iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1150
PostUp = iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53
PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53
PostUp = iptables -I FORWARD 1 -i awg0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
PostDown = iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o ${EXT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT
PostDown = iptables -D FORWARD -o awg0 -j ACCEPT
PostDown = iptables -t mangle -D FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1150
PostDown = iptables -t mangle -D FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1150
PostDown = iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53
PostDown = iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53
PostDown = iptables -D FORWARD -i awg0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable

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

configure_udp_buffers() {
  local sysctl_file="${VPN_UDP_BUFFER_SYSCTL_FILE:-/etc/sysctl.d/97-golden-vpn-udp-buffers.conf}"
  local sysctl_bin="${VPN_SYSCTL_BIN:-sysctl}"
  install -d -m 0755 "$(dirname "${sysctl_file}")"
  cat >"${sysctl_file}" <<'EOF'
# Golden VPN high-throughput UDP socket limits.
net.core.rmem_default = 4194304
net.core.rmem_max = 16777216
net.core.wmem_default = 4194304
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 4096
EOF
  chmod 0644 "${sysctl_file}"
  "${sysctl_bin}" -p "${sysctl_file}" >/dev/null
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

render_awg_udp443_ufw_rules() {
  local input="$1" output="$2"
  awk '
    $0 == "# golden-vpn-awg-udp443" {skip_nat=1; next}
    skip_nat && $0 == "COMMIT" {skip_nat=0; skip_nat_blank=1; next}
    skip_nat {next}
    skip_nat_blank && $0 == "" {skip_nat_blank=0; next}
    {skip_nat_blank=0}
    $0 == "# golden-vpn-awg-udp443-input" {skip_filter=1; next}
    skip_filter {skip_filter=0; next}
    /^\*filter$/ && !nat_inserted {
      print "# golden-vpn-awg-udp443"
      print "*nat"
      print ":PREROUTING ACCEPT [0:0]"
      print "-A PREROUTING -p udp --dport 443 -m addrtype --dst-type LOCAL -j REDIRECT --to-ports 51820"
      print "COMMIT"
      print ""
      nat_inserted=1
    }
    {
      print
      if ($0 == ":ufw-before-forward - [0:0]" && !filter_inserted) {
        print "# golden-vpn-awg-udp443-input"
        print "-A ufw-before-input -p udp --dport 51820 -m conntrack --ctorigdstport 443 -j ACCEPT"
        filter_inserted=1
      }
    }
  ' "${input}" >"${output}"
}

configure_awg_udp443_gateway() {
  local rules="/etc/ufw/before.rules" tmp
  [[ -f "${rules}" ]] || die "Missing UFW rules file: ${rules}"
  tmp="$(mktemp /etc/ufw/.before.rules.XXXXXX)"
  render_awg_udp443_ufw_rules "${rules}" "${tmp}"
  install -m 0640 "${tmp}" "${rules}"
  rm -f "${tmp}"
  iptables-restore --test <"${rules}"
}

activate_awg_udp443_gateway() {
  while iptables -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-ports 51820 >/dev/null 2>&1; do
    iptables -t nat -D PREROUTING -p udp --dport 443 -j REDIRECT --to-ports 51820
  done
  while iptables -t nat -C PREROUTING -p udp --dport 443 -m addrtype --dst-type LOCAL -j REDIRECT --to-ports 51820 >/dev/null 2>&1; do
    iptables -t nat -D PREROUTING -p udp --dport 443 -m addrtype --dst-type LOCAL -j REDIRECT --to-ports 51820
  done
  iptables -t nat -A PREROUTING -p udp --dport 443 -m addrtype --dst-type LOCAL -j REDIRECT --to-ports 51820
}

configure_firewall() {
  local awg_port="${AWG_ENDPOINT_PORT:-${AWG_DEFAULT_PORT}}" gecko_port mimic_port
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
  if [[ -s "${STACK_DIR}/hysteria-gecko-port.txt" ]]; then
    gecko_port="$(<"${STACK_DIR}/hysteria-gecko-port.txt")"
    ufw allow "${gecko_port}/udp"
  fi
  if [[ "$(cat "${STACK_DIR}/hysteria-mimic-available.txt" 2>/dev/null || printf 0)" == 1 ]] \
    && [[ -s "${STACK_DIR}/hysteria-mimic-port.txt" ]]; then
    mimic_port="$(<"${STACK_DIR}/hysteria-mimic-port.txt")"
    ufw allow "${mimic_port}/udp"
    ufw allow "${mimic_port}/tcp"
  fi
  ufw allow "${awg_port}/udp"
  ufw --force delete allow "${AWG_INTERNAL_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
  configure_awg_udp443_gateway
  ufw --force enable
  activate_awg_udp443_gateway
}

install_helper_hiddify_profile() {
  cat >"${HIDDIFY_PROFILE_HELPER_PATH}" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import parse_qs, unquote, urlsplit

OUTPUT_ROOT = Path("/root/vpn-keys/hiddify-json")
DOH_IP = os.environ.get("GOLDEN_DOH_IP", "1.1.1.1")
DOH_HOST = os.environ.get("GOLDEN_DOH_HOST", "cloudflare-dns.com")
SAFE_LABEL = re.compile(r"[A-Za-z0-9._-]+")


def atomic_write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            fd = -1
            handle.write(value)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def read_uri(source):
    uri = source.resolve().read_text(encoding="utf-8").strip()
    if not uri or "\n" in uri or "\r" in uri:
        raise ValueError(f"expected exactly one URI in {source}")
    return uri


def split_authority(uri):
    parsed = urlsplit(uri)
    if "@" not in parsed.netloc:
        raise ValueError("URI has no credentials")
    userinfo, endpoint = parsed.netloc.rsplit("@", 1)
    if endpoint.startswith("["):
        closing = endpoint.find("]")
        if closing < 0:
            raise ValueError("invalid IPv6 endpoint")
        host = endpoint[1:closing]
        port_text = endpoint[closing + 1 :].lstrip(":")
    else:
        host, separator, port_text = endpoint.rpartition(":")
        if not separator:
            host, port_text = endpoint, ""
    if not host:
        raise ValueError("URI has no server")
    return parsed, unquote(userinfo), host, port_text


def query_value(query, name, default=""):
    values = parse_qs(query, keep_blank_values=True).get(name)
    return unquote(values[0]) if values else default


def tls(server_name, alpn=None):
    result = {
        "enabled": True,
        "server_name": server_name,
        "insecure": False,
    }
    if alpn:
        result["alpn"] = alpn
    return result


def trojan_outbound(uri, tag="proxy"):
    parsed, password, server, port_text = split_authority(uri)
    if parsed.scheme.lower() != "trojan":
        raise ValueError("expected a Trojan URI")
    port = int(port_text or "443")
    query = parse_qs(parsed.query, keep_blank_values=True)
    if query_value(parsed.query, "type", "") != "xhttp":
        raise ValueError("only Trojan XHTTP profiles are supported")
    server_name = query_value(parsed.query, "sni", server)
    host = query_value(parsed.query, "host", server_name)
    path = query_value(parsed.query, "path", "/")
    return {
        "type": "trojan",
        "tag": tag,
        "server": server,
        "server_port": port,
        "password": password,
        "tls": {
            **tls(server_name, ["h2"]),
            "utls": {"enabled": True, "fingerprint": "chrome"},
        },
        "transport": {
            "type": "xhttp",
            "host": host,
            "path": path,
            "mode": "stream-one",
        },
    }


def hysteria_outbound(uri, tag="proxy"):
    parsed, credential, server, port_text = split_authority(uri)
    if parsed.scheme.lower() not in {"hysteria2", "hy2"}:
        raise ValueError("expected a Hysteria2 URI")
    ports = []
    for item in (port_text or "443").split(","):
        item = item.strip().replace("-", ":")
        if not re.fullmatch(r"[0-9]+(?::[0-9]+)?", item):
            raise ValueError(f"invalid Hysteria2 port or range: {item}")
        if ":" not in item:
            item = f"{item}:{item}"
        ports.append(item)
    obfs_type = query_value(parsed.query, "obfs", "")
    obfs_password = query_value(parsed.query, "obfs-password", "")
    if obfs_type == "gecko":
        raise ValueError("Hiddify core does not support Hysteria2 Gecko profiles")
    server_name = query_value(parsed.query, "sni", server)
    outbound = {
        "type": "hysteria2",
        "tag": tag,
        "server": server,
        "server_ports": ports,
        "password": credential,
        "tls": tls(server_name),
    }
    if obfs_type:
        if obfs_type not in {"salamander", "gecko"}:
            raise ValueError(f"unsupported Hysteria2 obfuscation: {obfs_type}")
        outbound["obfs"] = {"type": obfs_type, "password": obfs_password}
    return outbound


def protocol_for(uri):
    scheme = urlsplit(uri).scheme.lower()
    if scheme == "trojan":
        return "trojan"
    if scheme in {"hysteria2", "hy2"}:
        return "hysteria"
    raise ValueError(f"unsupported key URI scheme: {scheme or 'missing'}")


def dns_config(proxy_tag="proxy"):
    return {
        "servers": [
            {
                "type": "https",
                "tag": "dns-remote",
                "server": DOH_IP,
                "server_port": 443,
                "path": "/dns-query",
                "detour": proxy_tag,
                "tls": {"enabled": True, "server_name": DOH_HOST},
            },
            {
                "type": "udp",
                "tag": "dns-bootstrap",
                "server": DOH_IP,
                "server_port": 53,
                "detour": "direct",
            },
        ],
        "final": "dns-remote",
        "strategy": "ipv4_only",
        "independent_cache": True,
    }


def base_config(outbounds, final_tag="proxy"):
    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": dns_config(final_tag),
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30"],
                "auto_route": True,
                "strict_route": True,
                "stack": "mixed",
            }
        ],
        "outbounds": outbounds + [{"type": "direct", "tag": "direct"}],
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
            ],
            "final": final_tag,
            "default_domain_resolver": "dns-bootstrap",
        },
    }


def render_single(uri):
    protocol = protocol_for(uri)
    outbound = trojan_outbound(uri) if protocol == "trojan" else hysteria_outbound(uri)
    return protocol, base_config([outbound])


def wrap(source, output_dir=None):
    label = source.stem
    if not SAFE_LABEL.fullmatch(label):
        raise ValueError(f"unsafe profile label: {label}")
    uri = read_uri(source)
    protocol, config = render_single(uri)
    target_dir = Path(output_dir).resolve() if output_dir else OUTPUT_ROOT / protocol
    output = target_dir / f"{label}.json"
    atomic_write(output, json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    return output


def bundle(trojan_source, hysteria_source, output):
    trojan_uri = read_uri(trojan_source)
    hysteria_uri = read_uri(hysteria_source)
    selector = {
        "type": "selector",
        "tag": "proxy",
        "outbounds": ["hysteria2", "trojan"],
        "default": "hysteria2",
    }
    config = base_config([
        selector,
        hysteria_outbound(hysteria_uri, "hysteria2"),
        trojan_outbound(trojan_uri, "trojan"),
    ])
    atomic_write(output.resolve(), json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    return output


def iter_inputs(directory):
    yield from sorted(Path(directory).glob("*.txt"))


def main():
    parser = argparse.ArgumentParser(description="Create Hiddify-compatible Sing-box JSON profiles")
    commands = parser.add_subparsers(dest="command", required=True)
    wrap_parser = commands.add_parser("wrap")
    wrap_parser.add_argument("input")
    wrap_parser.add_argument("--output-dir")
    bulk_parser = commands.add_parser("bulk")
    bulk_parser.add_argument("input_dir")
    bulk_parser.add_argument("--output-dir")
    bundle_parser = commands.add_parser("bundle")
    bundle_parser.add_argument("trojan_input")
    bundle_parser.add_argument("hysteria_input")
    bundle_parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.command == "wrap":
        print(wrap(Path(args.input), args.output_dir))
        return
    if args.command == "bundle":
        print(bundle(Path(args.trojan_input), Path(args.hysteria_input), Path(args.output)))
        return
    count = 0
    for source in iter_inputs(args.input_dir):
        try:
            wrap(source, args.output_dir)
        except ValueError:
            continue
        count += 1
    print(f"wrapped={count}")


if __name__ == "__main__":
    main()
PY
  chmod 0755 "${HIDDIFY_PROFILE_HELPER_PATH}"
}

install_helper_trojan() {
  install -d -m 0755 "$(dirname "${TROJAN_HELPER_PATH}")"
  cat >"${TROJAN_HELPER_PATH}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/opt/vpn-stack/xray/config.json"
STACK_DIR="/opt/vpn-stack"
KEY_DIR="/root/vpn-keys/trojan"
SERVICE="$(cat "${STACK_DIR}/trojan-xhttp-service.txt" 2>/dev/null || printf 'xray-trojan-xhttp-tls.service')"

die() { echo "ERROR: $*" >&2; exit 1; }
uri_encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
usage() {
  cat <<'USAGE'
Usage:
  vpn-trojan <name>    Create a Trojan XHTTP TLS client
  vpn-trojan help      Show this help
USAGE
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

print_encrypted_dns_json() {
  local source="$1" protocol_dir="$2" stem hiddify_profile
  /usr/local/bin/vpn-hiddify-profile wrap "${source}" >/dev/null
  stem="$(basename "${source%.txt}")"
  hiddify_profile="/root/vpn-keys/hiddify-json/${protocol_dir}/${stem}.json"
  [[ -s "${hiddify_profile}" ]] || die "Hiddify JSON was not generated: ${hiddify_profile}"
  printf '\nHiddify Sing-box JSON (DoH through tunnel):\n'
  cat "${hiddify_profile}"
  printf '\nSaved Hiddify JSON: %s\n' "${hiddify_profile}"
  printf 'Hiddify: import this JSON file as a local configuration; do not paste the raw URI instead.\n'
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
case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac
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
link="trojan://${password}@${domain}:443?security=tls&type=xhttp&path=${encoded_path}&mode=auto&sni=${domain}&host=${domain}&alpn=h2#${fragment}"

install -d -m 0700 "${KEY_DIR}"
printf '%s\n' "${link}" >"${KEY_DIR}/${label}.txt"
chmod 0600 "${KEY_DIR}/${label}.txt"
print_encrypted_dns_json "${KEY_DIR}/${label}.txt" trojan
printf 'Client: %s\n' "${label}"
print_qr "${link}"
printf 'Link:\n%s\n' "${link}"
printf 'Saved: %s\n' "${KEY_DIR}/${label}.txt"
EOF
  chmod 0755 "${TROJAN_HELPER_PATH}"
}

install_helper_hysteria() {
  cat >/usr/local/bin/vpn-hysteria <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="/opt/vpn-stack"
CONFIG="/opt/vpn-stack/hysteria/config.yaml"
GECKO_CONFIG="/opt/vpn-stack/hysteria-profiles/config-gecko.yaml"
MIMIC_CONFIG="/opt/vpn-stack/hysteria-profiles/config-mimic.yaml"
CLIENTS="/opt/vpn-stack/hysteria-clients.json"
KEY_DIR="/root/vpn-keys/hysteria"
SERVICE="hysteria2.service"
GECKO_SERVICE="hysteria2-gecko.service"
MIMIC_SERVICE="hysteria2-mimic.service"

die() { echo "ERROR: $*" >&2; exit 1; }
uri_encode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
rand_hex() { openssl rand -hex "$1"; }
usage() {
  cat <<'USAGE'
Usage:
  vpn-hysteria <name> [salamander]  Create/show the default Hysteria2 URI
  vpn-hysteria <name> gecko         Create/show a Gecko Hysteria2 URI
  vpn-hysteria <name> mimic         Create/show a Linux-only Mimic YAML
  vpn-hysteria help                 Show this help

Existing names keep their current username/password when another profile is issued.
USAGE
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

print_encrypted_dns_json() {
  local source="$1" protocol_dir="$2" stem hiddify_profile
  /usr/local/bin/vpn-hiddify-profile wrap "${source}" >/dev/null
  stem="$(basename "${source%.txt}")"
  hiddify_profile="/root/vpn-keys/hiddify-json/${protocol_dir}/${stem}.json"
  [[ -s "${hiddify_profile}" ]] || die "Hiddify JSON was not generated: ${hiddify_profile}"
  printf '\nHiddify Sing-box JSON (DoH through tunnel):\n'
  cat "${hiddify_profile}"
  printf '\nSaved Hiddify JSON: %s\n' "${hiddify_profile}"
  printf 'Hiddify: import this JSON file as a local configuration; do not paste the raw URI instead.\n'
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

render_profile_config() {
  local profile="$1" output="$2" port obfs obfs_type
  case "${profile}" in
    salamander)
      port="8443,20000-50000"
      obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
      obfs_type=salamander
      ;;
    gecko)
      port="$(<"${STACK_DIR}/hysteria-gecko-port.txt")"
      obfs="$(<"${STACK_DIR}/hysteria-obfs-gecko.txt")"
      obfs_type=gecko
      ;;
    mimic)
      port="$(<"${STACK_DIR}/hysteria-mimic-port.txt")"
      obfs="$(<"${STACK_DIR}/hysteria-obfs-mimic.txt")"
      obfs_type=salamander
      ;;
    *) die "Unknown profile: ${profile}" ;;
  esac
  {
    printf 'listen: :%s\n' "${port}"
    printf 'quic:\n  disablePathMTUDiscovery: true\n'
    printf 'tls:\n'
    printf '  cert: /etc/letsencrypt/live/%s/fullchain.pem\n' "$(<"${STACK_DIR}/domain.txt")"
    printf '  key: /etc/letsencrypt/live/%s/privkey.pem\n' "$(<"${STACK_DIR}/domain.txt")"
    printf 'auth:\n'
    printf '  type: userpass\n'
    printf '  userpass:\n'
    jq -r 'to_entries[] | "    \(.key): \(.value)"' "${CLIENTS}"
    printf 'obfs:\n'
    printf '  type: %s\n' "${obfs_type}"
    printf '  %s:\n' "${obfs_type}"
    printf '    password: %s\n' "${obfs}"
    if [[ "${profile}" == gecko ]]; then
      printf '    minPacketSize: 512\n    maxPacketSize: 1200\n'
    elif [[ "${profile}" == mimic ]]; then
      printf 'mimic:\n  enabled: true\n  xdpMode: skb\n'
    fi
  } >"${output}"
  chmod 0600 "${output}"
}

render_configs() {
  render_profile_config salamander "${CONFIG}"
  render_profile_config gecko "${GECKO_CONFIG}"
  if [[ "$(cat "${STACK_DIR}/hysteria-mimic-available.txt" 2>/dev/null || printf 0)" == 1 ]]; then
    render_profile_config mimic "${MIMIC_CONFIG}"
  fi
}

restart_profiles() {
  systemctl restart "${SERVICE}"
  systemctl restart "${GECKO_SERVICE}"
  if [[ -f "${MIMIC_CONFIG}" ]]; then
    systemctl restart "${MIMIC_SERVICE}"
  fi
}

[[ "${EUID}" -eq 0 ]] || die "Run as root."
case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac
[[ $# -ge 1 && $# -le 2 ]] || die "Usage: vpn-hysteria <name> [salamander|gecko|mimic]"
name="$1"
profile="${2:-salamander}"
[[ "${profile}" == salamander || "${profile}" == gecko || "${profile}" == mimic ]] \
  || die "Profile must be salamander, gecko, or mimic."
[[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Use only letters, digits, dot, underscore, dash."
[[ -f "${CLIENTS}" ]] || die "Missing ${CLIENTS}"
label="$(label_name "HYSTERIA" "${name}")"

if jq -e --arg name "${name}" 'has($name)' "${CLIENTS}" >/dev/null; then
  password="$(jq -r --arg name "${name}" '.[$name]' "${CLIENTS}")"
else
  password="$(rand_hex 18)"
  tmp="$(mktemp)"
  backup="$(mktemp)"
  cp "${CLIENTS}" "${backup}"
  jq --arg name "${name}" --arg password "${password}" '.[$name] = $password' "${CLIENTS}" >"${tmp}"
  install -m 0600 "${tmp}" "${CLIENTS}"
  rm -f "${tmp}"
  if ! render_configs || ! restart_profiles; then
    install -m 0600 "${backup}" "${CLIENTS}"
    render_configs || true
    restart_profiles || true
    rm -f "${backup}"
    die "Could not activate Hysteria user; registry was restored."
  fi
  rm -f "${backup}"
fi

domain="$(<"${STACK_DIR}/domain.txt")"
install -d -m 0700 "${KEY_DIR}"
case "${profile}" in
  salamander)
    obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
    tag="$(uri_encode "${label}")"
    link="hysteria2://${name}:${password}@${domain}:8443,20000-50000/?obfs=salamander&obfs-password=${obfs}&sni=${domain}#${tag}"
    out="${KEY_DIR}/${label}.txt"
    printf '%s\n' "${link}" >"${out}"
    chmod 0600 "${out}"
    print_encrypted_dns_json "${out}" hysteria
    print_qr "${link}"
    printf 'Link:\n%s\n' "${link}"
    ;;
  gecko)
    obfs="$(<"${STACK_DIR}/hysteria-obfs-gecko.txt")"
    port="$(<"${STACK_DIR}/hysteria-gecko-port.txt")"
    tag="$(uri_encode "${label}-GECKO")"
    link="hysteria2://${name}:${password}@${domain}:${port}?obfs=gecko&obfs-password=${obfs}&sni=${domain}#${tag}"
    out="${KEY_DIR}/${label}-gecko.txt"
    printf '%s\n' "${link}" >"${out}"
    chmod 0600 "${out}"
    print_encrypted_dns_json "${out}" hysteria
    print_qr "${link}"
    printf 'Link:\n%s\n' "${link}"
    ;;
  mimic)
    [[ "$(cat "${STACK_DIR}/hysteria-mimic-available.txt" 2>/dev/null || printf 0)" == 1 ]] \
      || die "Mimic is unavailable on this server; it requires supported Linux packages, kernel >= 6.1, and eBPF."
    obfs="$(<"${STACK_DIR}/hysteria-obfs-mimic.txt")"
    port="$(<"${STACK_DIR}/hysteria-mimic-port.txt")"
    out="${KEY_DIR}/${label}-mimic.yaml"
    cat >"${out}" <<EOF_MIMIC
server: "${domain}:${port}"
auth: "${name}:${password}"
tls:
  sni: ${domain}
obfs:
  type: salamander
  salamander:
    password: ${obfs}
mimic:
  enabled: true
socks5:
  listen: 127.0.0.1:1080
EOF_MIMIC
    chmod 0600 "${out}"
    printf 'Linux Hysteria2 client config:\n'
    cat "${out}"
    printf '\nMimic must be installed on the Linux client and Hysteria must run as root.\n'
    ;;
esac
printf 'Client: %s (%s)\n' "${label}" "${profile}"
printf 'Saved: %s\n' "${out}"
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
DEFAULT_PORT=443

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


storage_hint() {
  local path="$1"
  {
    echo "Storage diagnostics for ${path}:"
    df -h "${path}" 2>/dev/null || true
    df -ih "${path}" 2>/dev/null || true
  } >&2
}

require_writable_dir() {
  local dir="$1"
  if ! install -d -m 0700 "${dir}"; then
    storage_hint "$(dirname "${dir}")"
    die "Could not create ${dir}; check disk space and inodes."
  fi
  [[ -w "${dir}" ]] || die "Directory is not writable: ${dir}"
}

add_runtime_peer() {
  local public="$1" psk="$2" ip="$3"
  if ! awg set awg0 peer "${public}" preshared-key <(printf '%s\n' "${psk}") allowed-ips "${ip}/32"; then
    storage_hint /tmp
    storage_hint /run
    die "Could not add AWG peer at runtime."
  fi
}

remove_runtime_peer() {
  local public="$1"
  awg show awg0 >/dev/null 2>&1 && awg set awg0 peer "${public}" remove >/dev/null 2>&1 || true
}

drop_peer_from_config_by_public() {
  local public="$1" tmp
  tmp="$(mktemp "$(dirname "${CONFIG}")/.awg0.conf.rollback.XXXXXX")" || return 1
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
  ' "${CONFIG}" >"${tmp}" && install -m 0600 "${tmp}" "${CONFIG}"
  local status=$?
  rm -f "${tmp}"
  return "${status}"
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
  recover_param_from_server AWG_HEADER_PROTECTION_KEY HeaderProtectionKey
  recover_param_from_server AWG_CONTENT_PADDING_ADDITION ContentPaddingAddition
  recover_param_from_server AWG_REKEY_AFTER_TIME RekeyAfterTime
  recover_param_from_server AWG_REKEY_TIMEOUT RekeyTimeout
  recover_param_from_server AWG_REJECT_AFTER_TIME RejectAfterTime
  recover_param_from_server AWG_KEEPALIVE_TIMEOUT KeepaliveTimeout
  recover_param_from_server AWG_MAX_HANDSHAKE_ATTEMPTS MaxHandshakeAttempts
  recover_param_from_server AWG_RANDOM_TRAILERS RandomTrailers
  recover_param_from_server AWG_DISABLE_COOKIES DisableCookies
  AWG_ENDPOINT_PORT="${AWG_ENDPOINT_PORT:-${DEFAULT_PORT}}"
  AWG_DNS="${AWG_DNS:-1.1.1.1}"
  AWG_ALLOWED_IPS="${AWG_ALLOWED_IPS:-0.0.0.0/0}"
  AWG_KEEPALIVE="${AWG_KEEPALIVE:-25}"
}

config_interface_value() {
  local wanted="$1"
  awk -F= -v wanted="${wanted}" '
    BEGIN { in_interface=0 }
    /^[[:space:]]*\[Interface\][[:space:]]*$/ { in_interface=1; next }
    /^[[:space:]]*\[/ { if (in_interface) exit; next }
    in_interface {
      key=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (tolower(key) == tolower(wanted)) {
        value=substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "${CONFIG}"
}

recover_param_from_server() {
  local variable="$1" config_key="$2" value
  [[ -n "${!variable:-}" ]] && return 0
  value="$(config_interface_value "${config_key}")"
  [[ -n "${value}" ]] \
    || die "Missing ${variable} in ${PARAMS} and ${config_key} in the live AWG config."
  printf -v "${variable}" '%s' "${value}"
}

archive_empty_client_file() {
  local path="$1" failed_dir
  [[ -f "${path}" && ! -s "${path}" ]] || return 0
  failed_dir="${KEY_DIR}/.failed"
  install -d -m 0700 "${failed_dir}"
  mv -- "${path}" "${failed_dir}/$(basename "${path}").empty.$(date -u +%Y%m%dT%H%M%SZ)"
}

show_usage() {
  cat <<'USAGE'
Usage:
  vpn-awg <name>          Create a new AmneziaWG 3.1 client
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
  echo "AmneziaWG 3.1 diagnostics"
  echo
  echo "Services:"
  systemctl is-active awg-quick@awg0.service 2>/dev/null | sed 's/^/  awg-quick@awg0 active: /' || true
  systemctl is-enabled awg-quick@awg0.service 2>/dev/null | sed 's/^/  awg-quick@awg0 enabled: /' || true
  systemctl is-active amneziawg-ensure-module.service 2>/dev/null | sed 's/^/  amneziawg-ensure-module active: /' || true
  echo
  echo "Storage:"
  df -h / /tmp /run "$(dirname "${CONFIG}")" "${KEY_DIR}" 2>/dev/null | sed 's/^/  /' || true
  df -ih / /tmp /run "$(dirname "${CONFIG}")" "${KEY_DIR}" 2>/dev/null | sed 's/^/  /' || true
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
    grep -E '^AWG_(PROTOCOL_VERSION|OBFS_PROFILE|EFFECTIVE_PROFILE|TUNING_SOURCE|MTU|MTU_SOURCE|ENDPOINT_PORT|DNS|ALLOWED_IPS|KEEPALIVE|JC|JMIN|JMAX|S[1-4]|H[1-4]|I[1-5]|CONTENT_PADDING_ADDITION|REKEY_AFTER_TIME|REKEY_TIMEOUT|REJECT_AFTER_TIME|KEEPALIVE_TIMEOUT|MAX_HANDSHAKE_ATTEMPTS|RANDOM_TRAILERS|DISABLE_COOKIES)=' "${PARAMS}" | sed 's/^/  /'
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
  private="$(awk '
    /^[[:space:]]*PrivateKey[[:space:]]*=/ {
      line = $0
      sub(/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*/, "", line)
      gsub(/\r/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "${file}")"
  [[ -n "${private}" ]] || die "Could not read client private key from ${file}."
  public="$(printf '%s\n' "${private}" | awg pubkey)"

  tmp="$(mktemp "$(dirname "${CONFIG}")/.awg0.conf.revoke.XXXXXX")" || {
    storage_hint "$(dirname "${CONFIG}")"
    die "Could not create temp config next to ${CONFIG}; check disk space and inodes."
  }

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
  echo "AmneziaWG 3.1 profile"
  echo
  grep -E '^AWG_(PROTOCOL_VERSION|OBFS_PROFILE|EFFECTIVE_PROFILE|TUNING_SOURCE|MTU|MTU_SOURCE|ENDPOINT_PORT|DNS|ALLOWED_IPS|KEEPALIVE|JC|JMIN|JMAX|S[1-4]|H[1-4]|I[1-5]|CONTENT_PADDING_ADDITION|REKEY_AFTER_TIME|REKEY_TIMEOUT|REJECT_AFTER_TIME|KEEPALIVE_TIMEOUT|MAX_HANDSHAKE_ATTEMPTS|RANDOM_TRAILERS|DISABLE_COOKIES)=' "${PARAMS}" | sed 's/^/  /'
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
  sed -E 's/^(PrivateKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=.*/\1 = [hidden]/' "${CONFIG}"
}

explain_tuning() {
  cat <<'EXPLAIN'
AmneziaWG 3.1 tuning notes

Values are generated at install time from AWG_OBFS_PROFILE and saved in /opt/vpn-stack/awg-params.env.
Supported profiles: dns, quic-lite, video-call, mobile-low-mtu, random-balanced, custom.
AWG 3.1 header protection, content padding, timing ranges, and random trailers are enabled by default.
Cookie replies stay enabled by default for denial-of-service resistance.
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
archive_empty_client_file "${KEY_DIR}/${label}.conf"
archive_empty_client_file "${KEY_DIR}/${name}.conf"
if [[ -f "${KEY_DIR}/${label}.conf" || -f "${KEY_DIR}/${name}.conf" ]]; then
  die "Client config already exists for: ${label}"
fi

domain="$(<"${STACK_DIR}/domain.txt")"
server_public="$(<"${STACK_DIR}/awg-server-public-key.txt")"
client_ip="$(next_ip)" || die "No free IP left in 10.66.66.0/24."
client_private="$(awg genkey)"
client_public="$(printf '%s\n' "${client_private}" | awg pubkey)"
psk="$(awg_genpsk)"

require_writable_dir "${KEY_DIR}"
out="${KEY_DIR}/${label}.conf"
runtime_peer_added=0

if awg show awg0 >/dev/null 2>&1; then
  add_runtime_peer "${client_public}" "${psk}" "${client_ip}"
  runtime_peer_added=1
fi

if ! cat >>"${CONFIG}" <<EOF_PEER

[Peer]
PublicKey = ${client_public}
PresharedKey = ${psk}
AllowedIPs = ${client_ip}/32
EOF_PEER
then
  [[ "${runtime_peer_added}" -eq 1 ]] && remove_runtime_peer "${client_public}"
  storage_hint "$(dirname "${CONFIG}")"
  die "Could not append peer to ${CONFIG}; runtime peer was rolled back."
fi
chmod 0600 "${CONFIG}"

if [[ "${runtime_peer_added}" -eq 0 ]]; then
  if ! systemctl restart awg-quick@awg0.service; then
    drop_peer_from_config_by_public "${client_public}" || true
    die "Could not restart awg-quick@awg0.service; persistent peer was rolled back."
  fi
fi

if ! cat >"${out}" <<EOF_CLIENT
# ${label}
# GeneratedAt = $(date -Is)
# Protocol = AmneziaWG ${AWG_PROTOCOL_VERSION:-3.1}
# ObfuscationProfile = ${AWG_OBFS_PROFILE:-unknown}
# EffectiveProfile = ${AWG_EFFECTIVE_PROFILE:-unknown}
# MTU = ${AWG_MTU:-1420}
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = ${AWG_DNS:-1.1.1.1}
MTU = ${AWG_MTU:-1420}
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
HeaderProtectionKey = ${AWG_HEADER_PROTECTION_KEY}
ContentPaddingAddition = ${AWG_CONTENT_PADDING_ADDITION}
RekeyAfterTime = ${AWG_REKEY_AFTER_TIME}
RekeyTimeout = ${AWG_REKEY_TIMEOUT}
RejectAfterTime = ${AWG_REJECT_AFTER_TIME}
KeepaliveTimeout = ${AWG_KEEPALIVE_TIMEOUT}
MaxHandshakeAttempts = ${AWG_MAX_HANDSHAKE_ATTEMPTS}
RandomTrailers = ${AWG_RANDOM_TRAILERS}
DisableCookies = ${AWG_DISABLE_COOKIES}

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${domain}:${AWG_ENDPOINT_PORT:-443}
AllowedIPs = ${AWG_ALLOWED_IPS:-0.0.0.0/0}
PersistentKeepalive = ${AWG_KEEPALIVE:-25}
EOF_CLIENT
then
  remove_runtime_peer "${client_public}"
  drop_peer_from_config_by_public "${client_public}" || true
  archive_empty_client_file "${out}"
  storage_hint "${KEY_DIR}"
  die "Could not write ${out}; AWG peer was rolled back."
fi
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
XRAY_SERVICE="$(cat "${STACK_DIR}/trojan-xhttp-service.txt" 2>/dev/null || printf 'xray-trojan-xhttp-tls.service')"
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
  local obfs profile port output obfs_type
  obfs="$(<"${STACK_DIR}/hysteria-obfs.txt")"
  {
    printf 'listen: :8443,20000-50000\n'
    printf 'quic:\n'
    printf '  disablePathMTUDiscovery: true\n'
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

  install -d -m 0700 "${STACK_DIR}/hysteria-profiles"
  for profile in gecko mimic; do
    [[ -s "${STACK_DIR}/hysteria-${profile}-port.txt" ]] || continue
    [[ -s "${STACK_DIR}/hysteria-obfs-${profile}.txt" ]] || continue
    if [[ "${profile}" == mimic ]] \
      && [[ "$(cat "${STACK_DIR}/hysteria-mimic-available.txt" 2>/dev/null || printf 0)" != 1 ]]; then
      continue
    fi
    port="$(<"${STACK_DIR}/hysteria-${profile}-port.txt")"
    obfs="$(<"${STACK_DIR}/hysteria-obfs-${profile}.txt")"
    output="${STACK_DIR}/hysteria-profiles/config-${profile}.yaml"
    [[ "${profile}" == gecko ]] && obfs_type=gecko || obfs_type=salamander
    {
      printf 'listen: :%s\n' "${port}"
      printf 'quic:\n  disablePathMTUDiscovery: true\n'
      printf 'tls:\n  cert: /etc/letsencrypt/live/%s/fullchain.pem\n' "$(domain_name)"
      printf '  key: /etc/letsencrypt/live/%s/privkey.pem\n' "$(domain_name)"
      printf 'auth:\n  type: userpass\n  userpass:\n'
      jq -r 'to_entries[] | "    \(.key): \(.value)"' "${HYSTERIA_CLIENTS}"
      printf 'obfs:\n  type: %s\n  %s:\n    password: %s\n' "${obfs_type}" "${obfs_type}" "${obfs}"
      if [[ "${profile}" == gecko ]]; then
        printf '    minPacketSize: 512\n    maxPacketSize: 1200\n'
      else
        printf 'mimic:\n  enabled: true\n  xdpMode: skb\n'
      fi
    } >"${output}"
    chmod 0600 "${output}"
  done
}

write_portal_files() {
  local name="$1" token="$2" trojan_file="$3" hysteria_file="$4" awg_file="$5"
  local trojan_link hysteria_link
  local pubdir base domain label safe_name safe_label
  domain="$(domain_name)"
  label="$(label_name "SUB" "${name}")"
  safe_name="$(html_escape "${name}")"
  safe_label="$(html_escape "${label}")"
  base="https://${domain}/s/${token}"
  pubdir="${WEB_ROOT}/${token}"
  trojan_link="$(<"${trojan_file}")"
  hysteria_link="$(<"${hysteria_file}")"

  install -d -m 0755 "${WEB_ROOT}"
  install -d -m 0750 "${pubdir}"
  {
    printf '%s\n' "${trojan_link}"
    printf '%s\n' "${hysteria_link}"
  } >"${pubdir}/sub.txt"
  b64_nowrap <"${pubdir}/sub.txt" >"${pubdir}/sub.base64"
  /usr/local/bin/vpn-hiddify-profile bundle "${trojan_file}" "${hysteria_file}" \
    --output "${pubdir}/hiddify.json" >/dev/null
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
      <a href="${base}/hiddify.json"><strong>Hiddify JSON</strong>Importable Sing-box profile with DoH through the tunnel</a>
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

  write_portal_files "${name}" "${token}" "${trojan_file}" "${hysteria_file}" "${awg_file}"

  domain="$(domain_name)"
  base="https://${domain}/s/${token}"
  created_at="$(date -Is)"
  jq -n \
    --arg version "1" \
    --arg name "${name}" \
    --arg sub_label "${label}" \
    --arg token "${token}" \
    --arg created_at "${created_at}" \
    --arg portal "${base}" \
    --arg hiddify_json "${base}/hiddify.json" \
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
      "label": $sub_label,
      token: $token,
      status: "active",
      created_at: $created_at,
      labels: {trojan: $trojan_label, hysteria: $hysteria_label, awg: $awg_label},
      urls: {portal: $portal, hiddify_json: $hiddify_json, sub_txt: $sub_txt, sub_base64: $sub_base64, awg_conf: $awg_conf, awg_preview: $awg_preview}
    }' >"${private_dir}/meta.json"
  chmod 0600 "${private_dir}/meta.json"

  printf '\nSubscription: %s\n' "${label}"
  printf 'Portal/import URL: %s\n' "${base}"
  printf 'Hiddify JSON: %s/hiddify.json\n' "${base}"
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
  systemctl restart hysteria2-gecko.service >/dev/null 2>&1 || true
  [[ ! -f "${STACK_DIR}/hysteria-profiles/config-mimic.yaml" ]] \
    || systemctl restart hysteria2-mimic.service >/dev/null 2>&1 || true
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
  archive_file "${KEY_ROOT}/hysteria/${hysteria_label}-gecko.txt" "${KEY_ROOT}/hysteria/revoked"
  archive_file "${KEY_ROOT}/hysteria/${hysteria_label}-mimic.yaml" "${KEY_ROOT}/hysteria/revoked"
  archive_file "${KEY_ROOT}/awg/${awg_label}.conf" "${KEY_ROOT}/awg/revoked"
  archive_file "${KEY_ROOT}/hiddify-json/trojan/${trojan_label}.json" "${KEY_ROOT}/hiddify-json/revoked"
  archive_file "${KEY_ROOT}/hiddify-json/hysteria/${hysteria_label}.json" "${KEY_ROOT}/hiddify-json/revoked"

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
    "Hiddify JSON: \(.urls.hiddify_json // \"not generated for this existing subscription\")",
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

install_helper_bot_export() {
  cat >/usr/local/bin/vpn-bot-export <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

TELEGRAM_ENV="${GOLDEN_ISSUER_BOT_ENV:-/etc/golden-vpn-installer/issuer-bot.env}"
if [[ -r "${TELEGRAM_ENV}" ]]; then
  telegram_env_mode="$(stat -c '%a' "${TELEGRAM_ENV}")"
  (( (8#${telegram_env_mode} & 077) == 0 )) || die "${TELEGRAM_ENV} must not be accessible by group or others"
  set -a
  # shellcheck disable=SC1090
  source "${TELEGRAM_ENV}"
  set +a
fi

usage() {
  cat <<'USAGE'
Usage:
  vpn-bot-export audit --out /root/vpn-keys/bot-export/server-audit.json
  vpn-bot-export keys --plan plan_30 --out /root/vpn-keys/bot-export/keys.sqlite
  vpn-bot-export inventory --type all --plan plan_30 --out /root/vpn-keys/bot-export/active-keys.sqlite [--send]
  vpn-bot-export batch --type awg --count 20 --prefix stock --plan plan_30 [--send]
  vpn-bot-export send /root/vpn-keys/bot-export/active-keys.sqlite [--caption TEXT]
  vpn-bot-export emergency --map /root/vpn-migration/map.csv --out /root/vpn-keys/bot-export/emergency.sqlite
  vpn-bot-export fingerprint /root/vpn-keys/awg/AWG-US-phone1.conf

Options:
  --source DIR       AWG config source directory for audit/keys, default /root/vpn-keys/awg
  --plan CODE        Bot plan code for keys export, or fallback plan for emergency rows
  --out FILE         Output JSON/SQLite file
  --map FILE         CSV map for emergency export
  --expires-at ISO   Optional expires_at value for keys export
  --comment TEXT     Optional comment for keys export
  --type TYPE        awg, trojan, hysteria, or all for inventory; one type for batch
  --count NUMBER     Number of new keys for batch (1..500)
  --prefix NAME      Batch client-name prefix; generated names end in -0001, -0002, ...
  --send             Send the generated SQLite file to the configured Telegram bot/chat
  --caption TEXT     Optional Telegram document caption

Golden issuer bot configuration (root-only 0600):
  /etc/golden-vpn-installer/issuer-bot.env
  GOLDEN_ISSUER_BOT_TOKEN=123456:token
  GOLDEN_ISSUER_CHAT_ID=-1001234567890

Emergency CSV columns:
  client_name,old_key_fingerprint,old_conf_path,new_conf_path,plan_code,new_external_ref,new_comment,expires_at

Bot compatibility:
  keys.sqlite table: keys(plan_code, conf_text, external_ref, comment, expires_at)
  emergency.sqlite table: emergency_replacements(old_key_fingerprint, old_conf_text, new_conf_text, plan_code, new_external_ref, new_comment, expires_at)
USAGE
}

if [[ "${EUID}" -ne 0 && "${VPN_BOT_EXPORT_ALLOW_NON_ROOT:-0}" != "1" ]]; then
  die "Run as root, or set VPN_BOT_EXPORT_ALLOW_NON_ROOT=1 for local tests only."
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" || $# -eq 0 ]]; then
  usage
  exit 0
fi

python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

STACK_DIR = Path(os.environ.get("VPN_BOT_STACK_DIR", "/opt/vpn-stack"))
KEY_ROOT = Path(os.environ.get("VPN_BOT_KEY_ROOT", "/root/vpn-keys"))
AWG_DIR = KEY_ROOT / "awg"
EXPORT_DIR = KEY_ROOT / "bot-export"
TYPE_DIRS = {
    "awg": KEY_ROOT / "awg",
    "trojan": KEY_ROOT / "trojan",
    "hysteria": KEY_ROOT / "hysteria",
}
TYPE_SUFFIXES = {"awg": (".conf",), "trojan": (".txt",), "hysteria": (".txt", ".yaml")}
TYPE_BATCH_SUFFIX = {"awg": ".conf", "trojan": ".txt", "hysteria": ".txt"}
TYPE_HELPERS = {"awg": "vpn-awg", "trojan": "vpn-trojan", "hysteria": "vpn-hysteria"}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def ensure_private_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass


def write_json(path: Path, payload: dict) -> None:
    ensure_private_parent(path)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def connect_sqlite_out(path: Path) -> tuple[sqlite3.Connection, Path]:
    ensure_private_parent(path)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    if tmp.exists():
        tmp.unlink()
    return sqlite3.connect(tmp), tmp


def finish_sqlite(connection: sqlite3.Connection, tmp: Path, out: Path) -> None:
    connection.commit()
    connection.close()
    os.chmod(tmp, 0o600)
    os.replace(tmp, out)
    os.chmod(out, 0o600)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{path} is not valid UTF-8: {exc}")
    except OSError as exc:
        fail(f"Cannot read {path}: {exc}")


def normalize_conf_text(value: str) -> str:
    text = value.replace("\r\n", "\n").replace("\r", "\n").strip("\ufeff \t\r\n")
    return "\n".join(line.rstrip() for line in text.split("\n"))


def read_conf(path: Path) -> str:
    if not path.is_file():
        fail(f"Config file not found: {path}")
    return normalize_conf_text(read_text(path))


def fingerprint_text(conf_text: str) -> str:
    return hashlib.sha256(normalize_conf_text(conf_text).encode("utf-8")).hexdigest()


def read_optional(path: Path, default: str = "") -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return default


def awg_files(source: Path) -> list[Path]:
    if not source.is_dir():
        fail(f"AWG source directory not found: {source}")
    return sorted(path for path in source.iterdir() if path.is_file() and path.suffix == ".conf")


def conf_value(conf_text: str, key: str) -> str | None:
    prefix = f"{key} ="
    for line in conf_text.splitlines():
        stripped = line.strip()
        if stripped.startswith(prefix):
            return stripped.split("=", 1)[1].strip()
    return None


def server_location() -> str:
    value = read_optional(STACK_DIR / "server-location.txt", "XX").upper()
    if len(value) == 2 and value.isalpha() and value.isascii():
        return value
    return "XX"


def default_external_ref(label: str) -> str:
    return f"golden-vpn:{server_location()}:{label}"


def key_rows(source: Path, plan: str, expires_at: str | None, comment: str | None) -> list[tuple[str, str, str, str | None, str | None]]:
    if not plan:
        fail("--plan is required for keys export")
    rows = []
    for path in awg_files(source):
        conf = read_conf(path)
        label = path.stem
        rows.append((plan, conf, default_external_ref(label), comment or f"Golden VPN AWG {label}", expires_at))
    if not rows:
        fail(f"No .conf files found in {source}")
    return rows


def command_keys(args: argparse.Namespace) -> None:
    out = Path(args.out or EXPORT_DIR / "keys.sqlite")
    rows = key_rows(Path(args.source), args.plan, args.expires_at, args.comment)
    connection, tmp = connect_sqlite_out(out)
    try:
        connection.execute(
            "CREATE TABLE export_meta (format_version TEXT NOT NULL, exported_at TEXT NOT NULL, source TEXT NOT NULL)"
        )
        connection.execute(
            "INSERT INTO export_meta(format_version, exported_at, source) VALUES (?, ?, ?)",
            ("vpn-seller-lite.keys.v1", now_iso(), "golden-vpn"),
        )
        connection.execute(
            """
            CREATE TABLE keys (
              plan_code TEXT NOT NULL,
              conf_text TEXT NOT NULL,
              external_ref TEXT,
              comment TEXT,
              expires_at TEXT
            )
            """
        )
        connection.executemany(
            "INSERT INTO keys(plan_code, conf_text, external_ref, comment, expires_at) VALUES (?, ?, ?, ?, ?)",
            rows,
        )
        finish_sqlite(connection, tmp, out)
    except Exception:
        connection.close()
        if tmp.exists():
            tmp.unlink()
        raise
    print(f"Exported {len(rows)} AWG configs: {out}")
    print("Import in vpn-seller-lite with /admin_import.")


def command_audit(args: argparse.Namespace) -> None:
    source = Path(args.source)
    out = Path(args.out or EXPORT_DIR / "server-audit.json")
    domain = read_optional(STACK_DIR / "domain.txt", "unknown")
    location = server_location()
    params = {}
    params_path = STACK_DIR / "awg-params.env"
    if params_path.exists():
        for line in read_text(params_path).splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                if key.startswith("AWG_"):
                    params[key] = value.strip().strip('"').strip("'")
    report_path = KEY_ROOT / "install-report.json"
    report_status = {"path": str(report_path), "exists": report_path.exists()}
    if report_path.exists():
        try:
            report_json = json.loads(read_text(report_path))
            report_status["generated_at"] = report_json.get("generated_at")
        except Exception as exc:
            report_status["error"] = str(exc)

    keys = []
    for path in awg_files(source):
        conf = read_conf(path)
        keys.append(
            {
                "label": path.stem,
                "path": str(path),
                "fingerprint": fingerprint_text(conf),
                "address": conf_value(conf, "Address"),
                "endpoint": conf_value(conf, "Endpoint"),
                "mtime": datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).isoformat(),
            }
        )
    payload = {
        "format_version": "golden-vpn.bot-audit.v1",
        "generated_at": now_iso(),
        "domain": domain,
        "server_location": location,
        "awg": {
            "source_dir": str(source),
            "protocol_version": params.get("AWG_PROTOCOL_VERSION", "unknown"),
            "endpoint_port": params.get("AWG_ENDPOINT_PORT", "443"),
            "profile": params.get("AWG_OBFS_PROFILE", "unknown"),
            "mtu": params.get("AWG_MTU", "unknown"),
            "key_count": len(keys),
            "keys": keys,
        },
        "install_report": report_status,
        "notes": "No private keys or config bodies are included in this audit JSON.",
    }
    write_json(out, payload)
    print(f"Audit written: {out}")
    print(f"AWG key count: {len(keys)}")


def validate_key_type(value: str, allow_all: bool = False) -> str:
    allowed = set(TYPE_DIRS)
    if allow_all:
        allowed.add("all")
    if value not in allowed:
        fail(f"Unsupported key type: {value}; expected {', '.join(sorted(allowed))}")
    return value


def typed_key_files(key_type: str) -> list[tuple[str, Path]]:
    selected = sorted(TYPE_DIRS) if key_type == "all" else [validate_key_type(key_type)]
    result: list[tuple[str, Path]] = []
    for current_type in selected:
        directory = TYPE_DIRS[current_type]
        suffixes = TYPE_SUFFIXES[current_type]
        if not directory.is_dir():
            continue
        result.extend(
            (current_type, path)
            for path in sorted(directory.iterdir())
            if path.is_file() and path.suffix in suffixes
        )
    return result


def typed_rows(
    files: list[tuple[str, Path]],
    plan: str | None,
    expires_at: str | None,
    comment: str | None,
    key_status: str,
) -> list[tuple[str, str, str, str, str | None, str, str | None, str | None]]:
    rows = []
    for key_type, path in files:
        config_text = read_conf(path)
        label = path.stem
        rows.append(
            (
                key_type,
                label,
                key_status,
                config_text,
                plan,
                default_external_ref(label),
                comment or f"Golden VPN {key_type.upper()} {label}",
                expires_at,
            )
        )
    return rows


def write_typed_bundle(
    out: Path,
    rows: list[tuple[str, str, str, str, str | None, str, str | None, str | None]],
    source: str,
) -> None:
    if not rows:
        fail("No active key files matched the requested type")
    connection, tmp = connect_sqlite_out(out)
    try:
        connection.execute(
            "CREATE TABLE export_meta (format_version TEXT NOT NULL, exported_at TEXT NOT NULL, source TEXT NOT NULL)"
        )
        connection.execute(
            "INSERT INTO export_meta(format_version, exported_at, source) VALUES (?, ?, ?)",
            ("golden-vpn.typed-keys.v1", now_iso(), source),
        )
        connection.execute(
            """
            CREATE TABLE typed_keys (
              key_type TEXT NOT NULL,
              label TEXT NOT NULL,
              key_status TEXT NOT NULL,
              config_text TEXT NOT NULL,
              plan_code TEXT,
              external_ref TEXT,
              comment TEXT,
              expires_at TEXT
            )
            """
        )
        connection.executemany(
            """
            INSERT INTO typed_keys(
              key_type, label, key_status, config_text, plan_code, external_ref, comment, expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        connection.execute("CREATE INDEX typed_keys_type_label ON typed_keys(key_type, label)")
        finish_sqlite(connection, tmp, out)
    except Exception:
        connection.close()
        if tmp.exists():
            tmp.unlink()
        raise


def telegram_credentials() -> tuple[str, str]:
    token = os.environ.get("GOLDEN_ISSUER_BOT_TOKEN", "").strip()
    chat_id = os.environ.get("GOLDEN_ISSUER_CHAT_ID", "").strip()
    if not token or not chat_id:
        fail("Issuer bot is not configured; set GOLDEN_ISSUER_BOT_TOKEN and GOLDEN_ISSUER_CHAT_ID in the root-only issuer-bot.env")
    return token, chat_id


def telegram_send_document(path: Path, caption: str | None = None) -> None:
    if not path.is_file():
        fail(f"Telegram document not found: {path}")
    token, chat_id = telegram_credentials()
    boundary = f"----golden-vpn-{uuid.uuid4().hex}"
    chunks: list[bytes] = []

    def field(name: str, value: str) -> None:
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                value.encode("utf-8"),
                b"\r\n",
            ]
        )

    field("chat_id", chat_id)
    if caption:
        field("caption", caption[:1024])
    chunks.extend(
        [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="document"; filename="{path.name}"\r\n'.encode(),
            b"Content-Type: application/vnd.sqlite3\r\n\r\n",
            path.read_bytes(),
            b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
    )
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendDocument",
        data=b"".join(chunks),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        fail(f"Telegram sendDocument failed: {type(exc).__name__}")
    if not payload.get("ok"):
        fail("Telegram sendDocument returned ok=false")
    print(f"Sent to Telegram: {path.name}")


def command_inventory(args: argparse.Namespace) -> None:
    key_type = validate_key_type(args.type, allow_all=True)
    if args.send and key_type != "all":
        fail("Telegram inventory delivery must use --type all so every active key type is included in one bundle")
    out = Path(args.out or EXPORT_DIR / f"active-{key_type}-keys.sqlite")
    rows = typed_rows(typed_key_files(key_type), args.plan, args.expires_at, args.comment, "issued")
    write_typed_bundle(out, rows, "golden-vpn-active-inventory")
    counts: dict[str, int] = {}
    for row in rows:
        counts[row[0]] = counts.get(row[0], 0) + 1
    print(f"Exported {len(rows)} active keys: {out}")
    print("Types: " + ", ".join(f"{name}={count}" for name, count in sorted(counts.items())))
    if args.send:
        telegram_send_document(out, args.caption or f"Golden VPN active keys ({key_type})")


def validate_batch_name(prefix: str) -> str:
    if not prefix or len(prefix) > 48 or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for ch in prefix):
        fail("--prefix must be 1..48 characters from [A-Za-z0-9._-]")
    return prefix


def expected_key_path(key_type: str, name: str) -> Path:
    label = f"{key_type.upper()}-{server_location()}-{name}"
    return TYPE_DIRS[key_type] / f"{label}{TYPE_BATCH_SUFFIX[key_type]}"


def command_batch(args: argparse.Namespace) -> None:
    key_type = validate_key_type(args.type)
    count = args.count
    if count < 1 or count > 500:
        fail("--count must be between 1 and 500")
    prefix = validate_batch_name(args.prefix)
    helper = TYPE_HELPERS[key_type]
    if not shutil.which(helper):
        fail(f"Required helper is missing: {helper}")

    names = [f"{prefix}-{index:04d}" for index in range(1, count + 1)]
    paths = [expected_key_path(key_type, name) for name in names]
    collisions = [path for path in paths if path.exists()]
    if collisions:
        fail(f"Batch would overwrite an existing key: {collisions[0]}")

    created: list[tuple[str, Path]] = []
    for index, (name, path) in enumerate(zip(names, paths), start=1):
        result = subprocess.run(
            [helper, name],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0 or not path.is_file():
            fail(f"Batch stopped at {index}/{count}; {len(created)} keys were created and were not removed")
        created.append((key_type, path))

    out = Path(args.out or EXPORT_DIR / f"batch-{key_type}-{prefix}-{int(time.time())}.sqlite")
    rows = typed_rows(created, args.plan, args.expires_at, args.comment, "available")
    write_typed_bundle(out, rows, "golden-vpn-generated-batch")
    print(f"Created and exported {len(rows)} {key_type} keys: {out}")
    if args.send:
        telegram_send_document(out, args.caption or f"Golden VPN batch: {key_type}, {len(rows)} keys")


def command_send(args: argparse.Namespace) -> None:
    telegram_send_document(Path(args.file), args.caption)


def require_csv_columns(fieldnames: list[str] | None, required: set[str], source: Path) -> None:
    if not fieldnames:
        fail(f"CSV has no header: {source}")
    missing = required - set(fieldnames)
    if missing:
        fail(f"CSV is missing required columns: {', '.join(sorted(missing))}")


def command_emergency(args: argparse.Namespace) -> None:
    source = Path(args.map)
    out = Path(args.out or EXPORT_DIR / "emergency.sqlite")
    if not source.is_file():
        fail(f"CSV map not found: {source}")
    rows = []
    with source.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        require_csv_columns(reader.fieldnames, {"new_conf_path"}, source)
        for row_number, row in enumerate(reader, start=2):
            client_name = (row.get("client_name") or "").strip()
            old_fingerprint = (row.get("old_key_fingerprint") or "").strip()
            old_conf_path = (row.get("old_conf_path") or "").strip()
            new_conf_path = (row.get("new_conf_path") or "").strip()
            if not new_conf_path:
                fail(f"Row {row_number}: new_conf_path is required")
            if not old_fingerprint:
                if not old_conf_path:
                    fail(f"Row {row_number}: old_key_fingerprint or old_conf_path is required")
                old_fingerprint = fingerprint_text(read_conf(Path(old_conf_path)))
            new_conf = read_conf(Path(new_conf_path))
            plan_code = (row.get("plan_code") or args.plan or "").strip() or None
            new_external_ref = (row.get("new_external_ref") or "").strip()
            if not new_external_ref:
                new_external_ref = default_external_ref(Path(new_conf_path).stem)
            new_comment = (row.get("new_comment") or "").strip()
            if not new_comment:
                new_comment = f"Golden VPN emergency replacement {client_name or Path(new_conf_path).stem}"
            expires_at = (row.get("expires_at") or "").strip() or None
            rows.append((old_fingerprint, None, new_conf, plan_code, new_external_ref, new_comment, expires_at))
    if not rows:
        fail(f"CSV map has no rows: {source}")

    connection, tmp = connect_sqlite_out(out)
    try:
        connection.execute(
            "CREATE TABLE export_meta (format_version TEXT NOT NULL, exported_at TEXT NOT NULL, source TEXT NOT NULL)"
        )
        connection.execute(
            "INSERT INTO export_meta(format_version, exported_at, source) VALUES (?, ?, ?)",
            ("vpn-seller-lite.emergency.v1", now_iso(), "golden-vpn"),
        )
        connection.execute(
            """
            CREATE TABLE emergency_replacements (
              old_key_fingerprint TEXT,
              old_conf_text TEXT,
              new_conf_text TEXT NOT NULL,
              plan_code TEXT,
              new_external_ref TEXT,
              new_comment TEXT,
              expires_at TEXT
            )
            """
        )
        connection.executemany(
            """
            INSERT INTO emergency_replacements(
              old_key_fingerprint, old_conf_text, new_conf_text, plan_code,
              new_external_ref, new_comment, expires_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )
        finish_sqlite(connection, tmp, out)
    except Exception:
        connection.close()
        if tmp.exists():
            tmp.unlink()
        raise
    print(f"Exported {len(rows)} emergency replacements: {out}")
    print("Apply in vpn-seller with /admin_emergency; Golden does not notify customers or assign replacements.")


def command_fingerprint(args: argparse.Namespace) -> None:
    print(fingerprint_text(read_conf(Path(args.conf_path))))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vpn-bot-export", add_help=True)
    sub = parser.add_subparsers(dest="command", required=True)

    audit = sub.add_parser("audit", help="write a secret-free server audit JSON")
    audit.add_argument("--source", default=str(AWG_DIR))
    audit.add_argument("--out", default=str(EXPORT_DIR / "server-audit.json"))
    audit.set_defaults(func=command_audit)

    keys = sub.add_parser("keys", help="export AWG configs as vpn-seller-lite keys.sqlite")
    keys.add_argument("--source", default=str(AWG_DIR))
    keys.add_argument("--plan", required=True)
    keys.add_argument("--out", default=str(EXPORT_DIR / "keys.sqlite"))
    keys.add_argument("--expires-at")
    keys.add_argument("--comment")
    keys.set_defaults(func=command_keys)

    inventory = sub.add_parser("inventory", help="export active AWG/Trojan/Hysteria keys with explicit types")
    inventory.add_argument("--type", default="all", choices=["all", "awg", "trojan", "hysteria"])
    inventory.add_argument("--plan", required=True)
    inventory.add_argument("--out")
    inventory.add_argument("--expires-at")
    inventory.add_argument("--comment")
    inventory.add_argument("--send", action="store_true")
    inventory.add_argument("--caption")
    inventory.set_defaults(func=command_inventory)

    batch = sub.add_parser("batch", help="create a typed key batch and export it as SQLite")
    batch.add_argument("--type", required=True, choices=["awg", "trojan", "hysteria"])
    batch.add_argument("--count", required=True, type=int)
    batch.add_argument("--prefix", required=True)
    batch.add_argument("--plan", required=True)
    batch.add_argument("--out")
    batch.add_argument("--expires-at")
    batch.add_argument("--comment")
    batch.add_argument("--send", action="store_true")
    batch.add_argument("--caption")
    batch.set_defaults(func=command_batch)

    send = sub.add_parser("send", help="send an existing export file to Telegram")
    send.add_argument("file")
    send.add_argument("--caption")
    send.set_defaults(func=command_send)

    emergency = sub.add_parser("emergency", help="prepare a replacement mapping bundle for vpn-seller")
    emergency.add_argument("--map", required=True)
    emergency.add_argument("--plan")
    emergency.add_argument("--out", default=str(EXPORT_DIR / "emergency.sqlite"))
    emergency.set_defaults(func=command_emergency)

    fingerprint = sub.add_parser("fingerprint", help="print bot-compatible config fingerprint")
    fingerprint.add_argument("conf_path")
    fingerprint.set_defaults(func=command_fingerprint)
    return parser


def main(argv: list[str]) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main(sys.argv[1:])
PY
EOF
  chmod 0755 /usr/local/bin/vpn-bot-export
}

install_helper_cert_notify() {
  cat >/usr/local/bin/vpn-cert-notify <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

TELEGRAM_ENV="${GOLDEN_ISSUER_BOT_ENV:-/etc/golden-vpn-installer/issuer-bot.env}"
if [[ -r "${TELEGRAM_ENV}" ]]; then
  telegram_env_mode="$(stat -c '%a' "${TELEGRAM_ENV}")"
  (( (8#${telegram_env_mode} & 077) == 0 )) || die "${TELEGRAM_ENV} must not be accessible by group or others"
  set -a
  # shellcheck disable=SC1090
  source "${TELEGRAM_ENV}"
  set +a
fi

python3 - "$@" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

STACK_DIR = Path(os.environ.get("VPN_CERT_STACK_DIR", "/opt/vpn-stack"))
CERT_ROOT = Path(os.environ.get("VPN_CERT_ROOT", "/etc/letsencrypt/live"))
STATE_DIR = Path(os.environ.get("VPN_CERT_STATE_DIR", "/var/lib/golden-vpn"))
STATE_PATH = STATE_DIR / "cert-notify-state.json"
THRESHOLDS = (30, 14, 7, 3, 1, 0)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_text(path: Path, default: str = "") -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return default


def load_state() -> dict:
    try:
        value = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(value: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    tmp = STATE_PATH.with_name(f".{STATE_PATH.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE_PATH)
    os.chmod(STATE_PATH, 0o600)


def cert_details() -> dict:
    domain = read_text(STACK_DIR / "domain.txt")
    if not domain:
        fail("Golden VPN domain is unknown")
    cert_path = CERT_ROOT / domain / "fullchain.pem"
    if not cert_path.is_file():
        fail(f"Certificate not found: {cert_path}")
    pem = cert_path.read_text(encoding="ascii")
    end_marker = "-----END CERTIFICATE-----"
    marker_index = pem.find(end_marker)
    if marker_index < 0:
        fail(f"Certificate PEM is invalid: {cert_path}")
    leaf_pem = pem[: marker_index + len(end_marker)] + "\n"
    der = ssl.PEM_cert_to_DER_cert(leaf_pem)
    decoded = ssl._ssl._test_decode_cert(str(cert_path))
    expires = datetime.strptime(decoded["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    now = datetime.now(tz=timezone.utc)
    seconds = (expires - now).total_seconds()
    days = max(-1, int(seconds // 86400))
    return {
        "domain": domain,
        "path": str(cert_path),
        "fingerprint": hashlib.sha256(der).hexdigest(),
        "expires_at": expires.isoformat(),
        "days_remaining": days,
        "hostname": socket.gethostname(),
    }


def telegram_send(message: str, dry_run: bool = False) -> None:
    if dry_run:
        print(message)
        return
    token = os.environ.get("GOLDEN_ISSUER_BOT_TOKEN", "").strip()
    chat_id = os.environ.get("GOLDEN_ISSUER_CHAT_ID", "").strip()
    if not token or not chat_id:
        fail("Golden issuer bot is not configured in the root-only issuer-bot.env")
    body = urllib.parse.urlencode({"chat_id": chat_id, "text": message}).encode()
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage", data=body, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        fail(f"Telegram sendMessage failed: {type(exc).__name__}")
    if not payload.get("ok"):
        fail("Telegram sendMessage returned ok=false")


def threshold_for(days: int) -> int | None:
    for threshold in reversed(THRESHOLDS):
        if days <= threshold:
            return threshold
    return None


def command_check(dry_run: bool) -> None:
    details = cert_details()
    state = load_state()
    fingerprint = details["fingerprint"]
    previous = state.get("fingerprint")
    if previous and previous != fingerprint:
        telegram_send(
            f"Golden VPN TLS certificate replaced\n"
            f"Server: {details['hostname']}\nDomain: {details['domain']}\n"
            f"Valid until: {details['expires_at']}",
            dry_run,
        )
        state["last_replacement_fingerprint"] = fingerprint

    threshold = threshold_for(details["days_remaining"])
    warning_key = f"{fingerprint}:{threshold}" if threshold is not None else None
    if warning_key and state.get("last_warning") != warning_key:
        telegram_send(
            f"Golden VPN TLS certificate expires soon\n"
            f"Server: {details['hostname']}\nDomain: {details['domain']}\n"
            f"Days remaining: {details['days_remaining']}\nValid until: {details['expires_at']}",
            dry_run,
        )
        state["last_warning"] = warning_key

    state.update({"fingerprint": fingerprint, "last_check": datetime.now(tz=timezone.utc).isoformat(), **details})
    if not dry_run:
        save_state(state)
    print(f"Certificate OK: {details['domain']}, {details['days_remaining']} days remaining")


def command_renewed(dry_run: bool) -> None:
    details = cert_details()
    state = load_state()
    if state.get("last_replacement_fingerprint") != details["fingerprint"]:
        telegram_send(
            f"Golden VPN TLS certificate renewed\n"
            f"Server: {details['hostname']}\nDomain: {details['domain']}\n"
            f"Valid until: {details['expires_at']}",
            dry_run,
        )
    state.update(
        {
            "fingerprint": details["fingerprint"],
            "last_replacement_fingerprint": details["fingerprint"],
            "last_warning": None,
            "last_renewal_notification": datetime.now(tz=timezone.utc).isoformat(),
            **details,
        }
    )
    if not dry_run:
        save_state(state)
    print(f"Renewal recorded: {details['domain']}")


def main(argv: list[str]) -> None:
    command = argv[0] if argv else "check"
    dry_run = "--dry-run" in argv[1:]
    if command == "check":
        command_check(dry_run)
    elif command == "renewed":
        command_renewed(dry_run)
    elif command == "test":
        details = cert_details()
        telegram_send(
            f"Golden VPN Telegram test\nServer: {details['hostname']}\nDomain: {details['domain']}",
            dry_run,
        )
        print("Telegram test sent" if not dry_run else "Telegram test dry-run")
    else:
        fail("Usage: vpn-cert-notify [check|renewed|test] [--dry-run]")


if __name__ == "__main__":
    main(sys.argv[1:])
PY
EOF
  chmod 0755 /usr/local/bin/vpn-cert-notify
}

install_helper_help() {
  cat >/usr/local/bin/vpn-help <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

is_tty() {
  [[ -t 1 && "${TERM:-}" != "dumb" ]]
}

if is_tty; then
  bold=$'\033[1m'
  dim=$'\033[2m'
  cyan=$'\033[36m'
  green=$'\033[32m'
  yellow=$'\033[33m'
  reset=$'\033[0m'
else
  bold=""
  dim=""
  cyan=""
  green=""
  yellow=""
  reset=""
fi

show_key_if_exists() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    echo "No saved key yet: ${file}"
  fi
}

read_value() {
  local file="$1"
  local fallback="$2"
  if [[ -r "${file}" ]]; then
    cat "${file}"
  else
    printf '%s' "${fallback}"
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

print_header() {
  local domain location
  domain="$(read_value /opt/vpn-stack/domain.txt DOMAIN)"
  location="$(read_value /opt/vpn-stack/server-location.txt XX)"

  printf '%sGolden VPN menu%s\n' "${bold}${cyan}" "${reset}"
  printf 'Domain: %s    Location: %s\n' "${domain}" "${location}"
  printf '%sUse: vpn-help <number> [name], for example: vpn-help 1 phone1%s\n\n' "${dim}" "${reset}"
}

menu_item() {
  local num="$1"
  local title="$2"
  local hint="$3"
  printf '  %2s. %s%-34s%s %s\n' "${num}" "${green}" "${title}" "${reset}" "${hint}"
}

print_menu() {
  print_header
  menu_item 1 "Trojan XHTTP TLS" "create/show client"
  menu_item 2 "Hysteria2" "create/show client"
  menu_item 3 "AmneziaWG" "create/show client"
  menu_item 4 "Subscription bundle" "create/list/show/revoke/rotate"
  menu_item 5 "Saved keys and reports" "where files are stored"
  menu_item 6 "AWG tools" "profile, explain, diagnostics"
  menu_item 7 "Install status" "progress, logs, reports"
  menu_item 8 "Service health" "systemd checks"
  menu_item 9 "Grafana access" "SSH tunnel and dashboard 1860"
  menu_item 10 "Decoy and public URLs" "site and subscription URL shapes"
  menu_item 11 "Bot export" "typed SQLite bundles and Telegram delivery"
  printf '\n%sNo prompt is shown on login; this menu is printed and your shell stays usable.%s\n' "${yellow}" "${reset}"
}

topic_trojan() {
  local name="${1:-}"
  if [[ -n "${name}" ]]; then
    show_key_if_exists "/root/vpn-keys/trojan/$(label_name "TROJAN" "${name}").txt"
    return 0
  fi
  cat <<'HELP'
1. Trojan XHTTP TLS

Create a client:
  vpn-trojan phone1

Show saved client material:
  vpn-help 1 phone1
  vpn-help trojan phone1

Saved path:
  /root/vpn-keys/trojan/TROJAN-<LOCATION>-<name>.txt
HELP
}

topic_hysteria() {
  local name="${1:-}"
  if [[ -n "${name}" ]]; then
    local label
    label="$(label_name "HYSTERIA" "${name}")"
    for file in \
      "/root/vpn-keys/hysteria/${label}.txt" \
      "/root/vpn-keys/hysteria/${label}-gecko.txt" \
      "/root/vpn-keys/hysteria/${label}-mimic.yaml"; do
      [[ ! -f "${file}" ]] || { printf '\n%s:\n' "${file}"; cat "${file}"; }
    done
    return 0
  fi
  cat <<'HELP'
2. Hysteria2

Create a client:
  vpn-hysteria phone1
  vpn-hysteria phone1 salamander
  vpn-hysteria phone1 gecko
  vpn-hysteria phone1 mimic

Salamander is the default and works with ordinary Hysteria2 clients.
Gecko creates a separate URI on a persistent random UDP port.
Mimic creates a Linux-only YAML and requires Mimic, root, eBPF, and kernel 6.1+.
Issuing another profile for an existing name reuses its username/password.

Show saved client material:
  vpn-help 2 phone1
  vpn-help hysteria phone1

Saved path:
  /root/vpn-keys/hysteria/HYSTERIA-<LOCATION>-<name>.txt
  /root/vpn-keys/hysteria/HYSTERIA-<LOCATION>-<name>-gecko.txt
  /root/vpn-keys/hysteria/HYSTERIA-<LOCATION>-<name>-mimic.yaml
HELP
}

topic_awg() {
  local name="${1:-}"
  if [[ -n "${name}" ]]; then
    show_key_if_exists "/root/vpn-keys/awg/$(label_name "AWG" "${name}").conf"
    return 0
  fi
  cat <<'HELP'
3. AmneziaWG

Create a client:
  vpn-awg phone1

Show saved client material:
  vpn-help 3 phone1
  vpn-help awg phone1

Lifecycle:
  vpn-awg list
  vpn-awg show phone1
  vpn-awg revoke phone1
  vpn-awg rotate phone1

Saved path:
  /root/vpn-keys/awg/AWG-<LOCATION>-<name>.conf
HELP
}

topic_subscription() {
  cat <<'HELP'
4. Subscription bundle

Create a Hiddify-style static bundle:
  vpn-sub create phone1

Manage bundles:
  vpn-sub list
  vpn-sub show phone1
  vpn-sub revoke phone1
  vpn-sub rotate phone1

URL shape:
  https://DOMAIN/s/<token>
  https://DOMAIN/s/<token>/hiddify.json
  https://DOMAIN/s/<token>/sub.txt
  https://DOMAIN/s/<token>/sub.base64
  https://DOMAIN/s/<token>/awg.conf
HELP
}

topic_files() {
  cat <<'HELP'
5. Saved keys and reports

Client material:
  /root/vpn-keys/trojan/
  /root/vpn-keys/hysteria/
  /root/vpn-keys/awg/

Install reports:
  /root/vpn-keys/install-report.txt
  /root/vpn-keys/install-report.json
  /opt/vpn-stack/awg-tuning-report.json
  /opt/vpn-stack/decoy-manifest.json

Subscription files:
  metadata: /opt/vpn-stack/subscriptions/<token>/meta.json
  public: /var/www/subscriptions/<token>/
HELP
}

topic_awg_tools() {
  cat <<'HELP'
6. AWG tools

Profile and current config:
  vpn-awg profile
  vpn-awg explain
  vpn-awg show-config

Diagnostics are explicit only:
  vpn-awg analyze
  vpn-awg analyze 20
  vpn-awg capture 30
  vpn-awg analyze-live 20

Packet captures can contain metadata. Keep pcap files private.
HELP
}

topic_install_status() {
  cat <<'HELP'
7. Install status

Automatic login behavior:
  /root/.bashrc runs vpn-install-status auto during reboot resume.
  No command input is required after reboot to see progress and logs.

Manual commands:
  vpn-install-status status
  vpn-install-status watch
  vpn-install-status log 200

Resume log:
  /var/log/vpn-stack-resume-install.log
HELP
}

topic_services() {
  cat <<'HELP'
8. Service health

Check services:
  systemctl status nginx --no-pager
  systemctl status xray-trojan-xhttp-tls --no-pager
  systemctl status hysteria2 --no-pager
  systemctl status awg-quick@awg0 --no-pager -l
  systemctl status prometheus --no-pager
  systemctl status prometheus-node-exporter --no-pager
  systemctl status grafana-server --no-pager

Validate the installed stack:
  install-vpn-stack.sh validate
HELP
}

topic_grafana() {
  cat <<'HELP'
9. Grafana access

Grafana is localhost-only on the server.

SSH tunnel:
  ssh -L 3000:127.0.0.1:3000 root@SERVER_IP

Open:
  http://localhost:3000

Default login:
  admin / admin

Dashboard:
  Node Exporter Full dashboard ID 1860 is provisioned when download succeeds.
  Manual import: Grafana -> Dashboards -> New -> Import -> 1860 -> datasource Prometheus
HELP
}

topic_public_urls() {
  cat <<'HELP'
10. Decoy and public URLs

Decoy site:
  https://DOMAIN/

Regenerate or preview decoy:
  vpn-decoy-regenerate
  vpn-decoy-preview

Subscription URL shape:
  https://DOMAIN/s/<token>

Install reports never print subscription tokens or client secrets.
HELP
}

topic_bot_export() {
  cat <<'HELP'
11. Bot export

Export typed AWG, Trojan, and Hysteria keys into vpn-seller SQLite bundles.

Golden issuer bot credentials (file mode 0600):
  /etc/golden-vpn-installer/issuer-bot.env

Secret-free server audit:
  vpn-bot-export audit --out /root/vpn-keys/bot-export/server-audit.json

Active key inventory (imported as issued):
  vpn-bot-export inventory --type all --plan plan_30 --out /root/vpn-keys/bot-export/active.sqlite --send

Create bot stock (imported as available):
  vpn-bot-export batch --type awg --count 20 --prefix stock --plan plan_30 --send

Supported batch types: awg, trojan, hysteria.

Emergency replacement bundle:
  vpn-bot-export emergency --map /root/vpn-migration/map.csv --out /root/vpn-keys/bot-export/emergency.sqlite

This helper only creates replacement credentials/bundles. vpn-seller owns customer
notifications, client-to-key mapping, incident decisions, and replacement delivery.

Config fingerprint:
  vpn-bot-export fingerprint /root/vpn-keys/awg/AWG-US-phone1.conf

Upload or forward a typed SQLite bundle to vpn-seller with /admin_import.
HELP
}

topic="${1:-menu}"
name="${2:-}"

case "${topic}" in
  ""|menu|--menu|--login|-h|--help|help)
    print_menu
    ;;
  1|trojan|tls|xhttp)
    topic_trojan "${name}"
    ;;
  vless|reality)
    echo "VLESS/REALITY was replaced by Trojan XHTTP TLS in this installer."
    topic_trojan "${name}"
    ;;
  2|hysteria|hy2)
    topic_hysteria "${name}"
    ;;
  3|awg|amneziawg)
    topic_awg "${name}"
    ;;
  4|sub|subs|subscription|subscriptions)
    topic_subscription
    ;;
  5|keys|files|reports)
    topic_files
    ;;
  6|awg-tools|diagnostics)
    topic_awg_tools
    ;;
  7|status|install|progress)
    topic_install_status
    ;;
  8|services|health)
    topic_services
    ;;
  9|grafana|monitoring)
    topic_grafana
    ;;
  10|decoy|urls|public)
    topic_public_urls
    ;;
  11|bot|export|bot-export|migration)
    topic_bot_export
    ;;
  *)
    print_menu >&2
    echo >&2
    echo "Unknown menu item: ${topic}" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 /usr/local/bin/vpn-help
}

install_helpers() {
  log "Installing helper commands."
  rm -f /usr/local/bin/vpn /usr/local/bin/vpn-vless /usr/local/bin/vpn-vless-xhttp /usr/local/bin/vpn-vless-reality
  install_helper_hiddify_profile
  install_helper_trojan
  install_helper_hysteria
  install_helper_awg
  install_helper_subscriptions
  install_helper_bot_export
  install_helper_cert_notify
  install_helper_help
  install_shell_startup_hook
  [[ ! -d "${KEY_DIR}/trojan" ]] || "${HIDDIFY_PROFILE_HELPER_PATH}" bulk "${KEY_DIR}/trojan" >/dev/null
  [[ ! -d "${KEY_DIR}/hysteria" ]] || "${HIDDIFY_PROFILE_HELPER_PATH}" bulk "${KEY_DIR}/hysteria" >/dev/null
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

set_ini_section_value() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  [[ -f "${file}" ]] || return 0
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v target="${section}" -v key="${key}" -v value="${value}" '
    BEGIN {in_target=0; section_seen=0; key_seen=0}
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_target && !key_seen) print key " = " value
      header=$0
      gsub(/^[[:space:]]*\[/, "", header)
      gsub(/\][[:space:]]*$/, "", header)
      in_target=(header == target)
      if (in_target) {section_seen=1; key_seen=0}
      print
      next
    }
    in_target {
      candidate=$0
      sub(/^[[:space:];#]*/, "", candidate)
      if (candidate ~ ("^" key "[[:space:]]*=")) {
        if (!key_seen) print key " = " value
        key_seen=1
        next
      }
    }
    {print}
    END {
      if (in_target && !key_seen) print key " = " value
      if (!section_seen) {
        print ""
        print "[" target "]"
        print key " = " value
      }
    }
  ' "${file}" >"${tmp}"
  cat "${tmp}" >"${file}"
  chmod 0640 "${file}"
  rm -f "${tmp}"
}

ensure_logrotate_path_maxsize() {
  local file="$1" path_pattern="$2" value="$3" tmp
  [[ -f "${file}" ]] || return 0
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v path_pattern="${path_pattern}" -v value="${value}" '
    BEGIN {in_target=0; maxsize_seen=0}
    $0 ~ path_pattern {in_target=1; maxsize_seen=0}
    in_target && /^[[:space:]]*maxsize[[:space:]]+/ {maxsize_seen=1}
    in_target && /^[[:space:]]*}[[:space:]]*$/ {
      if (!maxsize_seen) print "    maxsize " value
      in_target=0
    }
    {print}
  ' "${file}" >"${tmp}"
  install -m 0644 "${tmp}" "${file}"
  rm -f "${tmp}"
}

configure_log_limits() {
  log "Configuring log retention limits."
  install -d -m 0755 \
    /etc/systemd/journald.conf.d \
    /etc/systemd/system/logrotate.timer.d \
    "${LOG_DIR}"
  cat >/etc/systemd/journald.conf.d/limits.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=7day
Compress=yes
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
    su root root
}
EOF
  chmod 0644 /etc/logrotate.d/vpn-stack

  ensure_logrotate_path_maxsize /etc/logrotate.d/rsyslog '^[[:space:]]*/var/log/syslog([[:space:]]|$)' 50M

  cat >/etc/logrotate.d/grafana-server <<'EOF'
/var/log/grafana/grafana.log {
    daily
    rotate 3
    maxsize 20M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 grafana adm
}
EOF
  chmod 0644 /etc/logrotate.d/grafana-server

  if [[ -f /etc/grafana/grafana.ini ]]; then
    set_ini_section_value /etc/grafana/grafana.ini log.file max_lines 100000
    set_ini_section_value /etc/grafana/grafana.ini log.file max_size_shift 24
    set_ini_section_value /etc/grafana/grafana.ini log.file daily_rotation true
    set_ini_section_value /etc/grafana/grafana.ini log.file max_days 3
  fi

  cat >/etc/logrotate.d/golden-vpn-external-logs <<'EOF'
/var/log/x-ui/*.log {
    size 20M
    rotate 3
    compress
    copytruncate
    missingok
    notifempty
    su root root
}

/var/lib/docker/containers/*/*-json.log {
    size 20M
    rotate 3
    compress
    copytruncate
    missingok
    notifempty
    su root root
}
EOF
  chmod 0644 /etc/logrotate.d/golden-vpn-external-logs

  cat >/etc/systemd/system/logrotate.timer.d/golden-vpn.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true
EOF
  chmod 0644 /etc/systemd/system/logrotate.timer.d/golden-vpn.conf

  cat >/usr/local/sbin/vpn-storage-maintenance.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-size=200M --vacuum-time=7d >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true

if [[ -d /var/log/grafana ]]; then
  find /var/log/grafana -xdev -maxdepth 1 -type f \
    -name 'grafana.log.*' -mtime +3 -delete 2>/dev/null || true
fi

usage="$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
if [[ "${usage}" =~ ^[0-9]+$ ]] && ((usage >= 90)); then
  logger -p daemon.warning -t vpn-storage-maintenance \
    "root filesystem usage is ${usage}%; forcing bounded log rotation"
  journalctl --vacuum-size=100M >/dev/null 2>&1 || true
  logrotate --force /etc/logrotate.d/golden-vpn-external-logs >/dev/null 2>&1 || true
  logrotate --force /etc/logrotate.d/grafana-server >/dev/null 2>&1 || true
  logrotate /etc/logrotate.d/rsyslog >/dev/null 2>&1 || true
fi
EOF
  chmod 0755 /usr/local/sbin/vpn-storage-maintenance.sh

  cat >/etc/systemd/system/vpn-storage-maintenance.service <<'EOF'
[Unit]
Description=Golden VPN bounded log and cache maintenance
After=local-fs.target systemd-journald.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-storage-maintenance.sh
EOF
  chmod 0644 /etc/systemd/system/vpn-storage-maintenance.service

  cat >/etc/systemd/system/vpn-storage-maintenance.timer <<'EOF'
[Unit]
Description=Run Golden VPN storage maintenance hourly

[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true
Unit=vpn-storage-maintenance.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-storage-maintenance.timer

  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-size=200M --vacuum-time=7d >/dev/null 2>&1 || true
  logrotate /etc/logrotate.d/golden-vpn-external-logs >/dev/null 2>&1 || true
  logrotate /etc/logrotate.d/grafana-server >/dev/null 2>&1 || true
  logrotate /etc/logrotate.d/rsyslog >/dev/null 2>&1 || true
}

configure_timers() {
  log "Configuring boot healthcheck timers; scheduled reboots remain disabled."
  systemctl disable --now vpn-soft-reboot.timer >/dev/null 2>&1 || true
  rm -f \
    /etc/systemd/system/vpn-soft-reboot.timer \
    /etc/systemd/system/vpn-soft-reboot.service \
    /usr/local/sbin/vpn-soft-reboot.sh

  cat >/usr/local/sbin/vpn-awg-auto-update.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

lock_file="/run/vpn-engine-update.lock"
backup_root="/root/vpn-keys/awg-update-backups"
log_tag="vpn-awg-auto-update"
packages=(amneziawg amneziawg-dkms amneziawg-tools)

exec 9>"${lock_file}"
flock -n 9 || exit 0
install -d -m 0700 "${backup_root}"

log() {
  logger -t "${log_tag}" -- "$*"
  printf '[%s] %s\n' "${log_tag}" "$*"
}

prune_backups() {
  local old target
  while IFS= read -r old; do
    [[ "${old}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
    target="${backup_root}/${old}"
    [[ -d "${target}" && "${target}" == "${backup_root}/"* ]] || continue
    rm -rf -- "${target}"
  done < <(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort -r | tail -n +6)
}

installed_version() {
  dpkg-query -W -f='${Status} ${Version}\n' "$1" 2>/dev/null \
    | awk '$1 == "install" && $2 == "ok" && $3 == "installed" {print $4}'
}

candidate_version() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

reload_awg() {
  systemctl stop awg-quick@awg0.service >/dev/null 2>&1 || true
  modprobe -r amneziawg >/dev/null 2>&1 || true
  modprobe amneziawg
  systemctl start awg-quick@awg0.service
}

validate_awg() {
  awg --version 2>/dev/null | grep -Eq 'v3\.1\.' \
    && systemctl is-active --quiet awg-quick@awg0.service \
    && awg show awg0 >/dev/null 2>&1 \
    && grep -Eq '^HeaderProtectionKey[[:space:]]*=' /etc/amnezia/amneziawg/awg0.conf \
    && grep -Eq '^RandomTrailers[[:space:]]*=[[:space:]]*on$' /etc/amnezia/amneziawg/awg0.conf
}

apt-get -o DPkg::Lock::Timeout=1800 update >/dev/null
update_needed=0
for package in "${packages[@]}"; do
  installed="$(installed_version "${package}")"
  candidate="$(candidate_version "${package}")"
  [[ -n "${installed}" && -n "${candidate}" && "${candidate}" != "(none)" ]] || continue
  if dpkg --compare-versions "${candidate}" gt "${installed}"; then
    update_needed=1
  fi
done
((update_needed == 1)) || exit 0

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${backup_root}/${stamp}"
install -d -m 0700 "${backup_dir}/debs"
tar -C / -czf "${backup_dir}/profiles.tar.gz" \
  etc/amnezia/amneziawg/awg0.conf \
  opt/vpn-stack/awg-params.env \
  opt/vpn-stack/awg-tuning-report.json \
  root/vpn-keys/awg
chmod 0600 "${backup_dir}/profiles.tar.gz"

for package in "${packages[@]}"; do
  installed="$(installed_version "${package}")"
  [[ -n "${installed}" ]] || continue
  if ! (cd "${backup_dir}/debs" && apt-get download "${package}=${installed}" >/dev/null); then
    log "Update skipped: exact rollback package is unavailable for ${package}=${installed}."
    rm -rf -- "${backup_dir}"
    exit 0
  fi
done
find "${backup_dir}/debs" -maxdepth 1 -type f -name '*.deb' -exec chmod 0600 {} +
[[ "$(find "${backup_dir}/debs" -maxdepth 1 -type f -name '*.deb' | wc -l)" -ge 2 ]] \
  || { log "Update skipped: exact rollback packages could not be saved."; rm -rf -- "${backup_dir}"; exit 0; }

rollback() {
  trap - ERR
  log "AWG update failed; restoring previous packages."
  systemctl stop awg-quick@awg0.service >/dev/null 2>&1 || true
  apt-get -o DPkg::Lock::Timeout=1800 install -y --allow-downgrades \
    "${backup_dir}"/debs/*.deb >/dev/null 2>&1 || true
  reload_awg || true
}
trap rollback ERR

log "Installing an available official AWG 3.1 package update. Backup: ${backup_dir}"
apt-get -o DPkg::Lock::Timeout=1800 install -y --only-upgrade "${packages[@]}"
reload_awg
validate_awg
trap - ERR
log "AWG 3.1 package update completed successfully."
prune_backups
EOF
  chmod 0755 /usr/local/sbin/vpn-awg-auto-update.sh

  cat >/etc/systemd/system/vpn-awg-auto-update.service <<'EOF'
[Unit]
Description=Safely update official AmneziaWG 3.1 packages
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-awg-auto-update.sh
EOF
  chmod 0644 /etc/systemd/system/vpn-awg-auto-update.service

  cat >/etc/systemd/system/vpn-awg-auto-update.timer <<'EOF'
[Unit]
Description=Check daily for official AmneziaWG 3.1 patch updates

[Timer]
OnCalendar=*-*-* 02:00:00 UTC
RandomizedDelaySec=30m
Persistent=true
Unit=vpn-awg-auto-update.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-awg-auto-update.timer

  cat >/usr/local/sbin/vpn-core-auto-update.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

lock_file="/run/vpn-engine-update.lock"
backup_root="/root/vpn-keys/core-update-backups"
stack_dir="/opt/vpn-stack"
xray_config="${stack_dir}/xray/config.json"
xray_service="$(cat "${stack_dir}/trojan-xhttp-service.txt" 2>/dev/null || printf 'xray-trojan-xhttp-tls.service')"
log_tag="vpn-core-auto-update"

exec 9>"${lock_file}"
flock -n 9 || exit 0
install -d -m 0700 "${backup_root}"

log() {
  logger -t "${log_tag}" -- "$*"
  printf '[%s] %s\n' "${log_tag}" "$*"
}

prune_backups() {
  local old target
  while IFS= read -r old; do
    [[ "${old}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
    target="${backup_root}/${old}"
    [[ -d "${target}" && "${target}" == "${backup_root}/"* ]] || continue
    rm -rf -- "${target}"
  done < <(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort -r | tail -n +6)
}

xray_bin="$(command -v xray)"
hysteria_bin="$(command -v hysteria)"
[[ -x "${xray_bin}" && -x "${hysteria_bin}" ]] || { log "Xray or Hysteria binary is missing."; exit 1; }
"${xray_bin}" run -test -config "${xray_config}" >/dev/null

xray_current="v$("${xray_bin}" version 2>/dev/null | sed -n '1{s/^[^0-9]*\([0-9][0-9.]*\).*/\1/p}')"
hysteria_current="$("${hysteria_bin}" version 2>/dev/null | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p')"
[[ "${hysteria_current}" == v* ]] || hysteria_current="v${hysteria_current}"
[[ "${xray_current}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${hysteria_current}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { log "Could not parse installed Xray/Hysteria versions."; exit 1; }
xray_latest="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: Golden-VPN-updater' \
  https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name // empty')"
hysteria_latest="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: Golden-VPN-updater' \
  https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name // empty' | sed 's#^app/##')"
[[ -n "${xray_latest}" && -n "${hysteria_latest}" ]] \
  || { log "Could not determine current stable Xray/Hysteria releases."; exit 1; }
if [[ "${xray_current}" == "${xray_latest}" && "${hysteria_current}" == "${hysteria_latest}" ]]; then
  exit 0
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="${backup_root}/${stamp}"
install -d -m 0700 "${backup_dir}"
install -m 0755 "${xray_bin}" "${backup_dir}/xray"
install -m 0755 "${hysteria_bin}" "${backup_dir}/hysteria"
printf '%s\n' "${xray_bin}" >"${backup_dir}/xray-path.txt"
printf '%s\n' "${hysteria_bin}" >"${backup_dir}/hysteria-path.txt"
"${xray_bin}" version 2>/dev/null | sed -n '1p' >"${backup_dir}/xray-version.before.txt" || true
"${hysteria_bin}" version 2>/dev/null | sed -n '1p' >"${backup_dir}/hysteria-version.before.txt" || true
chmod 0600 "${backup_dir}"/*.txt

rollback() {
  trap - ERR
  log "Core update failed; restoring previous Xray and Hysteria binaries."
  install -m 0755 "${backup_dir}/xray" "${xray_bin}" || true
  install -m 0755 "${backup_dir}/hysteria" "${hysteria_bin}" || true
  systemctl restart "${xray_service}" >/dev/null 2>&1 || true
  systemctl restart hysteria2.service >/dev/null 2>&1 || true
  [[ ! -f "${stack_dir}/hysteria-profiles/config-gecko.yaml" ]] || systemctl restart hysteria2-gecko.service >/dev/null 2>&1 || true
  [[ ! -f "${stack_dir}/hysteria-profiles/config-mimic.yaml" ]] || systemctl restart hysteria2-mimic.service >/dev/null 2>&1 || true
  for service in hysteria-server.service hysteria.service hysteria@server.service; do
    systemctl disable --now "${service}" >/dev/null 2>&1 || true
  done
}
trap rollback ERR

update_dir="$(mktemp -d)"
trap 'rm -rf "${update_dir}"' EXIT
curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "${update_dir}/xray-install.sh"
curl -fsSL https://get.hy2.sh/ -o "${update_dir}/hysteria-install.sh"
chmod 0700 "${update_dir}"/*.sh

# Both official installers select their latest non-prerelease channel by default.
bash "${update_dir}/xray-install.sh" install -u root
bash "${update_dir}/hysteria-install.sh"
for service in hysteria-server.service hysteria.service hysteria@server.service; do
  systemctl disable --now "${service}" >/dev/null 2>&1 || true
done

"${xray_bin}" run -test -config "${xray_config}" >/dev/null
systemctl restart "${xray_service}"
systemctl restart hysteria2.service
if [[ -f "${stack_dir}/hysteria-profiles/config-gecko.yaml" ]]; then systemctl restart hysteria2-gecko.service; fi
if [[ -f "${stack_dir}/hysteria-profiles/config-mimic.yaml" ]]; then systemctl restart hysteria2-mimic.service; fi
systemctl is-active --quiet "${xray_service}"
systemctl is-active --quiet hysteria2.service
if [[ -f "${stack_dir}/hysteria-profiles/config-gecko.yaml" ]]; then systemctl is-active --quiet hysteria2-gecko.service; fi
if [[ -f "${stack_dir}/hysteria-profiles/config-mimic.yaml" ]]; then systemctl is-active --quiet hysteria2-mimic.service; fi
test -S /dev/shm/xray-trojan-xhttp.sock
ss -H -lun | awk '$4 ~ /:8443$/ {found=1} END {exit found ? 0 : 1}'
if [[ -s "${stack_dir}/hysteria-gecko-port.txt" ]]; then
  gecko_port="$(<"${stack_dir}/hysteria-gecko-port.txt")"
  ss -H -lun | awk -v port=":${gecko_port}" '$4 ~ (port "$") {found=1} END {exit found ? 0 : 1}'
fi
if [[ -f "${stack_dir}/hysteria-profiles/config-mimic.yaml" ]]; then
  mimic_port="$(<"${stack_dir}/hysteria-mimic-port.txt")"
  ss -H -lun | awk -v port=":${mimic_port}" '$4 ~ (port "$") {found=1} END {exit found ? 0 : 1}'
fi

trap - ERR
"${xray_bin}" version 2>/dev/null | sed -n '1p' >"${backup_dir}/xray-version.after.txt" || true
"${hysteria_bin}" version 2>/dev/null | sed -n '1p' >"${backup_dir}/hysteria-version.after.txt" || true
chmod 0600 "${backup_dir}"/*.txt
log "Stable Xray and Hysteria update check completed successfully. Backup: ${backup_dir}"
prune_backups
EOF
  chmod 0755 /usr/local/sbin/vpn-core-auto-update.sh

  cat >/etc/systemd/system/vpn-core-auto-update.service <<'EOF'
[Unit]
Description=Safely update stable Xray and Hysteria releases
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-core-auto-update.sh
EOF
  chmod 0644 /etc/systemd/system/vpn-core-auto-update.service

  cat >/etc/systemd/system/vpn-core-auto-update.timer <<'EOF'
[Unit]
Description=Check daily for stable Xray and Hysteria updates

[Timer]
OnCalendar=*-*-* 03:00:00 UTC
RandomizedDelaySec=45m
Persistent=true
Unit=vpn-core-auto-update.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-core-auto-update.timer

  cat >/usr/local/sbin/vpn-stack-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file="/var/log/vpn-stack-healthcheck.log"
services=(
  nginx
  xray-trojan-xhttp-tls
  xray-vless-xhttp-tls
  xray-vless-reality-xhttp
  hysteria2
  hysteria2-gecko
  hysteria2-mimic
  prometheus
  prometheus-node-exporter
  grafana-server
  amneziawg-ensure-module
  awg-quick@awg0
)

printf '%s healthcheck start\n' "$(date -Is)" >>"${log_file}"
for svc in "${services[@]}"; do
  systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
  if [[ "${svc}" == hysteria2-mimic && ! -f /opt/vpn-stack/hysteria-profiles/config-mimic.yaml ]]; then
    continue
  fi
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

  cat >/etc/systemd/system/vpn-cert-notify.service <<'EOF'
[Unit]
Description=Golden VPN TLS certificate expiry notification
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-cert-notify check
EOF
  chmod 0644 /etc/systemd/system/vpn-cert-notify.service

  cat >/etc/systemd/system/vpn-cert-notify.timer <<'EOF'
[Unit]
Description=Check Golden VPN TLS certificate daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
Unit=vpn-cert-notify.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 /etc/systemd/system/vpn-cert-notify.timer
}

enable_and_start_services() {
  log "Enabling and starting services."
  systemctl daemon-reload

  systemctl enable nginx
  systemctl enable xray-trojan-xhttp-tls
  systemctl enable hysteria2
  systemctl enable hysteria2-gecko
  if [[ -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]]; then systemctl enable hysteria2-mimic; fi
  systemctl enable amneziawg-ensure-module
  systemctl enable awg-quick@awg0
  systemctl enable prometheus
  systemctl enable prometheus-node-exporter
  systemctl enable grafana-server
  systemctl enable logrotate.timer
  systemctl enable vpn-storage-maintenance.timer
  systemctl enable vpn-awg-auto-update.timer
  systemctl enable vpn-core-auto-update.timer
  systemctl enable vpn-stack-healthcheck.timer
  systemctl enable vpn-cert-notify.timer

  systemctl restart systemd-journald || true
  systemctl restart xray-trojan-xhttp-tls
  systemctl restart nginx
  systemctl restart hysteria2
  systemctl restart hysteria2-gecko
  if [[ -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]]; then systemctl restart hysteria2-mimic; fi
  systemctl restart amneziawg-ensure-module
  systemctl restart awg-quick@awg0
  systemctl restart prometheus
  systemctl restart prometheus-node-exporter
  systemctl restart grafana-server
  systemctl restart logrotate.timer
  systemctl restart vpn-storage-maintenance.timer
  systemctl restart vpn-awg-auto-update.timer
  systemctl restart vpn-core-auto-update.timer
  systemctl restart vpn-stack-healthcheck.timer
  systemctl restart vpn-cert-notify.timer
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

current_awg_listen_port() {
  local port
  port="$(awk -F= 'tolower($1) ~ /^[[:space:]]*listenport[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${AWG_CONFIG}" 2>/dev/null || true)"
  [[ "${port}" =~ ^[0-9]+$ ]] || port="${AWG_INTERNAL_LISTEN_PORT}"
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

installed_trojan_xray_service() {
  local service
  service="$(cat "${STACK_DIR}/trojan-xhttp-service.txt" 2>/dev/null || true)"
  [[ -n "${service}" ]] || service="xray-trojan-xhttp-tls.service"
  printf '%s\n' "${service}"
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
  local awg_port gecko_port mimic_port
  local -a missing
  awg_port="$(current_awg_listen_port)"
  gecko_port="$(cat "${STACK_DIR}/hysteria-gecko-port.txt" 2>/dev/null || true)"
  mimic_port="$(cat "${STACK_DIR}/hysteria-mimic-port.txt" 2>/dev/null || true)"

  log "Waiting up to ${timeout}s for expected listening ports."
  while true; do
    missing=()

    listen_any_port tcp 443 || missing+=("443/tcp")
    listen_any_port udp 8443 || missing+=("8443/udp")
    [[ -z "${gecko_port}" ]] || listen_any_port udp "${gecko_port}" || missing+=("${gecko_port}/udp Gecko")
    if [[ -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]]; then
      listen_any_port udp "${mimic_port}" || missing+=("${mimic_port}/udp Mimic")
    fi
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
  local dashboard_status awg_port awg_listen_port awg_profile awg_effective awg_mtu decoy_profile decoy_seed cert_issuer cert_expiry swap_result xray_service gecko_port mimic_port gecko_status mimic_status
  load_installed_context
  xray_service="$(installed_trojan_xray_service)"
  awg_port="$(current_awg_port)"
  awg_listen_port="$(current_awg_listen_port)"
  gecko_port="$(cat "${STACK_DIR}/hysteria-gecko-port.txt" 2>/dev/null || printf unavailable)"
  mimic_port="$(cat "${STACK_DIR}/hysteria-mimic-port.txt" 2>/dev/null || printf unavailable)"
  if [[ "${gecko_port}" =~ ^[0-9]+$ ]]; then
    gecko_status="$(listen_label any udp "${gecko_port}")"
  else
    gecko_status="unavailable"
  fi
  if [[ -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" && "${mimic_port}" =~ ^[0-9]+$ ]]; then
    mimic_status="enabled; listener $(listen_label any udp "${mimic_port}")"
  else
    mimic_status="unavailable"
  fi
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
  AmneziaWG 3.1 (№1)  : service $(service_summary awg-quick@awg0); external ${awg_port}/udp via protected redirect; internal ${awg_listen_port}/udp $(listen_label any udp "${awg_listen_port}"); interface awg0
  Hysteria2 (№2)      : Salamander 8443/udp $(listen_label any udp 8443); Gecko ${gecko_port}/udp ${gecko_status}
  Hysteria2 Mimic     : service $(service_summary hysteria2-mimic); ${mimic_port}/udp+fake-tcp; Linux-only ${mimic_status}
  Trojan TLS fallback : service $(service_summary "${xray_service}"); external 443/tcp via nginx $(listen_label any tcp 443); backend ${TROJAN_XHTTP_SOCKET} $(socket_label "${TROJAN_XHTTP_SOCKET}")
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

Engine updates:
  AWG 3.1 stable patches: vpn-awg-auto-update.timer (daily, rollback protected)
  Xray/Hysteria stable: vpn-core-auto-update.timer (daily, binary rollback protected)
  Scheduled server reboot: disabled

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
  VPN logs: /etc/logrotate.d/vpn-stack
  Docker/x-ui logs: /etc/logrotate.d/golden-vpn-external-logs
  Grafana logs: native 16MB rotation / 3 days plus logrotate fallback
  Maintenance: vpn-storage-maintenance.timer
  Logrotate schedule: hourly
  Prometheus retention: 7d / 1GB

Initial client files:
  ${KEY_DIR}/trojan/TROJAN-${SERVER_LOCATION}-main-trojan.txt
  ${KEY_DIR}/hysteria/HYSTERIA-${SERVER_LOCATION}-main-hysteria-client.txt
  ${KEY_DIR}/awg/AWG-${SERVER_LOCATION}-main-awg.conf

Create more clients:
  vpn-trojan phone1
  vpn-hysteria phone1
  vpn-hysteria phone1 gecko
  vpn-hysteria phone1 mimic
  vpn-awg phone1

Subscription bundles:
  Create: vpn-sub create phone1
  Show: vpn-sub show phone1
  Browser/import URL shape: https://${DOMAIN}/s/<token>
  Hiddify JSON: https://${DOMAIN}/s/<token>/hiddify.json
  Plain payload: https://${DOMAIN}/s/<token>/sub.txt
  AmneziaWG download: https://${DOMAIN}/s/<token>/awg.conf
  Metadata root: ${SUBSCRIPTION_DIR}
  Public root: ${SUBSCRIPTION_WEB_DIR}

Bot export for vpn-seller:
  Audit: vpn-bot-export audit --out ${KEY_DIR}/bot-export/server-audit.json
  Active typed keys: vpn-bot-export inventory --type all --plan plan_30 --out ${KEY_DIR}/bot-export/active-keys.sqlite --send
  Typed stock: vpn-bot-export batch --type awg --count 20 --prefix stock --plan plan_30 --send
  Emergency: vpn-bot-export emergency --map /root/vpn-migration/map.csv --out ${KEY_DIR}/bot-export/emergency.sqlite
  TLS notifications: vpn-cert-notify.timer
  Output root: ${KEY_DIR}/bot-export

  vpn-help

Install reports:
  ${INSTALL_REPORT_TXT}
  ${INSTALL_REPORT_JSON}
============================================================
EOF
}

generate_install_report() {
  local awg_port awg_listen_port awg_profile awg_effective awg_mtu decoy_profile decoy_seed cert_issuer cert_expiry swap_active dashboard_status swap_result xray_service gecko_port mimic_port
  load_installed_context
  xray_service="$(installed_trojan_xray_service)"
  awg_port="$(current_awg_port)"
  awg_listen_port="$(current_awg_listen_port)"
  gecko_port="$(cat "${STACK_DIR}/hysteria-gecko-port.txt" 2>/dev/null || printf unavailable)"
  mimic_port="$(cat "${STACK_DIR}/hysteria-mimic-port.txt" 2>/dev/null || printf unavailable)"
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
      "priority": 3,
      "external": "443/tcp",
      "service": $(json_escape "$(service_summary "${xray_service}")"),
      "backend_socket": $(json_escape "${TROJAN_XHTTP_SOCKET}")
    },
    "hysteria2_salamander": {
      "priority": 2,
      "external": "8443/udp",
      "service": $(json_escape "$(service_summary hysteria2)")
    },
    "hysteria2_gecko": {
      "priority": 2,
      "external": $(json_escape "${gecko_port}/udp"),
      "service": $(json_escape "$(service_summary hysteria2-gecko)"),
      "experimental": true
    },
    "hysteria2_mimic": {
      "priority": 2,
      "external": $(json_escape "${mimic_port}/udp+fake-tcp"),
      "service": $(json_escape "$(service_summary hysteria2-mimic)"),
      "linux_client_only": true
    },
    "amneziawg": {
      "priority": 1,
      "protocol_version": "3.1",
      "external": $(json_escape "${awg_port}/udp"),
      "internal_listener": $(json_escape "${awg_listen_port}/udp"),
      "gateway": "local-destination-only REDIRECT",
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
    "hiddify_json": $(json_escape "${KEY_DIR}/hiddify-json"),
    "awg": $(json_escape "${KEY_DIR}/awg")
  },
  "subscriptions": {
    "helper": "vpn-sub",
    "metadata_root": $(json_escape "${SUBSCRIPTION_DIR}"),
    "public_root": $(json_escape "${SUBSCRIPTION_WEB_DIR}"),
    "url_shape": $(json_escape "https://${DOMAIN:-DOMAIN}/s/<token>"),
    "payload": "hiddify.json is a Hiddify/Sing-box profile; sub.txt contains Trojan and Hysteria2 links; awg.conf is downloadable separately",
    "token_policy": "unguessable per-subscription tokens are never included in install reports"
  },
  "engine_updates": {
    "awg31_timer": "vpn-awg-auto-update.timer",
    "xray_hysteria_timer": "vpn-core-auto-update.timer",
    "channel": "stable",
    "rollback": true,
    "scheduled_reboot": false
  },
  "bot_export": {
    "helper": "vpn-bot-export",
    "output_root": $(json_escape "${KEY_DIR}/bot-export"),
    "stock_bundle": $(json_escape "${KEY_DIR}/bot-export/keys.sqlite"),
    "emergency_bundle": $(json_escape "${KEY_DIR}/bot-export/emergency.sqlite"),
    "audit_json": $(json_escape "${KEY_DIR}/bot-export/server-audit.json"),
    "bot_contract": "vpn-seller typed AWG/Trojan/Hysteria SQLite v1; reports never include client config bodies"
  }
}
EOF
  chmod 0600 "${INSTALL_REPORT_JSON}"
  log "Install reports saved: ${INSTALL_REPORT_TXT}, ${INSTALL_REPORT_JSON}"
}

validate_stack() {
  local failed=0 awg_port awg_listen_port xray_service gecko_port mimic_port
  load_installed_context
  awg_port="$(current_awg_port)"
  awg_listen_port="$(current_awg_listen_port)"
  xray_service="$(installed_trojan_xray_service)"
  gecko_port="$(cat "${STACK_DIR}/hysteria-gecko-port.txt" 2>/dev/null || true)"
  mimic_port="$(cat "${STACK_DIR}/hysteria-mimic-port.txt" 2>/dev/null || true)"

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
  if [[ -n "${gecko_port}" ]]; then
    check_pass "${gecko_port}/udp Gecko listener" listen_any_port udp "${gecko_port}"
  fi
  check_pass "${awg_listen_port}/udp AWG internal listener" listen_any_port udp "${awg_listen_port}"
  if [[ "${awg_port}" == 443 && "${awg_listen_port}" == "${AWG_INTERNAL_LISTEN_PORT}" ]]; then
    check_pass "443/udp AWG local-destination redirect" iptables -t nat -C PREROUTING -p udp --dport 443 -m addrtype --dst-type LOCAL -j REDIRECT --to-ports "${AWG_INTERNAL_LISTEN_PORT}"
    check_pass "AWG post-redirect UFW acceptance" iptables -C ufw-before-input -p udp --dport "${AWG_INTERNAL_LISTEN_PORT}" -m conntrack --ctorigdstport 443 -j ACCEPT
    check_absent "direct ${AWG_INTERNAL_LISTEN_PORT}/udp UFW exposure absent" bash -c "ufw status | grep -Eq '^${AWG_INTERNAL_LISTEN_PORT}/udp[[:space:]]+ALLOW'"
  fi
  check_pass "Trojan XHTTP unix socket" test -S "${TROJAN_XHTTP_SOCKET}"
  check_pass "Grafana localhost 3000" listen_local_port tcp 3000
  check_pass "Prometheus localhost 9090" listen_local_port tcp 9090
  check_pass "Node Exporter localhost 9100" listen_local_port tcp 9100
  check_absent "Grafana not public" listen_nonlocal_port tcp 3000
  check_absent "Prometheus not public" listen_nonlocal_port tcp 9090
  check_absent "Node Exporter not public" listen_nonlocal_port tcp 9100
  check_pass "nginx active" systemctl is-active --quiet nginx
  check_pass "Trojan-capable Xray active (${xray_service})" systemctl is-active --quiet "${xray_service}"
  check_pass "hysteria2 active" systemctl is-active --quiet hysteria2
  if [[ -s "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml" ]]; then
    check_pass "hysteria2-gecko active" systemctl is-active --quiet hysteria2-gecko
  fi
  if [[ -s "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]]; then
    check_pass "hysteria2-mimic active" systemctl is-active --quiet hysteria2-mimic
    check_pass "${mimic_port}/udp Mimic listener" listen_any_port udp "${mimic_port}"
    # shellcheck disable=SC2016
    check_pass "Mimic kernel module loaded" bash -c 'lsmod | awk '\''$1 == "mimic" {found=1} END {exit found ? 0 : 1}'\'''
  fi
  check_pass "awg-quick@awg0 active" systemctl is-active --quiet awg-quick@awg0
  check_pass "AmneziaWG 3.1 tools" bash -c 'awg --version 2>/dev/null | grep -Eq '\''v3\.1\.'\'''
  check_pass "AWG 3.1 header protection configured" grep -Eq '^HeaderProtectionKey[[:space:]]*=' "${AWG_CONFIG}"
  check_pass "AWG 3.1 content padding configured" grep -Eq '^ContentPaddingAddition[[:space:]]*=' "${AWG_CONFIG}"
  check_pass "AWG 3.1 random trailers configured" grep -Eq '^RandomTrailers[[:space:]]*=[[:space:]]*on$' "${AWG_CONFIG}"
  check_pass "prometheus active" systemctl is-active --quiet prometheus
  check_pass "node exporter active" systemctl is-active --quiet prometheus-node-exporter
  check_pass "grafana active" systemctl is-active --quiet grafana-server
  check_pass "hourly logrotate timer active" systemctl is-active --quiet logrotate.timer
  check_pass "storage maintenance timer active" systemctl is-active --quiet vpn-storage-maintenance.timer
  check_pass "AWG stable update timer active" systemctl is-active --quiet vpn-awg-auto-update.timer
  check_pass "Xray/Hysteria stable update timer active" systemctl is-active --quiet vpn-core-auto-update.timer
  check_absent "scheduled reboot timer absent" systemctl is-enabled --quiet vpn-soft-reboot.timer
  check_pass "journald capped at 200M" grep -Eq '^SystemMaxUse=200M$' /etc/systemd/journald.conf.d/limits.conf
  check_pass "logrotate configuration valid" logrotate --debug /etc/logrotate.conf
  # shellcheck disable=SC2016
  check_pass "root filesystem usage below 95%" bash -c 'usage=$(df -P / | awk '\''NR == 2 {gsub(/%/, "", $5); print $5}'\''); [[ "$usage" =~ ^[0-9]+$ ]] && ((usage < 95))'
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
  local awg_port awg_listen_port xray_service gecko_port mimic_port port_pattern
  awg_port="$(current_awg_port)"
  awg_listen_port="$(current_awg_listen_port)"
  xray_service="$(installed_trojan_xray_service)"
  gecko_port="$(cat "${STACK_DIR}/hysteria-gecko-port.txt" 2>/dev/null || true)"
  mimic_port="$(cat "${STACK_DIR}/hysteria-mimic-port.txt" 2>/dev/null || true)"
  port_pattern=":443|:8443|:${awg_port}|:${awg_listen_port}|:3000|:9090|:9100"
  [[ -z "${gecko_port}" ]] || port_pattern+="|:${gecko_port}"
  [[ ! -s "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" || -z "${mimic_port}" ]] || port_pattern+="|:${mimic_port}"
  log "Final listening socket check."
  set +e
  ss -lntup | grep -E "${port_pattern}"
  ls -l "${TROJAN_XHTTP_SOCKET}"

  systemctl status nginx --no-pager
  systemctl status "${xray_service}" --no-pager
  systemctl status hysteria2 --no-pager
  systemctl status hysteria2-gecko --no-pager
  [[ ! -s "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]] || systemctl status hysteria2-mimic --no-pager
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
  require_install_storage "${BOOTSTRAP_MIN_FREE_MB}" "Bootstrap"
  cleanup_resume_install_state

  progress "Collecting installer variables"
  export VPN_STACK_IGNORE_SAVED_ENV=1
  require_root_and_env
  prompt_advanced_tuning
  install_resume_status_helper
  enable_compact_install_ui reset

  progress "Installing bootstrap packages"
  install_bootstrap_packages

  progress "Preparing SSH and firewall access"
  install_resume_status_helper
  install_shell_startup_hook
  ensure_ssh_firewall_access require-listener || die "SSH listener check failed before reboot. Start openssh-server manually, then rerun bootstrap."

  progress "Scheduling one-shot stage2 install"
  export VPN_STACK_NO_AUTO_REBOOT=1
  schedule_resume_install_once

  progress "Rebooting into stage2"
  log "The installer will continue once after reboot."
  log "After SSH login, /root/.bashrc shows installer progress automatically."
  log "Manual watcher remains available: vpn-install-status watch"
  systemctl reboot
  exit 0
}

detect_installed_xray_protocol() {
  local config="${XRAY_DIR}/config.json"

  if [[ -s "${config}" ]] && jq -e . "${config}" >/dev/null 2>&1; then
    if jq -e '[.inbounds[]?.protocol] | index("trojan") != null' "${config}" >/dev/null; then
      printf 'trojan\n'
      return 0
    fi
    if jq -e '[.inbounds[]?.protocol] | index("vless") != null' "${config}" >/dev/null; then
      printf 'vless\n'
      return 0
    fi
  fi

  printf 'unknown\n'
}

upgrade_profile_roots() {
  local path
  local -a candidates=(
    "${XRAY_DIR}"
    "${STACK_DIR}/trojan-xhttp-password.txt"
    "${STACK_DIR}/trojan-xhttp-path.txt"
    "${STACK_DIR}/trojan-xhttp-socket.txt"
    "${STACK_DIR}/trojan-xhttp-service.txt"
    "${STACK_DIR}/vless-xhttp-uuid.txt"
    "${STACK_DIR}/vless-xhttp-path.txt"
    "${STACK_DIR}/vless-reality-uuid.txt"
    "${STACK_DIR}/vless-reality-path.txt"
    "${HYSTERIA_DIR}"
    "${STACK_DIR}/hysteria-clients.json"
    "${STACK_DIR}/hysteria-auth.txt"
    "${STACK_DIR}/hysteria-obfs.txt"
    "${AWG_CONFIG}"
    "${KEY_DIR}/trojan"
    "${KEY_DIR}/vless"
    "${KEY_DIR}/vless-xhttp"
    "${KEY_DIR}/vless-reality"
    "${KEY_DIR}/hysteria"
    "${KEY_DIR}/awg"
    "${SUBSCRIPTION_DIR}"
    "${SUBSCRIPTION_WEB_DIR}"
  )

  for path in "${candidates[@]}"; do
    [[ -e "${path}" ]] || continue
    printf '%s\n' "${path#/}"
  done
}

write_upgrade_profile_manifest() {
  local output="$1" tmp file sum peer_count
  tmp="$(mktemp "${output}.XXXXXX")"

  {
    printf 'manifest_version\t1\n'
    printf 'xray_protocol\t%s\n' "$(detect_installed_xray_protocol)"

    if [[ -s "${XRAY_DIR}/config.json" ]]; then
      jq -r '
        .inbounds[]? as $inbound
        | ($inbound.settings.clients // [])[]
        | ["xray_client", ($inbound.protocol // "unknown"), (.email // "(unlabelled)")]
        | @tsv
      ' "${XRAY_DIR}/config.json" 2>/dev/null | LC_ALL=C sort
    fi

    if [[ -s "${STACK_DIR}/hysteria-clients.json" ]]; then
      jq -r '
        if type == "object" then
          keys[] | ["hysteria_client", .] | @tsv
        else empty end
      ' "${STACK_DIR}/hysteria-clients.json" 2>/dev/null | LC_ALL=C sort
    fi

    if [[ -s "${AWG_CONFIG}" ]]; then
      peer_count="$(grep -Ec '^[[:space:]]*\[Peer\][[:space:]]*$' "${AWG_CONFIG}" || true)"
      printf 'awg_peer_count\t%s\n' "${peer_count:-0}"
    else
      printf 'awg_peer_count\t0\n'
    fi

    while IFS= read -r -d '' file; do
      sum="$(sha256sum -- "${file}" | awk '{print $1}')"
      printf 'file\t%s\t%s\n' "${file#/}" "${sum}"
    done < <(
      while IFS= read -r root; do
        if [[ -d "/${root}" ]]; then
          find "/${root}" -xdev -type f -print0
        elif [[ -f "/${root}" ]]; then
          printf '%s\0' "/${root}"
        fi
      done < <(upgrade_profile_roots) | LC_ALL=C sort -z
    )
  } >"${tmp}"

  install -m 0600 "${tmp}" "${output}"
  rm -f "${tmp}"
}

manifest_record_count() {
  local manifest="$1" record="$2"
  awk -F '\t' -v record="${record}" '$1 == record {count++} END {print count + 0}' "${manifest}"
}

create_upgrade_backup() {
  local stamp backup_dir roots_file archive
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "${UPGRADE_BACKUP_ROOT}"
  backup_dir="$(mktemp -d "${UPGRADE_BACKUP_ROOT}/${stamp}.XXXXXX")"
  chmod 0700 "${backup_dir}"
  roots_file="${backup_dir}/profile-roots.txt"
  archive="${backup_dir}/profiles.tar"

  upgrade_profile_roots >"${roots_file}"
  chmod 0600 "${roots_file}"
  [[ -s "${roots_file}" ]] || die "No existing Golden VPN profile paths were found to back up."

  tar -C / -cpf "${archive}" -T "${roots_file}"
  tar -tf "${archive}" >/dev/null
  sha256sum "${archive}" >"${archive}.sha256"
  chmod 0600 "${archive}" "${archive}.sha256"
  write_upgrade_profile_manifest "${backup_dir}/profiles.before.tsv"

  printf '%s\n' "${backup_dir}"
}

upgrade_preflight() {
  local protocol free_mb
  [[ "${EUID}" -eq 0 ]] || die "Run upgrade as root."
  [[ -d "${STACK_DIR}" ]] || die "${STACK_DIR} does not exist; use install for a clean server."
  need_command jq
  need_command tar
  need_command sha256sum
  load_installed_context

  if [[ "${SERVER_LOCATION}" == "XX" ]]; then
    if have_tty; then
      unset SERVER_LOCATION
      ensure_valid_server_location
    else
      die "SERVER_LOCATION is unknown. Export the two-letter location before upgrade, for example SERVER_LOCATION=FR."
    fi
  fi
  [[ -n "${DOMAIN:-}" ]] || die "Installed DOMAIN could not be determined. Export DOMAIN before upgrade."

  protocol="$(detect_installed_xray_protocol)"
  [[ "${protocol}" != "unknown" ]] || die "Existing Xray protocol could not be identified safely."
  [[ -s "${STACK_DIR}/hysteria-clients.json" ]] || die "Hysteria client registry is missing."
  jq -e 'type == "object"' "${STACK_DIR}/hysteria-clients.json" >/dev/null \
    || die "Hysteria client registry is not a JSON object."
  [[ -s "${AWG_CONFIG}" ]] || die "AmneziaWG server config is missing."

  free_mb="$(root_free_mb)"
  [[ "${free_mb}" =~ ^[0-9]+$ ]] || die "Could not determine free disk space."
  ((free_mb >= UPGRADE_MIN_FREE_MB)) \
    || die "Upgrade requires at least ${UPGRADE_MIN_FREE_MB} MB free on /."

  log "Upgrade preflight passed: protocol=${protocol}, domain=${DOMAIN:-unknown}, location=${SERVER_LOCATION}."
  if [[ "${protocol}" == "vless" ]]; then
    warn "Legacy VLESS detected. Upgrade will preserve it and will not install Trojan/subscription helpers."
  fi
}

install_upgrade_helpers() {
  local protocol
  protocol="$(detect_installed_xray_protocol)"
  log "Installing profile-preserving helper updates."

  install_helper_hiddify_profile
  [[ -s "${AWG_CONFIG}" ]] && install_helper_awg
  if [[ -s "${STACK_DIR}/hysteria-clients.json" ]]; then
    install_helper_hysteria
  fi
  install_helper_bot_export
  install_helper_cert_notify

  if [[ "${protocol}" == "trojan" ]]; then
    install_helper_trojan
    install_helper_subscriptions
    install_helper_help
  else
    warn "Keeping existing VLESS and vpn-help commands unchanged on this legacy server."
  fi

  install_shell_startup_hook
  install_resume_status_helper
  [[ ! -d "${KEY_DIR}/trojan" ]] || "${HIDDIFY_PROFILE_HELPER_PATH}" bulk "${KEY_DIR}/trojan" >/dev/null
  [[ ! -d "${KEY_DIR}/hysteria" ]] || "${HIDDIFY_PROFILE_HELPER_PATH}" bulk "${KEY_DIR}/hysteria" >/dev/null
}

upgrade_hysteria_profiles() {
  local backup_dir="$1" hysteria_bin gecko_port mimic_port state_roots state_archive path
  local -a profile_state_paths=(
    "${HYSTERIA_PROFILE_DIR}"
    "${STACK_DIR}/hysteria-obfs-gecko.txt"
    "${STACK_DIR}/hysteria-obfs-mimic.txt"
    "${STACK_DIR}/hysteria-gecko-port.txt"
    "${STACK_DIR}/hysteria-mimic-port.txt"
    "${STACK_DIR}/hysteria-mimic-available.txt"
    "/etc/systemd/system/hysteria2-gecko.service"
    "/etc/systemd/system/hysteria2-mimic.service"
  )
  hysteria_bin="$(command -v hysteria)"
  [[ -x "${hysteria_bin}" ]] || die "Installed Hysteria binary is missing."
  install -m 0755 "${hysteria_bin}" "${backup_dir}/hysteria-binary.before"
  state_roots="${backup_dir}/hysteria-profile-state.roots"
  state_archive="${backup_dir}/hysteria-profile-state.tar"
  : >"${state_roots}"
  for path in "${profile_state_paths[@]}"; do
    [[ ! -e "${path}" ]] || printf '%s\n' "${path#/}" >>"${state_roots}"
  done
  if [[ -s "${state_roots}" ]]; then
    tar -C / -cpf "${state_archive}" -T "${state_roots}"
    chmod 0600 "${state_roots}" "${state_archive}"
  else
    chmod 0600 "${state_roots}"
  fi

  if ! (
    set -Eeuo pipefail
    install_hysteria
    install_mimic_optional
    ensure_hysteria_profile_state
    hysteria_render_profile_config gecko "${HYSTERIA_PROFILE_DIR}/config-gecko.yaml"
    if [[ "$(<"${STACK_DIR}/hysteria-mimic-available.txt")" == 1 ]]; then
      hysteria_render_profile_config mimic "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
    else
      rm -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml"
    fi
    write_hysteria_additional_units
    gecko_port="$(<"${STACK_DIR}/hysteria-gecko-port.txt")"
    ufw allow "${gecko_port}/udp"
    if [[ -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]]; then
      mimic_port="$(<"${STACK_DIR}/hysteria-mimic-port.txt")"
      ufw allow "${mimic_port}/udp"
      ufw allow "${mimic_port}/tcp"
    fi
    systemctl daemon-reload
    systemctl enable --now hysteria2.service hysteria2-gecko.service
    if [[ -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]]; then
      systemctl enable --now hysteria2-mimic.service
    fi
    systemctl restart hysteria2.service hysteria2-gecko.service
    systemctl is-active --quiet hysteria2.service
    systemctl is-active --quiet hysteria2-gecko.service
    ss -H -lun | awk -v port=":${gecko_port}" '$4 ~ (port "$") {found=1} END {exit found ? 0 : 1}'
    if [[ -f "${HYSTERIA_PROFILE_DIR}/config-mimic.yaml" ]]; then
      systemctl restart hysteria2-mimic.service
      systemctl is-active --quiet hysteria2-mimic.service
      ss -H -lun | awk -v port=":${mimic_port}" '$4 ~ (port "$") {found=1} END {exit found ? 0 : 1}'
    fi
  ); then
    return 0
  fi

  warn "Hysteria profile upgrade failed; restoring the previous Hysteria binary and Salamander service."
  install -m 0755 "${backup_dir}/hysteria-binary.before" "${hysteria_bin}" || true
  systemctl disable --now hysteria2-gecko.service hysteria2-mimic.service >/dev/null 2>&1 || true
  rm -rf -- "${HYSTERIA_PROFILE_DIR}"
  rm -f -- \
    "${STACK_DIR}/hysteria-obfs-gecko.txt" \
    "${STACK_DIR}/hysteria-obfs-mimic.txt" \
    "${STACK_DIR}/hysteria-gecko-port.txt" \
    "${STACK_DIR}/hysteria-mimic-port.txt" \
    "${STACK_DIR}/hysteria-mimic-available.txt" \
    /etc/systemd/system/hysteria2-gecko.service \
    /etc/systemd/system/hysteria2-mimic.service
  if [[ -s "${state_roots}" && -s "${state_archive}" ]]; then
    tar -C / -xpf "${state_archive}"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart hysteria2.service >/dev/null 2>&1 || true
  die "Hysteria profile upgrade rolled back. Existing users and Salamander files were preserved."
}

apply_upgrade_overlay() {
  local backup_dir="$1"
  configure_udp_buffers
  upgrade_hysteria_profiles "${backup_dir}"
  install_upgrade_helpers

  if [[ "$(current_awg_port)" == 443 && "$(current_awg_listen_port)" == "${AWG_INTERNAL_LISTEN_PORT}" ]]; then
    configure_awg_udp443_gateway
    ufw allow 443/udp
    ufw --force delete allow "${AWG_INTERNAL_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
    ufw reload
    activate_awg_udp443_gateway
  fi

  if [[ -d /etc/prometheus && -d /etc/grafana ]]; then
    configure_monitoring
  else
    warn "Monitoring packages are incomplete; monitoring configuration was skipped."
  fi

  configure_log_limits
  configure_timers
  systemctl daemon-reload
  systemctl restart systemd-journald || true
  systemctl enable --now logrotate.timer vpn-storage-maintenance.timer
  systemctl disable --now vpn-soft-reboot.timer >/dev/null 2>&1 || true
  systemctl enable --now vpn-stack-healthcheck.timer vpn-core-auto-update.timer
  if grep -Eq '^HeaderProtectionKey[[:space:]]*=' "${AWG_CONFIG}" \
    && grep -Eq '^RandomTrailers[[:space:]]*=[[:space:]]*on$' "${AWG_CONFIG}"; then
    systemctl enable --now vpn-awg-auto-update.timer
  else
    systemctl disable --now vpn-awg-auto-update.timer >/dev/null 2>&1 || true
    warn "AWG auto-update remains disabled because the existing contour is not a validated AWG 3.1 profile."
  fi
  systemctl enable --now vpn-cert-notify.timer

  if systemctl cat prometheus.service >/dev/null 2>&1; then
    systemctl enable prometheus.service
    systemctl restart prometheus.service
  fi
  if systemctl cat prometheus-node-exporter.service >/dev/null 2>&1; then
    systemctl enable prometheus-node-exporter.service
    systemctl restart prometheus-node-exporter.service
  fi
  if systemctl cat grafana-server.service >/dev/null 2>&1; then
    systemctl enable grafana-server.service
    systemctl restart grafana-server.service
  fi

  wait_for_expected_listeners 180
}

write_upgrade_report() {
  local backup_dir="$1" before="$2" after="$3" protocol
  protocol="$(detect_installed_xray_protocol)"
  install -d -m 0700 "${KEY_DIR}"
  cat >"${UPGRADE_REPORT}" <<EOF
{
  "version": $(json_escape "${GOLDEN_VPN_VERSION}"),
  "upgraded_at": $(json_escape "$(date -Is)"),
  "xray_protocol": $(json_escape "${protocol}"),
  "profiles_preserved": true,
  "backup_dir": $(json_escape "${backup_dir}"),
  "counts": {
    "xray": $(manifest_record_count "${before}" xray_client),
    "hysteria": $(manifest_record_count "${before}" hysteria_client),
    "awg": $(awk -F '\t' '$1 == "awg_peer_count" {print $2}' "${before}")
  },
  "before_manifest_sha256": $(json_escape "$(sha256sum "${before}" | awk '{print $1}')"),
  "after_manifest_sha256": $(json_escape "$(sha256sum "${after}" | awk '{print $1}')")
}
EOF
  chmod 0600 "${UPGRADE_REPORT}"
}

upgrade_existing_stack() {
  local backup_dir before after
  upgrade_preflight
  backup_dir="$(create_upgrade_backup)"
  before="${backup_dir}/profiles.before.tsv"
  after="${backup_dir}/profiles.after.tsv"
  log "Profile backup created: ${backup_dir}"

  if ! (set -Eeuo pipefail; apply_upgrade_overlay "${backup_dir}"); then
    die "Upgrade overlay failed. VPN credentials were not intentionally changed; backup retained at ${backup_dir}."
  fi

  write_upgrade_profile_manifest "${after}"
  if ! cmp -s "${before}" "${after}"; then
    warn "Profile manifest changed during upgrade. No VPN service was restarted by the upgrade."
    diff -u "${before}" "${after}" >"${backup_dir}/profiles.diff" || true
    chmod 0600 "${backup_dir}/profiles.diff"
    die "Profile preservation check failed. Inspect ${backup_dir}/profiles.diff and restore from profiles.tar if needed."
  fi

  if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "/root/install-vpn-stack.sh" ]]; then
    install -m 0700 "${BASH_SOURCE[0]}" /root/install-vpn-stack.sh
  fi
  printf '%s\n' "${GOLDEN_VPN_VERSION}" >"${INSTALLER_VERSION_FILE}"
  printf '%s\n' "${SERVER_LOCATION}" >"${STACK_DIR}/server-location.txt"
  chmod 0600 "${INSTALLER_VERSION_FILE}"
  chmod 0600 "${STACK_DIR}/server-location.txt"
  write_upgrade_report "${backup_dir}" "${before}" "${after}"
  log "Upgrade complete. Existing profiles are byte-for-byte unchanged."
  log "Upgrade report: ${UPGRADE_REPORT}"
}

upgrade_root_is_allowed() {
  local root="/${1#/}"
  case "${root}" in
    "${XRAY_DIR}"|\
    "${STACK_DIR}/trojan-xhttp-password.txt"|\
    "${STACK_DIR}/trojan-xhttp-path.txt"|\
    "${STACK_DIR}/trojan-xhttp-socket.txt"|\
    "${STACK_DIR}/trojan-xhttp-service.txt"|\
    "${STACK_DIR}/vless-xhttp-uuid.txt"|\
    "${STACK_DIR}/vless-xhttp-path.txt"|\
    "${STACK_DIR}/vless-reality-uuid.txt"|\
    "${STACK_DIR}/vless-reality-path.txt"|\
    "${HYSTERIA_DIR}"|\
    "${STACK_DIR}/hysteria-clients.json"|\
    "${STACK_DIR}/hysteria-auth.txt"|\
    "${STACK_DIR}/hysteria-obfs.txt"|\
    "${AWG_CONFIG}"|\
    "${KEY_DIR}/trojan"|\
    "${KEY_DIR}/vless"|\
    "${KEY_DIR}/vless-xhttp"|\
    "${KEY_DIR}/vless-reality"|\
    "${KEY_DIR}/hysteria"|\
    "${KEY_DIR}/awg"|\
    "${SUBSCRIPTION_DIR}"|\
    "${SUBSCRIPTION_WEB_DIR}")
      return 0
      ;;
  esac
  return 1
}

validate_upgrade_rollback_archive() {
  local backup_dir="$1"
  local roots_file="${backup_dir}/profile-roots.txt" archive="${backup_dir}/profiles.tar"
  local root member matched
  local -a roots=()

  [[ -s "${roots_file}" ]] || die "Rollback root list is missing: ${roots_file}"
  [[ -s "${archive}" ]] || die "Rollback archive is missing: ${archive}"
  [[ -s "${archive}.sha256" ]] || die "Rollback checksum is missing: ${archive}.sha256"
  sha256sum -c "${archive}.sha256" >/dev/null \
    || die "Rollback archive checksum verification failed."

  while IFS= read -r root; do
    [[ -n "${root}" && "${root}" != /* \
      && "${root}" != ".." && "${root}" != ../* \
      && "${root}" != */../* && "${root}" != */.. ]] \
      || die "Unsafe rollback root: ${root:-empty}"
    upgrade_root_is_allowed "${root}" || die "Rollback root is outside the protected profile set: /${root}"
    roots+=("${root%/}")
  done <"${roots_file}"
  ((${#roots[@]} > 0)) || die "Rollback root list is empty."

  while IFS= read -r member; do
    member="${member#./}"
    member="${member%/}"
    [[ -n "${member}" && "${member}" != /* \
      && "${member}" != ".." && "${member}" != ../* \
      && "${member}" != */../* && "${member}" != */.. ]] \
      || die "Unsafe path in rollback archive: ${member:-empty}"
    matched=0
    for root in "${roots[@]}"; do
      if [[ "${member}" == "${root}" || "${member}" == "${root}/"* ]]; then
        matched=1
        break
      fi
    done
    ((matched == 1)) || die "Archive member is outside the recorded profile roots: ${member}"
  done < <(tar -tf "${archive}")
}

upgrade_rollback() {
  local requested_backup="${1:-}" confirmation="${2:-}"
  local backup_root backup_dir roots_file before after root target

  [[ "${EUID}" -eq 0 ]] || die "Run rollback as root."
  [[ -n "${requested_backup}" ]] \
    || die "Usage: ./install-vpn-stack.sh upgrade-rollback BACKUP_DIR --confirm-profile-restore"
  [[ "${confirmation}" == "--confirm-profile-restore" ]] \
    || die "Rollback replaces the protected profile state. Re-run with --confirm-profile-restore after checking the backup path."
  need_command realpath
  need_command tar
  need_command sha256sum
  need_command cmp

  backup_root="$(realpath -e -- "${UPGRADE_BACKUP_ROOT}")" \
    || die "Upgrade backup root does not exist: ${UPGRADE_BACKUP_ROOT}"
  backup_dir="$(realpath -e -- "${requested_backup}")" \
    || die "Rollback backup directory does not exist: ${requested_backup}"
  [[ -d "${backup_dir}" && "${backup_dir}" == "${backup_root}/"* ]] \
    || die "Rollback backup must be a directory below ${backup_root}."

  roots_file="${backup_dir}/profile-roots.txt"
  before="${backup_dir}/profiles.before.tsv"
  after="${backup_dir}/profiles.rollback.tsv"
  [[ -s "${before}" ]] || die "Pre-upgrade manifest is missing: ${before}"
  validate_upgrade_rollback_archive "${backup_dir}"

  warn "Restoring the protected VPN profile state from ${backup_dir}."
  warn "VPN services will not be restarted automatically."
  while IFS= read -r root; do
    upgrade_root_is_allowed "${root}" || die "Unsafe rollback root: /${root}"
    target="/${root}"
    rm -rf -- "${target:?}"
  done <"${roots_file}"
  tar -C / -xpf "${backup_dir}/profiles.tar"

  write_upgrade_profile_manifest "${after}"
  if ! cmp -s "${before}" "${after}"; then
    diff -u "${before}" "${after}" >"${backup_dir}/profiles.rollback.diff" || true
    chmod 0600 "${backup_dir}/profiles.rollback.diff"
    die "Rollback extraction finished, but the manifest differs. Inspect ${backup_dir}/profiles.rollback.diff before restarting VPN services."
  fi

  log "Protected VPN profile state restored byte-for-byte from ${backup_dir}."
  log "No VPN service was restarted. Validate configs, then restart only the affected service if required."
}

vless_migration_nginx_site() {
  local site="${VLESS_MIGRATION_NGINX_SITE:-/etc/nginx/sites-enabled/decoy-443.conf}"
  [[ -e "${site}" || -L "${site}" ]] || die "Legacy nginx site was not found: ${site}"
  realpath -e -- "${site}"
}

vless_migration_service() {
  local service
  if [[ -n "${VLESS_XRAY_SERVICE:-}" ]]; then
    printf '%s\n' "${VLESS_XRAY_SERVICE}"
    return 0
  fi
  for service in xray-vless-xhttp-tls.service xray-vless-reality-xhttp.service; do
    if systemctl cat "${service}" >/dev/null 2>&1; then
      printf '%s\n' "${service}"
      return 0
    fi
  done
  die "Legacy VLESS systemd service was not found."
}

vless_migration_preflight() {
  local nginx_site service path
  [[ "${EUID}" -eq 0 ]] || die "Run VLESS migration as root."
  load_installed_context
  need_command jq
  need_command python3
  need_command openssl
  need_command sha256sum
  need_command realpath
  [[ -s "${XRAY_DIR}/config.json" ]] || die "Missing Xray config: ${XRAY_DIR}/config.json"
  jq -e . "${XRAY_DIR}/config.json" >/dev/null || die "Existing Xray config is not valid JSON."
  [[ "$(detect_installed_xray_protocol)" == "vless" ]] \
    || die "This command requires a legacy VLESS-only Golden Xray config."
  jq -e '[.inbounds[]? | select(.protocol == "trojan")] | length == 0' "${XRAY_DIR}/config.json" >/dev/null \
    || die "A Trojan inbound already exists; refusing to create a duplicate migration."
  for path in \
    "${STACK_DIR}/trojan-xhttp-password.txt" \
    "${STACK_DIR}/trojan-xhttp-path.txt" \
    "${STACK_DIR}/trojan-xhttp-socket.txt" \
    "${STACK_DIR}/trojan-xhttp-service.txt" \
    "${TROJAN_HELPER_PATH}"; do
    [[ ! -e "${path}" ]] || die "Stale Trojan migration artifact already exists: ${path}"
  done
  if [[ -d "${KEY_DIR}/trojan" ]] && find "${KEY_DIR}/trojan" -mindepth 1 -print -quit | grep -q .; then
    die "Trojan client directory is not empty: ${KEY_DIR}/trojan"
  fi
  jq -e '
    [.inbounds[]? | select(.protocol == "vless") | .settings.clients[]?]
    | length > 0
    and all(.email | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and ([.[].email] | length == (unique | length))
  ' "${XRAY_DIR}/config.json" >/dev/null \
    || die "Every legacy VLESS client must have a unique safe email label before migration."
  [[ -x /usr/local/bin/xray || -x "${XRAY_BIN:-}" ]] || die "Xray binary is missing."
  [[ -s "${STACK_DIR}/domain.txt" ]] || die "Installed domain metadata is missing."
  valid_server_location "${SERVER_LOCATION:-}" \
    || die "SERVER_LOCATION is missing. Export the two-letter location, for example SERVER_LOCATION=FR."
  nginx_site="$(vless_migration_nginx_site)"
  grep -Fq 'location / {' "${nginx_site}" \
    || die "Could not find the decoy catch-all location in ${nginx_site}."
  ! grep -Fq 'GOLDEN PARALLEL TROJAN BEGIN' "${nginx_site}" \
    || die "The parallel Trojan nginx block already exists."
  service="$(vless_migration_service)"
  systemctl is-active --quiet "${service}" \
    || die "Legacy VLESS service is not active: ${service}"
}

write_vless_migration_preserved_manifest() {
  local output="$1" raw xray_config_rel trojan_key_rel
  raw="$(mktemp "${output}.raw.XXXXXX")"
  write_upgrade_profile_manifest "${raw}"
  xray_config_rel="${XRAY_DIR#/}/config.json"
  trojan_key_rel="${KEY_DIR#/}/trojan/"
  {
    jq -Sc '[.inbounds[]? | select(.protocol == "vless")]' "${XRAY_DIR}/config.json" \
      | sha256sum | awk '{print "vless_inbounds\t" $1}'
    awk -F '\t' -v xray_config="${xray_config_rel}" -v trojan_keys="${trojan_key_rel}" '
      $1 == "xray_client" && $2 == "vless" { print; next }
      $1 == "hysteria_client" || $1 == "awg_peer_count" { print; next }
      $1 == "file" {
        path = $2
        if (path == xray_config) next
        if (index(path, trojan_keys) == 1) next
        if (path ~ /\/trojan-xhttp-(password|path|socket|service)\.txt$/) next
        print
      }
    ' "${raw}"
  } | LC_ALL=C sort >"${output}"
  chmod 0600 "${output}"
  rm -f "${raw}"
}

render_parallel_trojan_nginx_candidate() {
  local source="$1" output="$2" path="$3" socket="$4"
  python3 - "${source}" "${output}" "${path}" "${socket}" <<'PY'
import pathlib
import sys

source, output, path, socket = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
marker = "    location / {"
if text.count(marker) != 1:
    raise SystemExit("expected exactly one decoy catch-all location")
if "GOLDEN PARALLEL TROJAN BEGIN" in text:
    raise SystemExit("parallel Trojan block already exists")
block = f'''    # GOLDEN PARALLEL TROJAN BEGIN
    location ^~ {path} {{
        client_max_body_size 0;
        client_body_timeout 5m;
        grpc_read_timeout 315s;
        grpc_send_timeout 5m;
        grpc_set_header Host $host;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        grpc_pass unix:{socket};
    }}
    # GOLDEN PARALLEL TROJAN END

'''
pathlib.Path(output).write_text(text.replace(marker, block + marker, 1), encoding="utf-8")
PY
  chmod 0600 "${output}"
}

prepare_vless_to_trojan_migration() {
  local stamp bundle nginx_site service path password name clients_json tmp_credentials checksum_tmp
  local xray_bin="${XRAY_BIN:-/usr/local/bin/xray}" label encoded_path fragment domain
  local first_password=""
  vless_migration_preflight
  install -d -m 0700 "${VLESS_TROJAN_MIGRATION_ROOT}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  bundle="$(mktemp -d "${VLESS_TROJAN_MIGRATION_ROOT}/${stamp}.XXXXXX")"
  chmod 0700 "${bundle}"
  install -d -m 0700 "${bundle}/links"
  nginx_site="$(vless_migration_nginx_site)"
  service="$(vless_migration_service)"
  path="/$(rand_hex 8)/$(rand_hex 8)/"
  domain="$(<"${STACK_DIR}/domain.txt")"

  install -m 0600 "${XRAY_DIR}/config.json" "${bundle}/xray.before.json"
  install -m 0600 "${nginx_site}" "${bundle}/nginx.before.conf"
  printf '%s\n' "${nginx_site}" >"${bundle}/nginx-site.txt"
  printf '%s\n' "${service}" >"${bundle}/xray-service.txt"
  printf '%s\n' "${path}" >"${bundle}/trojan-path.txt"
  printf '%s\n' "${TROJAN_XHTTP_SOCKET}" >"${bundle}/trojan-socket.txt"
  tmp_credentials="${bundle}/credentials.tsv"
  : >"${tmp_credentials}"
  clients_json='[]'
  while IFS= read -r name; do
    password="$(rand_hex 24)"
    [[ -n "${first_password}" ]] || first_password="${password}"
    printf '%s\t%s\n' "${name}" "${password}" >>"${tmp_credentials}"
    clients_json="$(jq -c --arg password "${password}" --arg email "${name}" '. + [{password:$password,email:$email}]' <<<"${clients_json}")"
  done < <(jq -r '.inbounds[] | select(.protocol == "vless") | .settings.clients[].email' "${XRAY_DIR}/config.json")

  jq --argjson clients "${clients_json}" --arg path "${path}" --arg listen "${TROJAN_XHTTP_SOCKET},0666" '
    .inbounds += [{
      tag: "trojan-xhttp-tls",
      listen: $listen,
      protocol: "trojan",
      settings: {clients: $clients},
      streamSettings: {network: "xhttp", xhttpSettings: {path: $path, mode: "auto"}},
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
    }]
  ' "${XRAY_DIR}/config.json" >"${bundle}/xray.candidate.json"
  chmod 0600 "${bundle}/xray.candidate.json" "${tmp_credentials}"
  "${xray_bin}" run -test -config "${bundle}/xray.candidate.json" >/dev/null

  render_parallel_trojan_nginx_candidate "${nginx_site}" "${bundle}/nginx.candidate.conf" "${path}" "${TROJAN_XHTTP_SOCKET}"
  : >"${bundle}/client-map.tsv"
  while IFS=$'\t' read -r name password; do
    label="$(label_name "TROJAN" "${name}")"
    encoded_path="$(uri_encode "${path}")"
    fragment="$(uri_encode "${label}")"
    printf 'trojan://%s@%s:443?security=tls&type=xhttp&path=%s&mode=auto&sni=%s&host=%s&alpn=h2#%s\n' \
      "${password}" "${domain}" "${encoded_path}" "${domain}" "${domain}" "${fragment}" \
      >"${bundle}/links/${label}.txt"
    chmod 0600 "${bundle}/links/${label}.txt"
    printf '%s\t%s\t%s\n' "${name}" "${label}" "links/${label}.txt" >>"${bundle}/client-map.tsv"
  done <"${tmp_credentials}"
  chmod 0600 "${bundle}/client-map.tsv"
  printf '%s\n' "${first_password}" >"${bundle}/trojan-primary-password.txt"
  chmod 0600 "${bundle}/trojan-primary-password.txt"
  write_vless_migration_preserved_manifest "${bundle}/preserved.before.tsv"

  checksum_tmp="$(mktemp)"
  (
    cd "${bundle}"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  ) >"${checksum_tmp}"
  install -m 0600 "${checksum_tmp}" "${bundle}/bundle.sha256"
  rm -f "${checksum_tmp}"
  chmod 0600 "${bundle}/bundle.sha256"
  log "VLESS to Trojan migration bundle prepared: ${bundle}"
  log "No live Xray or nginx configuration was changed."
  printf '%s\n' "${bundle}"
}

resolve_vless_migration_bundle() {
  local requested="$1" root bundle
  root="$(realpath -e -- "${VLESS_TROJAN_MIGRATION_ROOT}")" \
    || die "Migration root does not exist: ${VLESS_TROJAN_MIGRATION_ROOT}"
  bundle="$(realpath -e -- "${requested}")" \
    || die "Migration bundle does not exist: ${requested}"
  [[ -d "${bundle}" && "${bundle}" == "${root}/"* ]] \
    || die "Migration bundle must be below ${root}."
  printf '%s\n' "${bundle}"
}

restore_vless_migration_preimage() {
  local bundle="$1" nginx_site="$2" service="$3" xray_bin="${XRAY_BIN:-/usr/local/bin/xray}"
  warn "Restoring pre-migration VLESS configuration."
  install -m 0600 "${bundle}/xray.before.json" "${XRAY_DIR}/config.json"
  install -m 0644 "${bundle}/nginx.before.conf" "${nginx_site}"
  rm -f "${TROJAN_XHTTP_SOCKET}"
  "${xray_bin}" run -test -config "${XRAY_DIR}/config.json" >/dev/null || true
  nginx -t >/dev/null 2>&1 || true
  systemctl restart "${service}" || true
  systemctl reload nginx || true
}

apply_vless_to_trojan_migration() {
  local requested="${1:-}" confirmation="${2:-}" bundle nginx_site service backup_dir
  local xray_bin="${XRAY_BIN:-/usr/local/bin/xray}" preserved_after link target socket
  local -a expected_sockets=()
  [[ -n "${requested}" ]] \
    || die "Usage: ./install-vpn-stack.sh migrate-vless-to-trojan-apply BUNDLE --confirm-parallel-trojan"
  [[ "${confirmation}" == "--confirm-parallel-trojan" ]] \
    || die "Re-run with --confirm-parallel-trojan after reviewing the migration bundle."
  vless_migration_preflight
  bundle="$(resolve_vless_migration_bundle "${requested}")"
  (
    cd "${bundle}"
    sha256sum -c bundle.sha256 >/dev/null
  ) || die "Migration bundle checksum verification failed."
  nginx_site="$(vless_migration_nginx_site)"
  service="$(vless_migration_service)"
  [[ "$(<"${bundle}/nginx-site.txt")" == "${nginx_site}" ]] || die "nginx site changed since bundle preparation."
  [[ "$(<"${bundle}/xray-service.txt")" == "${service}" ]] || die "Xray service changed since bundle preparation."
  cmp -s "${bundle}/xray.before.json" "${XRAY_DIR}/config.json" || die "Xray config changed since bundle preparation. Prepare a fresh bundle."
  cmp -s "${bundle}/nginx.before.conf" "${nginx_site}" || die "nginx config changed since bundle preparation. Prepare a fresh bundle."
  preserved_after="${bundle}/preserved.preapply.tsv"
  write_vless_migration_preserved_manifest "${preserved_after}"
  cmp -s "${bundle}/preserved.before.tsv" "${preserved_after}" \
    || die "Protected VLESS/Hysteria/AWG state changed since bundle preparation."
  while IFS=$'\t' read -r name label link; do
    [[ "${name}" =~ ^[A-Za-z0-9._-]+$ && "${label}" =~ ^TROJAN-[A-Z]{2}-[A-Za-z0-9._-]+$ ]] \
      || die "Unsafe client mapping in ${bundle}/client-map.tsv"
    [[ "${link}" == "links/${label}.txt" ]] || die "Unexpected client link path in migration bundle: ${link}"
    target="${KEY_DIR}/trojan/$(basename "${link}")"
    [[ ! -e "${target}" ]] || die "Trojan client file already exists: ${target}"
  done <"${bundle}/client-map.tsv"

  backup_dir="$(create_upgrade_backup)"
  log "Pre-migration profile backup created: ${backup_dir}"
  install -m 0600 "${bundle}/xray.candidate.json" "${XRAY_DIR}/config.json"
  install -m 0644 "${bundle}/nginx.candidate.conf" "${nginx_site}"
  if ! "${xray_bin}" run -test -config "${XRAY_DIR}/config.json" >/dev/null || ! nginx -t >/dev/null; then
    restore_vless_migration_preimage "${bundle}" "${nginx_site}" "${service}"
    die "Candidate config validation failed; legacy VLESS configuration was restored."
  fi

  rm -f "${TROJAN_XHTTP_SOCKET}"
  if ! systemctl restart "${service}" || ! systemctl reload nginx; then
    restore_vless_migration_preimage "${bundle}" "${nginx_site}" "${service}"
    die "Service activation failed; legacy VLESS configuration was restored."
  fi
  mapfile -t expected_sockets < <(
    jq -r '.inbounds[]?.listen // empty | split(",")[0] | select(startswith("/"))' "${XRAY_DIR}/config.json"
  )
  ((${#expected_sockets[@]} >= 2)) || {
    restore_vless_migration_preimage "${bundle}" "${nginx_site}" "${service}"
    die "Expected both legacy VLESS and parallel Trojan unix sockets."
  }
  local socket_ready=0 attempt all_ready
  for ((attempt = 0; attempt < 20; attempt++)); do
    all_ready=1
    for socket in "${expected_sockets[@]}"; do
      [[ -S "${socket}" ]] || { all_ready=0; break; }
    done
    if ((all_ready == 1)); then socket_ready=1; break; fi
    sleep 0.25
  done
  if ((socket_ready == 0)); then
    restore_vless_migration_preimage "${bundle}" "${nginx_site}" "${service}"
    die "Not all VLESS/Trojan unix sockets appeared; legacy VLESS configuration was restored."
  fi

  write_vless_migration_preserved_manifest "${bundle}/preserved.after.tsv"
  if ! cmp -s "${bundle}/preserved.before.tsv" "${bundle}/preserved.after.tsv"; then
    restore_vless_migration_preimage "${bundle}" "${nginx_site}" "${service}"
    die "A protected legacy profile changed; legacy VLESS configuration was restored."
  fi

  if ! (
    set -Eeuo pipefail
    install -d -m 0700 "${KEY_DIR}/trojan"
    while IFS=$'\t' read -r _ _ link; do
      target="${KEY_DIR}/trojan/$(basename "${link}")"
      install -m 0600 "${bundle}/${link}" "${target}"
    done <"${bundle}/client-map.tsv"
    install -m 0600 "${bundle}/trojan-path.txt" "${STACK_DIR}/trojan-xhttp-path.txt"
    install -m 0600 "${bundle}/trojan-socket.txt" "${STACK_DIR}/trojan-xhttp-socket.txt"
    install -m 0600 "${bundle}/trojan-primary-password.txt" "${STACK_DIR}/trojan-xhttp-password.txt"
    printf '%s\n' "${service}" >"${STACK_DIR}/trojan-xhttp-service.txt"
    chmod 0600 "${STACK_DIR}/trojan-xhttp-service.txt"
    install_helper_trojan
  ); then
    while IFS=$'\t' read -r _ _ link; do
      rm -f -- "${KEY_DIR}/trojan/$(basename "${link}")"
    done <"${bundle}/client-map.tsv"
    rmdir "${KEY_DIR}/trojan" 2>/dev/null || true
    rm -f "${STACK_DIR}"/trojan-xhttp-{password,path,socket,service}.txt "${TROJAN_HELPER_PATH}"
    restore_vless_migration_preimage "${bundle}" "${nginx_site}" "${service}"
    die "Could not install Trojan migration artifacts; legacy VLESS configuration was restored."
  fi
  cat >"${VLESS_TROJAN_MIGRATION_REPORT}" <<EOF
{
  "version": $(json_escape "${GOLDEN_VPN_VERSION}"),
  "applied_at": $(json_escape "$(date -Is)"),
  "bundle": $(json_escape "${bundle}"),
  "backup_dir": $(json_escape "${backup_dir}"),
  "legacy_vless_preserved": true,
  "trojan_clients_created": $(wc -l <"${bundle}/client-map.tsv"),
  "xray_service": $(json_escape "${service}"),
  "vpn_services_restarted": [$(json_escape "${service}")],
  "nginx_reloaded": true
}
EOF
  chmod 0600 "${VLESS_TROJAN_MIGRATION_REPORT}"
  log "Parallel Trojan activated. Legacy VLESS clients and Hysteria/AWG state are unchanged."
  log "Migration report: ${VLESS_TROJAN_MIGRATION_REPORT}"
}

awg_mtu_required_keys_json() {
  local config="$1" mtu="$2"
  python3 - "${config}" "${mtu}" <<'PY'
import json
import re
import sys

config, mtu = sys.argv[1:]
required = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"]
values = {}
section = None
with open(config, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.strip()
        match = re.fullmatch(r"\[([^]]+)\]", line)
        if match:
            section = match.group(1).lower()
            continue
        if section != "interface" or not line or line.startswith(("#", ";")) or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        for canonical in required:
            if key.lower() == canonical.lower():
                values[canonical] = value
                break
missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit("missing full AWG 2.0 tuning fields: " + ", ".join(missing))
values = {"MTU": mtu, **{key: values[key] for key in required}}
print(json.dumps(values, ensure_ascii=False, separators=(",", ":")))
PY
}

render_awg_tuning_candidate() {
  local source="$1" output="$2" values_json="$3"
  python3 - "${source}" "${output}" "${values_json}" <<'PY'
import json
import pathlib
import re
import sys

source, output, values_raw = sys.argv[1:]
values = json.loads(values_raw)
standard_order = ["MTU", "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"]
order = [key for key in standard_order if key in values]
lookup = {key.lower(): key for key in order}
lines = pathlib.Path(source).read_text(encoding="utf-8").splitlines(keepends=True)
if "MTU" in values:
    lines = [f"# MTU = {values['MTU']}\n" if re.fullmatch(r"\s*#\s*MTU\s*=.*", line.rstrip("\r\n"), re.IGNORECASE) else line for line in lines]
starts = [index for index, line in enumerate(lines) if line.strip().lower() == "[interface]"]
if len(starts) != 1:
    raise SystemExit("expected exactly one [Interface] section")
start = starts[0]
end = next((index for index in range(start + 1, len(lines)) if re.fullmatch(r"\s*\[[^]]+\]\s*", lines[index])), len(lines))
seen = set()
rendered = lines[: start + 1]
for line in lines[start + 1 : end]:
    stripped = line.strip()
    comment = re.fullmatch(r"#\s*MTU\s*=.*", stripped, re.IGNORECASE)
    if comment:
        rendered.append(f"# MTU = {values['MTU']}\n")
        continue
    if "=" in line and not stripped.startswith(("#", ";")):
        key = line.split("=", 1)[0].strip()
        canonical = lookup.get(key.lower())
        if canonical:
            if canonical not in seen:
                rendered.append(f"{canonical} = {values[canonical]}\n")
                seen.add(canonical)
            continue
    rendered.append(line)
for key in order:
    if key not in seen:
        rendered.append(f"{key} = {values[key]}\n")
if rendered and not rendered[-1].endswith("\n"):
    rendered[-1] += "\n"
rendered.extend(lines[end:])
pathlib.Path(output).write_text("".join(rendered), encoding="utf-8")
PY
  chmod 0600 "${output}"
}

write_awg_non_tuning_manifest() {
  local config="$1" client_dir="$2" output="$3"
  python3 - "${config}" "${client_dir}" >"${output}" <<'PY'
import hashlib
import pathlib
import re
import sys

config = pathlib.Path(sys.argv[1])
client_dir = pathlib.Path(sys.argv[2])
tuning = {key.lower() for key in ["MTU", "Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"]}

def normalized(path):
    result = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if re.fullmatch(r"#\s*(MTU|ObfuscationProfile|EffectiveProfile)\s*=.*", stripped, re.IGNORECASE):
            continue
        if "=" in raw and not stripped.startswith(("#", ";")):
            key = raw.split("=", 1)[0].strip().lower()
            if key in tuning:
                continue
        result.append(raw)
    return ("\n".join(result) + "\n").encode()

paths = [("server", config)]
paths.extend((f"client/{path.name}", path) for path in sorted(client_dir.glob("*.conf")))
for label, path in paths:
    print(f"{label}\t{hashlib.sha256(normalized(path)).hexdigest()}")
PY
  chmod 0600 "${output}"
}

write_awg_params_candidate() {
  local output="$1" values_json="$2" mtu="$3" first_client="$4"
  local key value listen_port dns allowed keepalive endpoint endpoint_port
  listen_port="$(awk -F= 'tolower($1) ~ /^[[:space:]]*listenport[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "${AWG_CONFIG}")"
  dns="$(awk -F= 'tolower($1) ~ /^[[:space:]]*dns[[:space:]]*$/ {sub(/^[^=]*=[[:space:]]*/,""); print; exit}' "${first_client}")"
  allowed="$(awk -F= 'tolower($1) ~ /^[[:space:]]*allowedips[[:space:]]*$/ {sub(/^[^=]*=[[:space:]]*/,""); print; exit}' "${first_client}")"
  keepalive="$(awk -F= 'tolower($1) ~ /^[[:space:]]*persistentkeepalive[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "${first_client}")"
  endpoint="$(awk -F= 'tolower($1) ~ /^[[:space:]]*endpoint[[:space:]]*$/ {sub(/^[^=]*=[[:space:]]*/,""); print; exit}' "${first_client}")"
  endpoint_port="${endpoint##*:}"
  [[ "${listen_port}" =~ ^[0-9]+$ ]] || listen_port="${AWG_DEFAULT_PORT}"
  [[ "${endpoint_port}" =~ ^[0-9]+$ ]] || endpoint_port="${listen_port}"
  [[ -n "${dns}" ]] || dns="1.1.1.1"
  [[ -n "${allowed}" ]] || allowed="0.0.0.0/0"
  [[ "${keepalive}" =~ ^[0-9]+$ ]] || keepalive="25"
  {
    printf 'AWG_OBFS_PROFILE=%q\n' "custom"
    printf 'AWG_EFFECTIVE_PROFILE=%q\n' "custom"
    printf 'AWG_TUNING_SOURCE=%q\n' "migration-preserved-server-obfuscation"
    printf 'AWG_MTU=%q\n' "${mtu}"
    printf 'AWG_MTU_SOURCE=%q\n' "migration-explicit"
    printf 'AWG_ENDPOINT_PORT=%q\n' "${endpoint_port}"
    printf 'AWG_DNS=%q\n' "${dns}"
    printf 'AWG_ALLOWED_IPS=%q\n' "${allowed}"
    printf 'AWG_KEEPALIVE=%q\n' "${keepalive}"
    for key in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5; do
      value="$(jq -r --arg key "${key}" '.[$key]' <<<"${values_json}")"
      printf 'AWG_%s=%q\n' "$(printf '%s' "${key}" | tr '[:lower:]' '[:upper:]')" "${value}"
    done
  } >"${output}"
  chmod 0600 "${output}"
}

awg_mtu_migration_preflight() {
  local mtu="$1" client_count
  [[ "${EUID}" -eq 0 ]] || die "Run AWG MTU migration as root."
  validate_int_range AWG_MTU "${mtu}" 1200 1420
  need_command jq
  need_command python3
  need_command sha256sum
  [[ -s "${AWG_CONFIG}" ]] || die "Missing AWG server config: ${AWG_CONFIG}"
  [[ -d "${KEY_DIR}/awg" ]] || die "Missing AWG client directory: ${KEY_DIR}/awg"
  client_count="$(find "${KEY_DIR}/awg" -maxdepth 1 -type f -name '*.conf' | wc -l)"
  ((client_count > 0)) || die "No AWG client configs were found."
  awg_mtu_required_keys_json "${AWG_CONFIG}" "${mtu}" >/dev/null
  systemctl is-active --quiet awg-quick@awg0.service || die "awg-quick@awg0.service is not active."
}

prepare_awg_mtu_migration() {
  local mtu="${1:-1420}" stamp bundle values_json client candidate checksum_tmp first_client
  awg_mtu_migration_preflight "${mtu}"
  values_json="$(awg_mtu_required_keys_json "${AWG_CONFIG}" "${mtu}")"
  install -d -m 0700 "${AWG_MTU_MIGRATION_ROOT}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  bundle="$(mktemp -d "${AWG_MTU_MIGRATION_ROOT}/${stamp}.XXXXXX")"
  chmod 0700 "${bundle}"
  install -d -m 0700 "${bundle}/clients.before" "${bundle}/clients.candidate"
  install -m 0600 "${AWG_CONFIG}" "${bundle}/awg0.before.conf"
  render_awg_tuning_candidate "${AWG_CONFIG}" "${bundle}/awg0.candidate.conf" "$(jq -c '{MTU}' <<<"${values_json}")"

  while IFS= read -r client; do
    candidate="${bundle}/clients.candidate/$(basename "${client}")"
    install -m 0600 "${client}" "${bundle}/clients.before/$(basename "${client}")"
    render_awg_tuning_candidate "${client}" "${candidate}" "${values_json}"
  done < <(find "${KEY_DIR}/awg" -maxdepth 1 -type f -name '*.conf' | LC_ALL=C sort)
  write_awg_non_tuning_manifest "${AWG_CONFIG}" "${KEY_DIR}/awg" "${bundle}/identity.before.tsv"
  write_awg_non_tuning_manifest "${bundle}/awg0.candidate.conf" "${bundle}/clients.candidate" "${bundle}/identity.candidate.tsv"
  cmp -s "${bundle}/identity.before.tsv" "${bundle}/identity.candidate.tsv" \
    || die "AWG candidate changed key/address/peer material outside tuning fields."
  first_client="$(find "${KEY_DIR}/awg" -maxdepth 1 -type f -name '*.conf' | LC_ALL=C sort | sed -n '1p')"
  write_awg_params_candidate "${bundle}/awg-params.candidate.env" "${values_json}" "${mtu}" "${first_client}"
  if [[ -s "${STACK_DIR}/awg-params.env" ]]; then
    install -m 0600 "${STACK_DIR}/awg-params.env" "${bundle}/awg-params.before.env"
    printf 'present\n' >"${bundle}/awg-params.before.state"
  else
    : >"${bundle}/awg-params.before.env"
    printf 'absent\n' >"${bundle}/awg-params.before.state"
  fi
  printf '%s\n' "${mtu}" >"${bundle}/target-mtu.txt"
  printf '%s\n' "$(find "${bundle}/clients.candidate" -type f -name '*.conf' | wc -l)" >"${bundle}/client-count.txt"
  chmod 0600 "${bundle}"/*.txt "${bundle}/awg-params.before.env" "${bundle}/awg-params.before.state"
  checksum_tmp="$(mktemp)"
  (
    cd "${bundle}"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  ) >"${checksum_tmp}"
  install -m 0600 "${checksum_tmp}" "${bundle}/bundle.sha256"
  rm -f "${checksum_tmp}"
  log "AWG MTU/tuning migration bundle prepared: ${bundle}"
  log "Target MTU: ${mtu}; keys and peer material are unchanged; live AWG was not modified."
  printf '%s\n' "${bundle}"
}

resolve_awg_mtu_bundle() {
  local requested="$1" root bundle
  root="$(realpath -e -- "${AWG_MTU_MIGRATION_ROOT}")" || die "AWG MTU migration root does not exist."
  bundle="$(realpath -e -- "${requested}")" || die "AWG MTU bundle does not exist: ${requested}"
  [[ -d "${bundle}" && "${bundle}" == "${root}/"* ]] || die "AWG MTU bundle must be below ${root}."
  printf '%s\n' "${bundle}"
}

restore_awg_mtu_preimage() {
  local bundle="$1" client
  warn "Restoring pre-migration AWG configuration and saved client files."
  install -m 0600 "${bundle}/awg0.before.conf" "${AWG_CONFIG}"
  find "${KEY_DIR}/awg" -maxdepth 1 -type f -name '*.conf' -delete
  while IFS= read -r client; do
    install -m 0600 "${client}" "${KEY_DIR}/awg/$(basename "${client}")"
  done < <(find "${bundle}/clients.before" -maxdepth 1 -type f -name '*.conf' | LC_ALL=C sort)
  if [[ "$(<"${bundle}/awg-params.before.state")" == "present" ]]; then
    install -m 0600 "${bundle}/awg-params.before.env" "${STACK_DIR}/awg-params.env"
  else
    rm -f "${STACK_DIR}/awg-params.env"
  fi
  systemctl restart awg-quick@awg0.service || true
}

apply_awg_mtu_migration() {
  local requested="${1:-}" confirmation="${2:-}" bundle mtu backup_dir client expected current
  local identity_current identity_after awg_quick_bin="${AWG_QUICK_BIN:-awg-quick}"
  [[ -n "${requested}" ]] || die "Usage: ./install-vpn-stack.sh migrate-awg-mtu-apply BUNDLE --confirm-awg-mtu"
  [[ "${confirmation}" == "--confirm-awg-mtu" ]] \
    || die "Re-run with --confirm-awg-mtu after reviewing the bundle and creating a provider snapshot."
  bundle="$(resolve_awg_mtu_bundle "${requested}")"
  mtu="$(<"${bundle}/target-mtu.txt")"
  awg_mtu_migration_preflight "${mtu}"
  (
    cd "${bundle}"
    sha256sum -c bundle.sha256 >/dev/null
  ) || die "AWG MTU migration bundle checksum verification failed."
  cmp -s "${bundle}/awg0.before.conf" "${AWG_CONFIG}" || die "AWG server config changed since bundle preparation."
  if [[ "$(<"${bundle}/awg-params.before.state")" == "present" ]]; then
    cmp -s "${bundle}/awg-params.before.env" "${STACK_DIR}/awg-params.env" \
      || die "AWG parameter metadata changed since bundle preparation."
  else
    [[ ! -e "${STACK_DIR}/awg-params.env" ]] || die "AWG parameter metadata appeared since bundle preparation."
  fi
  expected="$(find "${bundle}/clients.before" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | LC_ALL=C sort)"
  current="$(find "${KEY_DIR}/awg" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | LC_ALL=C sort)"
  [[ "${expected}" == "${current}" ]] || die "AWG client file set changed since bundle preparation."
  while IFS= read -r client; do
    cmp -s "${client}" "${KEY_DIR}/awg/$(basename "${client}")" \
      || die "AWG client changed since bundle preparation: $(basename "${client}")"
  done < <(find "${bundle}/clients.before" -maxdepth 1 -type f -name '*.conf' | LC_ALL=C sort)
  identity_current="${bundle}/identity.preapply.tsv"
  write_awg_non_tuning_manifest "${AWG_CONFIG}" "${KEY_DIR}/awg" "${identity_current}"
  cmp -s "${bundle}/identity.before.tsv" "${identity_current}" || die "AWG identity material changed since preparation."
  "${awg_quick_bin}" strip "${bundle}/awg0.candidate.conf" >/dev/null \
    || die "Candidate AWG server config validation failed."

  backup_dir="$(create_upgrade_backup)"
  log "Pre-MTU profile backup created: ${backup_dir}"
  install -m 0600 "${bundle}/awg0.candidate.conf" "${AWG_CONFIG}"
  while IFS= read -r client; do
    install -m 0600 "${client}" "${KEY_DIR}/awg/$(basename "${client}")"
  done < <(find "${bundle}/clients.candidate" -maxdepth 1 -type f -name '*.conf' | LC_ALL=C sort)
  install -m 0600 "${bundle}/awg-params.candidate.env" "${STACK_DIR}/awg-params.env"

  if ! systemctl restart awg-quick@awg0.service \
    || ! awg show awg0 >/dev/null 2>&1 \
    || ! ip -o link show dev awg0 | grep -Eq "[[:space:]]mtu[[:space:]]+${mtu}([[:space:]]|$)"; then
    restore_awg_mtu_preimage "${bundle}"
    die "AWG activation with MTU ${mtu} failed; previous server and client configs were restored."
  fi
  identity_after="${bundle}/identity.after.tsv"
  write_awg_non_tuning_manifest "${AWG_CONFIG}" "${KEY_DIR}/awg" "${identity_after}"
  if ! cmp -s "${bundle}/identity.before.tsv" "${identity_after}"; then
    restore_awg_mtu_preimage "${bundle}"
    die "AWG keys/address/peer material changed; previous state was restored."
  fi
  cat >"${AWG_TUNING_REPORT}" <<EOF
{
  "generated_at": $(json_escape "$(date -Is)"),
  "requested_profile": "custom",
  "effective_profile": "custom",
  "mtu": ${mtu},
  "mtu_source": "migration-explicit",
  "params_path": $(json_escape "${STACK_DIR}/awg-params.env"),
  "note": "Existing server obfuscation J/S/H/I1-I5 was preserved and synchronized into saved client configs; credentials were not rotated."
}
EOF
  chmod 0600 "${AWG_TUNING_REPORT}"
  cat >"${AWG_MTU_MIGRATION_REPORT}" <<EOF
{
  "version": $(json_escape "${GOLDEN_VPN_VERSION}"),
  "applied_at": $(json_escape "$(date -Is)"),
  "bundle": $(json_escape "${bundle}"),
  "backup_dir": $(json_escape "${backup_dir}"),
  "mtu": ${mtu},
  "client_files_updated": $(<"${bundle}/client-count.txt"),
  "credentials_preserved": true,
  "full_awg2_tuning": true
}
EOF
  chmod 0600 "${AWG_MTU_MIGRATION_REPORT}"
  log "AWG MTU ${mtu} activated; full J/S/H/I1-I5 tuning and all credentials were preserved."
  log "Saved client configs were updated in place and must be re-imported to change MTU on client devices."
}

upgrade_check() {
  local tmp protocol
  upgrade_preflight
  protocol="$(detect_installed_xray_protocol)"
  tmp="$(mktemp)"
  write_upgrade_profile_manifest "${tmp}"
  printf 'Golden VPN upgrade check\n'
  printf 'Version: %s\n' "${GOLDEN_VPN_VERSION}"
  printf 'Protocol: %s\n' "${protocol}"
  printf 'Xray clients: %s\n' "$(manifest_record_count "${tmp}" xray_client)"
  printf 'Hysteria clients: %s\n' "$(manifest_record_count "${tmp}" hysteria_client)"
  printf 'AWG peers: %s\n' "$(awk -F '\t' '$1 == "awg_peer_count" {print $2}' "${tmp}")"
  rm -f "${tmp}"
}

main() {
  local storage_required_mb
  progress "Checking input variables and kernel readiness"
  require_root_and_env
  enable_compact_install_ui append
  storage_required_mb="$(install_required_free_mb)"
  if ((storage_required_mb < INSTALL_MIN_FREE_MB)); then
    log "Installed base package stage detected; using ${storage_required_mb} MB retry reserve instead of the clean-install ${INSTALL_MIN_FREE_MB} MB reserve."
  fi
  require_install_storage "${storage_required_mb}" "Full installation"
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
  install_mimic_optional
  progress "Configuring Hysteria2"
  configure_hysteria
  progress "Installing AmneziaWG"
  install_amneziawg
  progress "Configuring AmneziaWG"
  configure_amneziawg
  progress "Configuring swap"
  configure_swap
  configure_udp_buffers
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
  printf '%s\n' "${GOLDEN_VPN_VERSION}" >"${INSTALLER_VERSION_FILE}"
  chmod 0600 "${INSTALLER_VERSION_FILE}"
  progress "Installation complete"
  log "Golden VPN stack installation complete."
}

preflight_check() {
  local failed=0 free_mb free_inode_percent

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

  free_mb="$(root_free_mb 2>/dev/null || true)"
  free_inode_percent="$(root_free_inode_percent 2>/dev/null || true)"
  if [[ "${free_mb}" =~ ^[0-9]+$ ]]; then
    if ((free_mb < INSTALL_MIN_FREE_MB)); then
      fail "root filesystem has ${free_mb} MB free; full install requires at least ${INSTALL_MIN_FREE_MB} MB"
    elif ((free_mb < 6144)); then
      warn_check "root filesystem has only ${free_mb} MB free"
    else
      pass "root filesystem has ${free_mb} MB free"
    fi
  else
    fail "root filesystem free space could not be determined"
  fi

  if [[ "${free_inode_percent}" =~ ^[0-9]+$ ]]; then
    if ((free_inode_percent < MIN_FREE_INODE_PERCENT)); then
      fail "root filesystem has only ${free_inode_percent}% free inodes"
    else
      pass "root filesystem has ${free_inode_percent}% free inodes"
    fi
  else
    fail "root filesystem inode capacity could not be determined"
  fi

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

configure_storage_only() {
  local free_mb
  [[ "${EUID}" -eq 0 ]] || die "Run this command as root."
  free_mb="$(root_free_mb)"
  if [[ ! "${free_mb}" =~ ^[0-9]+$ ]] || ((free_mb < 16)); then
    storage_hint /
    die "Storage repair needs at least 16 MB free on / to write configuration files. Free one large log first, then retry."
  fi

  if ! command -v logrotate >/dev/null 2>&1; then
    apt_get update
    apt_get install -y logrotate
  fi

  configure_log_limits
  systemctl daemon-reload
  systemctl restart systemd-journald || true
  systemctl enable --now logrotate.timer
  systemctl enable --now vpn-storage-maintenance.timer
  systemctl start vpn-storage-maintenance.service

  log "Storage protection configured."
  df -h /
  journalctl --disk-usage 2>/dev/null || true
  systemctl list-timers logrotate.timer vpn-storage-maintenance.timer --no-pager || true
}

show_installer_usage() {
  cat <<'USAGE'
Usage:
  ./install-vpn-stack.sh                 Run two-stage bootstrap, schedule stage2, and reboot once
  ./install-vpn-stack.sh bootstrap       Same as default two-stage bootstrap
  ./install-vpn-stack.sh install         Run stage2/full install now
  ./install-vpn-stack.sh upgrade         Update features without replacing existing client profiles
  ./install-vpn-stack.sh upgrade-check   Read-only compatibility and profile-count check
  ./install-vpn-stack.sh upgrade-rollback BACKUP_DIR --confirm-profile-restore
                                          Restore protected profiles from an upgrade backup
  ./install-vpn-stack.sh migrate-vless-to-trojan-prepare
                                          Build a reviewed parallel-Trojan bundle without live changes
  ./install-vpn-stack.sh migrate-vless-to-trojan-apply BUNDLE --confirm-parallel-trojan
                                          Apply a prepared bundle while preserving legacy VLESS
  ./install-vpn-stack.sh migrate-awg-mtu-prepare [MTU]
                                          Prepare same-key AWG tuning configs, default MTU 1320
  ./install-vpn-stack.sh migrate-awg-mtu-apply BUNDLE --confirm-awg-mtu
                                          Apply prepared MTU/full-obfuscation configs transactionally
  ./install-vpn-stack.sh preflight       Check inputs and host readiness without changing VPN configs
  ./install-vpn-stack.sh validate        Validate installed listeners, services, cert, and decoy
  ./install-vpn-stack.sh verify          Alias for validate
  ./install-vpn-stack.sh report          Write and print install reports
  ./install-vpn-stack.sh storage-repair  Apply disk/log limits without reinstalling the VPN stack
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
    upgrade)
      shift || true
      run_with_upgrade_lock() {
        if command -v flock >/dev/null 2>&1; then
          exec 200>"${INSTALL_LOCK}"
          flock -n 200 || die "Another Golden VPN install or upgrade is already running."
        fi
        upgrade_existing_stack "$@"
      }
      run_with_upgrade_lock "$@"
      ;;
    upgrade-check|check-upgrade)
      upgrade_check
      ;;
    upgrade-rollback|rollback-upgrade)
      shift || true
      upgrade_rollback "$@"
      ;;
    migrate-vless-to-trojan-prepare|prepare-vless-to-trojan)
      prepare_vless_to_trojan_migration
      ;;
    migrate-vless-to-trojan-apply|apply-vless-to-trojan)
      shift || true
      apply_vless_to_trojan_migration "$@"
      ;;
    migrate-awg-mtu-prepare|prepare-awg-mtu)
      shift || true
      prepare_awg_mtu_migration "$@"
      ;;
    migrate-awg-mtu-apply|apply-awg-mtu)
      shift || true
      apply_awg_mtu_migration "$@"
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
    storage-repair|configure-storage|storage)
      configure_storage_only
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

if [[ "${GOLDEN_VPN_SOURCE_ONLY:-0}" != "1" ]]; then
  dispatch "$@"
fi
