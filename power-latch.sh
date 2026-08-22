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
SERVICE_NAME="power-latch.service"
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

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        loge "Run this command as root."
        exit 1
    fi
}

installed() {
    [[ -f "${INSTALL_DIR}/power_latch.py" && -f "/etc/systemd/system/${SERVICE_NAME}" ]]
}

require_installed() {
    if ! installed; then
        loge "Power Latch is not installed."
        exit 1
    fi
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local answer=""
    read -rp "${prompt} [Default ${default}]: " answer || true
    if [[ -z "${answer}" ]]; then
        answer="${default}"
    fi
    [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

before_menu() {
    echo
    read -rp "Press Enter to return to the menu: " _ || true
    show_menu
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

current_version() {
    if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
        tr -d '[:space:]' < "${INSTALL_DIR}/VERSION"
    else
        echo "unknown"
    fi
}

service_state() {
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e "${green}running${plain}"
    else
        echo -e "${red}stopped${plain}"
    fi
}

autostart_state() {
    if systemctl is-enabled --quiet "${SERVICE_NAME}"; then
        echo -e "${green}enabled${plain}"
    else
        echo -e "${yellow}disabled${plain}"
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

remove_gpio_poweroff() {
    local cfg=""
    local tmp=""

    if ! cfg="$(find_boot_config)"; then
        return 0
    fi

    tmp="$(mktemp)"
    awk -v begin="${OVERLAY_BEGIN}" -v end="${OVERLAY_END}" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        skip { next }
        { print }
    ' "${cfg}" > "${tmp}"
    cat "${tmp}" > "${cfg}"
    rm -f "${tmp}"
    logi "Removed the Power Latch overlay block from ${cfg}"
}

start_service() {
    require_installed
    systemctl start "${SERVICE_NAME}"
    logi "Service started."
}

stop_service() {
    require_installed
    systemctl stop "${SERVICE_NAME}"
    logi "Service stopped."
}

restart_service() {
    require_installed
    systemctl restart "${SERVICE_NAME}"
    logi "Service restarted."
}

show_status() {
    require_installed
    systemctl status "${SERVICE_NAME}" --no-pager
}

enable_autostart() {
    require_installed
    systemctl enable "${SERVICE_NAME}"
    logi "Autostart enabled."
}

disable_autostart() {
    require_installed
    systemctl disable "${SERVICE_NAME}"
    logi "Autostart disabled."
}

show_logs() {
    require_installed
    journalctl -u "${SERVICE_NAME}" -e --no-pager -n 200
}

show_config() {
    require_installed
    local cfg=""
    cfg="$(find_boot_config || true)"

    echo -e "${blue}Power Latch configuration${plain}"
    echo "----------------------------------------"
    echo "Version     : $(current_version)"
    echo "Service     : $(service_state)"
    echo "Autostart   : $(autostart_state)"
    echo "Config file : ${CONF_FILE}"
    echo "Shutdown    : GPIO $(get_conf SHUTDOWN_BUTTON_PIN 27)"
    echo "Reboot      : GPIO $(get_conf REBOOT_BUTTON_PIN 22)"
    echo "Poweroff    : GPIO $(get_conf POWEROFF_PIN 17)"
    echo "Active high : $(get_conf POWEROFF_ACTIVE_HIGH 1)"
    echo "Hold shut   : $(get_conf HOLD_TIME_SHUTDOWN 0.001)s"
    echo "Hold reboot : $(get_conf HOLD_TIME_REBOOT 0.001)s"
    echo "Bounce      : $(get_conf BOUNCE_TIME 0)s"
    echo "Pull up     : $(get_conf BUTTON_PULL_UP 1)"
    if [[ -n "${cfg}" ]]; then
        echo "Boot config : ${cfg}"
        echo
        grep -A2 -F "${OVERLAY_BEGIN}" "${cfg}" || true
    fi
    echo "----------------------------------------"
}

edit_config() {
    require_installed
    local editor="${EDITOR:-nano}"

    "${editor}" "${CONF_FILE}"
    apply_gpio_poweroff
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}"
    logi "Configuration saved. Service restarted."
    logw "Reboot if you changed POWEROFF_PIN or POWEROFF_ACTIVE_HIGH."
}

update_install() {
    require_installed
    if ! confirm "Update Power Latch to the latest version?" "y"; then
        logw "Cancelled."
        return 0
    fi
    bash <(curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/install.sh")
}

uninstall_install() {
    require_installed
    if ! confirm "Uninstall Power Latch from this system?" "n"; then
        logw "Cancelled."
        return 0
    fi

    systemctl stop "${SERVICE_NAME}" || true
    systemctl disable "${SERVICE_NAME}" || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

    remove_gpio_poweroff
    rm -rf "${INSTALL_DIR}"
    rm -f "${BIN_FILE}"

    if confirm "Remove ${CONF_DIR} as well?" "n"; then
        rm -rf "${CONF_DIR}"
        logi "Configuration removed."
    else
        logi "Configuration kept at ${CONF_FILE}"
    fi

    echo
    logi "Power Latch has been uninstalled."
    echo "A reboot is recommended so the gpio-poweroff overlay is fully cleared."
    echo "To install again:"
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/install.sh)${plain}"
    echo
}

show_usage() {
    echo -e "Usage: ${blue}power-latch${plain} [command]"
    echo
    echo "  power-latch            Open the management menu"
    echo "  power-latch start      Start the service"
    echo "  power-latch stop       Stop the service"
    echo "  power-latch restart    Restart the service"
    echo "  power-latch status     Show service status"
    echo "  power-latch enable     Enable start on boot"
    echo "  power-latch disable    Disable start on boot"
    echo "  power-latch log        Show recent logs"
    echo "  power-latch config     Show current configuration"
    echo "  power-latch edit       Edit configuration"
    echo "  power-latch update     Update from GitHub"
    echo "  power-latch uninstall  Remove the installation"
}

show_menu() {
    clear
    echo -e "
================================================
  ${green}Power Latch${plain}
  Version: $(current_version)
================================================
  ${green}0.${plain} Exit
------------------------------------------------
  ${green}1.${plain} Start
  ${green}2.${plain} Stop
  ${green}3.${plain} Restart
  ${green}4.${plain} Status
  ${green}5.${plain} Enable on boot
  ${green}6.${plain} Disable on boot
  ${green}7.${plain} View logs
  ${green}8.${plain} Show configuration
  ${green}9.${plain} Edit configuration
------------------------------------------------
 ${green}10.${plain} Update
 ${green}11.${plain} Uninstall
================================================
  Service   : $(service_state)
  Autostart : $(autostart_state)
================================================
"
    local num=""
    read -rp "Select an option [0-11]: " num || true
    case "${num}" in
        0)
            exit 0
            ;;
        1)
            start_service
            before_menu
            ;;
        2)
            stop_service
            before_menu
            ;;
        3)
            restart_service
            before_menu
            ;;
        4)
            show_status
            before_menu
            ;;
        5)
            enable_autostart
            before_menu
            ;;
        6)
            disable_autostart
            before_menu
            ;;
        7)
            show_logs
            before_menu
            ;;
        8)
            show_config
            before_menu
            ;;
        9)
            edit_config
            before_menu
            ;;
        10)
            update_install
            before_menu
            ;;
        11)
            uninstall_install
            ;;
        *)
            loge "Enter a number from 0 to 11."
            sleep 1
            show_menu
            ;;
    esac
}

require_root

if [[ $# -gt 0 ]]; then
    case "$1" in
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        status)
            show_status
            ;;
        enable)
            enable_autostart
            ;;
        disable)
            disable_autostart
            ;;
        log)
            show_logs
            ;;
        config)
            show_config
            ;;
        edit)
            edit_config
            ;;
        update)
            update_install
            ;;
        uninstall)
            uninstall_install
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
else
    require_installed
    show_menu
fi
