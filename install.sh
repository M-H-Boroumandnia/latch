#!/usr/bin/env bash
set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

GITHUB_REPO="${POWER_LATCH_REPO:-M-H-Boroumandnia/latch}"
GITHUB_BRANCH="${POWER_LATCH_BRANCH:-main}"
INSTALL_DIR="/opt/power-latch"
CONF_DIR="/etc/power-latch"
CONF_FILE="${CONF_DIR}/power-latch.conf"
SERVICE_FILE="/etc/systemd/system/power-latch.service"
BIN_FILE="/usr/bin/power-latch"
OVERLAY_BEGIN="# power-latch begin"
OVERLAY_END="# power-latch end"

loge() {
    echo -e "${red}[ERR]${plain} $*"
}

logi() {
    echo -e "${green}[INF]${plain} $*"
}

logw() {
    echo -e "${yellow}[WRN]${plain} $*"
}

is_real_script() {
    local path="$1"
    [[ -f "${path}" ]] || return 1
    case "${path}" in
        /dev/fd/* | /proc/self/fd/* | /dev/stdin)
            return 1
            ;;
    esac
    return 0
}

require_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        if [[ "${BASH_SOURCE[0]:-}" == /tmp/power-latch-install.* ]]; then
            trap 'rm -f "${BASH_SOURCE[0]}"' EXIT
        fi
        return 0
    fi

    local script="${BASH_SOURCE[0]:-$0}"
    if is_real_script "${script}"; then
        exec sudo -E bash "${script}" "$@"
    fi

    local tmp url
    tmp="$(mktemp /tmp/power-latch-install.XXXXXX)"
    url="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/install.sh"
    logi "Re-running installer as root"
    if ! curl -fsSL "${url}" -o "${tmp}"; then
        rm -f "${tmp}"
        loge "Failed to download installer for privilege elevation."
        exit 1
    fi
    chmod 700 "${tmp}"
    exec sudo -E env POWER_LATCH_REPO="${GITHUB_REPO}" POWER_LATCH_BRANCH="${GITHUB_BRANCH}" bash "${tmp}" "$@"
}

is_raspberry_pi() {
    if [[ -f /proc/device-tree/model ]]; then
        grep -qi raspberry /proc/device-tree/model
        return
    fi
    grep -qi raspberry /proc/cpuinfo 2>/dev/null
}

find_boot_config() {
    if [[ -f /boot/firmware/config.txt ]]; then
        echo /boot/firmware/config.txt
        return 0
    fi
    if [[ -f /boot/config.txt ]]; then
        echo /boot/config.txt
        return 0
    fi
    return 1
}

get_conf() {
    local key="$1"
    local default="$2"
    local value=""
    if [[ -f "${CONF_FILE}" ]]; then
        value="$(grep -E "^${key}=" "${CONF_FILE}" | tail -n1 | cut -d= -f2- || true)"
    fi
    if [[ -z "${value}" ]]; then
        echo "${default}"
    else
        echo "${value}"
    fi
}

detect_source_dir() {
    local script_path="${BASH_SOURCE[0]:-}"
    local script_dir=""
    if [[ -n "${script_path}" && -f "${script_path}" ]]; then
        script_dir="$(cd "$(dirname "${script_path}")" && pwd)"
    fi
    if [[ -n "${script_dir}" && -f "${script_dir}/src/power_latch.py" && -f "${script_dir}/power-latch.sh" ]]; then
        echo "${script_dir}"
        return 0
    fi
    return 1
}

install_dependencies() {
    if ! command -v apt-get >/dev/null 2>&1; then
        loge "apt-get is required. This installer supports Raspberry Pi OS, Debian, and Ubuntu."
        exit 1
    fi

    logi "Installing dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3 python3-gpiozero python3-lgpio curl ca-certificates
    apt-get install -y python3-rpi-lgpio || true
}

download_release() {
    local dest="$1"
    local ref="${2:-${GITHUB_BRANCH}}"
    local url=""

    if [[ "${ref}" =~ ^v?[0-9] ]]; then
        url="https://github.com/${GITHUB_REPO}/archive/refs/tags/${ref}.tar.gz"
    else
        url="https://github.com/${GITHUB_REPO}/archive/refs/heads/${ref}.tar.gz"
    fi

    logi "Downloading ${url}"
    curl -fsSL "${url}" | tar -xz -C "${dest}" --strip-components=1
}

install_files() {
    local source_dir="$1"

    mkdir -p "${INSTALL_DIR}" "${CONF_DIR}"

    install -m 755 "${source_dir}/src/power_latch.py" "${INSTALL_DIR}/power_latch.py"
    install -m 755 "${source_dir}/power-latch.sh" "${INSTALL_DIR}/power-latch.sh"
    install -m 644 "${source_dir}/systemd/power-latch.service" "${SERVICE_FILE}"
    install -m 644 "${source_dir}/VERSION" "${INSTALL_DIR}/VERSION"
    install -m 755 "${source_dir}/power-latch.sh" "${BIN_FILE}"

    if [[ ! -f "${CONF_FILE}" ]]; then
        install -m 644 "${source_dir}/config/power-latch.conf" "${CONF_FILE}"
        logi "Wrote default configuration to ${CONF_FILE}"
    else
        logi "Keeping existing configuration at ${CONF_FILE}"
    fi
}

apply_gpio_poweroff() {
    local cfg=""
    local pin=""
    local active=""
    local line=""
    local tmp=""

    if ! cfg="$(find_boot_config)"; then
        logw "Boot firmware config.txt was not found. gpio-poweroff was not applied."
        return 0
    fi

    pin="$(get_conf POWEROFF_PIN 17)"
    active="$(get_conf POWEROFF_ACTIVE_HIGH 1)"
    if [[ "${active}" == "1" ]]; then
        line="dtoverlay=gpio-poweroff,gpiopin=${pin},active_high=1"
    else
        line="dtoverlay=gpio-poweroff,gpiopin=${pin},active_low=1"
    fi

    if [[ ! -f "${cfg}.power-latch.bak" ]]; then
        cp "${cfg}" "${cfg}.power-latch.bak"
        logi "Backed up ${cfg} to ${cfg}.power-latch.bak"
    fi

    tmp="$(mktemp)"
    awk -v begin="${OVERLAY_BEGIN}" -v end="${OVERLAY_END}" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        skip { next }
        /^[[:space:]]*dtoverlay=gpio-poweroff/ { next }
        { print }
    ' "${cfg}" > "${tmp}"

    {
        cat "${tmp}"
        printf '\n%s\n%s\n%s\n' "${OVERLAY_BEGIN}" "${line}" "${OVERLAY_END}"
    } > "${cfg}"
    rm -f "${tmp}"

    logi "Configured ${line} in ${cfg}"
}

enable_service() {
    systemctl daemon-reload
    systemctl enable power-latch.service
    systemctl restart power-latch.service
}

print_summary() {
    local version="unknown"
    local cfg=""
    if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
        version="$(tr -d '[:space:]' < "${INSTALL_DIR}/VERSION")"
    fi
    cfg="$(find_boot_config || true)"

    echo
    echo -e "${blue}Power Latch ${version}${plain}"
    echo "----------------------------------------"
    echo "Application : ${INSTALL_DIR}"
    echo "Config      : ${CONF_FILE}"
    echo "Service     : power-latch.service"
    echo "Command     : power-latch"
    if [[ -n "${cfg}" ]]; then
        echo "Boot config : ${cfg}"
    fi
    echo "Shutdown    : GPIO $(get_conf SHUTDOWN_BUTTON_PIN 27)"
    echo "Reboot      : GPIO $(get_conf REBOOT_BUTTON_PIN 22)"
    echo "Poweroff    : GPIO $(get_conf POWEROFF_PIN 17)"
    echo "----------------------------------------"
    echo
    echo "A reboot is required once so gpio-poweroff can take effect."
    echo -e "After that, run: ${green}power-latch${plain}"
    echo
}

maybe_open_menu() {
    if [[ ! -x "${BIN_FILE}" || ! -r /dev/tty ]]; then
        return 0
    fi
    echo
    read -rp "Open the management menu now? [Y/n]: " answer </dev/tty || true
    if [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]]; then
        exec "${BIN_FILE}" </dev/tty
    fi
}

main() {
    local requested_ref="${1:-${GITHUB_BRANCH}}"
    local source_dir=""
    local work_dir=""
    local already_installed=0

    require_root "$@"

    if [[ -f "${INSTALL_DIR}/power_latch.py" ]]; then
        already_installed=1
        logi "Existing installation found. Updating."
    else
        logi "Installing Power Latch"
    fi

    if ! is_raspberry_pi; then
        if [[ "${POWER_LATCH_FORCE:-0}" == "1" ]]; then
            logw "This does not look like a Raspberry Pi. Continuing because POWER_LATCH_FORCE=1."
        else
            loge "This installer is intended for Raspberry Pi. Set POWER_LATCH_FORCE=1 to continue anyway."
            exit 1
        fi
    fi

    install_dependencies

    if source_dir="$(detect_source_dir)"; then
        logi "Using local source at ${source_dir}"
    else
        work_dir="$(mktemp -d)"
        trap 'rm -rf "${work_dir}"' EXIT
        download_release "${work_dir}" "${requested_ref}"
        source_dir="${work_dir}"
    fi

    install_files "${source_dir}"
    apply_gpio_poweroff
    enable_service

    if systemctl is-active --quiet power-latch.service; then
        if [[ "${already_installed}" -eq 1 ]]; then
            logi "Update complete. Service is running."
        else
            logi "Installation complete. Service is running."
        fi
    else
        logw "Service is not running. Check: journalctl -u power-latch -e"
    fi

    print_summary
    maybe_open_menu
}

main "$@"
