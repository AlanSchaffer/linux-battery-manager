#!/usr/bin/env bash
# ============================================================================
# linux-battery-manager (v2.3.2 Universal Multi-Init)
# Universal Intelligent Battery Charge Limit & Auto-Discharge Manager for Linux
# Natively compatible with Lenovo (ThinkPad), ASUS, and Dell / Alienware
# Multi-Init Support: systemd, OpenRC, Runit, dinit, SysVinit
# Note: HP laptops are currently untested / not officially supported.
#
# Features:
#   - 100% automatic hardware vendor detection
#   - Start and Stop charge threshold control
#   - Smart AC Auto-Discharge (via charge_behaviour)
#   - Multi-Init Daemon Support (systemd, OpenRC, Runit, dinit, SysVinit)
#   - Automatic sleep/resume hook persistence across suspend & hibernate
#   - Centered, Zero-Latency Native TUI (Zero emojis, universal compatibility)
#   - Built-in Bilingual Interface (Portuguese & English with persistent config)
#   - Fast CLI commands (on, off, status, set, menu, lang)
#
# Author: Alan Schaffer
# License: MIT
# ============================================================================

set -euo pipefail

# ========================== GENERAL CONFIGURATION ===========================
readonly SCRIPT_NAME="linux-battery-manager"
readonly SCRIPT_VERSION="2.3.2"

# Default threshold values (%)
DEFAULT_START_THRESHOLD=75
DEFAULT_END_THRESHOLD=80
DEFAULT_AUTO_DISCHARGE=true
DEFAULT_UI_LANG="pt"

# Dynamic battery detection (BAT0, BAT1, BATT, CMB0)
BAT_PATH=""
for bat_candidate in /sys/class/power_supply/BAT* /sys/class/power_supply/CMB*; do
    if [[ -d "${bat_candidate}" ]]; then
        BAT_PATH="${bat_candidate}"
        break
    fi
done
[[ -z "${BAT_PATH}" ]] && BAT_PATH="/sys/class/power_supply/BAT0"
readonly BAT_PATH

readonly START_THRESHOLD_FILE="${BAT_PATH}/charge_control_start_threshold"
readonly END_THRESHOLD_FILE="${BAT_PATH}/charge_control_end_threshold"
readonly BEHAVIOUR_FILE="${BAT_PATH}/charge_behaviour"

# Dell specific paths (dell_wmi_sysman)
readonly WMI_SYSMAN_DIR="/sys/class/firmware-attributes/dell-smbios/attributes"
readonly WMI_MODE_FILE="${WMI_SYSMAN_DIR}/PrimaryBattChargeCfg/current_value"
readonly WMI_START_FILE="${WMI_SYSMAN_DIR}/CustomChargeStart/current_value"
readonly WMI_STOP_FILE="${WMI_SYSMAN_DIR}/CustomChargeStop/current_value"

# Universal installation and configuration paths
readonly CONF_FILE="/etc/linux-battery-manager.conf"
readonly LEGACY_CONF_FILE="/etc/gerenciador-bateria.conf"
readonly SERVICE_NAME="linux-battery-manager.service"
readonly SCRIPT_INSTALL_PATH="/usr/local/bin/linux-battery-manager"
readonly SCRIPT_ALIAS_PATH="/usr/local/bin/linux_battery_manager"
readonly BACKUP_DIR="/etc/linux-battery-manager/backups"
readonly PID_FILE="/run/linux-battery-manager.pid"
readonly MANUAL_DISCHARGE_FLAG="/run/linux-battery-manager.manual_discharge"

# Multi-Init system paths
readonly INIT_SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}"
readonly INIT_OPENRC_SERVICE="/etc/init.d/linux-battery-manager"
readonly INIT_RUNIT_SERVICE_DIR="/etc/sv/linux-battery-manager"
readonly INIT_RUNIT_ENABLE_DIR_VAR="/var/service"
readonly INIT_RUNIT_ENABLE_DIR_ETC="/etc/service"
readonly INIT_RUNIT_ENABLE_DIR_RUN="/run/runit/service"
readonly INIT_DINIT_SERVICE="/etc/dinit.d/linux-battery-manager"
readonly INIT_SYSV_SERVICE="/etc/init.d/linux-battery-manager"
readonly SLEEP_HOOK_DIR_SYSTEMD="/usr/lib/systemd/system-sleep"
readonly SLEEP_HOOK_DIR_ELOGIND_LIB="/lib/elogind/system-sleep"
readonly SLEEP_HOOK_DIR_ELOGIND_ETC="/etc/elogind/system-sleep"
readonly SLEEP_HOOK_DIR_PM="/etc/pm/sleep.d"

# Legacy services and binaries for clean migration
readonly LEGACY_SERVICES=(
    "gerenciador-bateria.service"
    "thinkpad-battery-charge-limit.service"
    "asus-battery-charge-limit.service"
    "dell-battery-charge-limit.service"
)
readonly LEGACY_BINARIES=(
    "/usr/local/bin/gerenciador-bateria"
    "/usr/local/bin/gerenciador_bateria"
)

TUI_ACTIVE=0

# ========================== VENDOR DETECTION ================================

detect_vendor() {
    local vendor
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
    case "${vendor,,}" in
        (*lenovo*)           echo "lenovo" ;;
        (*asus*|*asustek*)   echo "asus" ;;
        (*dell*|*alienware*) echo "dell" ;;
        (*)                  echo "generic" ;;
    esac
}

detect_vendor_display() {
    local v
    v=$(detect_vendor)
    case "${v}" in
        (lenovo)  echo "Lenovo ThinkPad" ;;
        (asus)    echo "ASUS" ;;
        (dell)    echo "Dell / Alienware" ;;
        (generic)
            if [[ "${UI_LANG:-pt}" == "en" ]]; then
                echo "Generic / Other"
            else
                echo "Generico / Outro"
            fi
            ;;
    esac
}

# ========================== LOAD / SAVE CONFIGURATION =======================

load_config() {
    START_THRESHOLD="${DEFAULT_START_THRESHOLD}"
    END_THRESHOLD="${DEFAULT_END_THRESHOLD}"
    AUTO_DISCHARGE="${DEFAULT_AUTO_DISCHARGE}"
    DELL_MODE="custom"
    UI_LANG="${DEFAULT_UI_LANG}"

    local target_conf=""
    if [[ -f "${CONF_FILE}" ]]; then
        target_conf="${CONF_FILE}"
    elif [[ -f "${LEGACY_CONF_FILE}" ]]; then
        target_conf="${LEGACY_CONF_FILE}"
    fi

    if [[ -n "${target_conf}" ]]; then
        while IFS='=' read -r key val; do
            [[ "${key}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key}" ]] && continue
            key="${key//[[:space:]]/}"
            val="${val#\"}"
            val="${val%\"}"
            val="${val#\'}"
            val="${val%\'}"
            case "${key}" in
                (START_THRESHOLD) [[ "${val}" =~ ^[0-9]+$ ]] && START_THRESHOLD="${val}" ;;
                (END_THRESHOLD)   [[ "${val}" =~ ^[0-9]+$ ]] && END_THRESHOLD="${val}" ;;
                (AUTO_DISCHARGE)  [[ "${val}" == "true" || "${val}" == "false" ]] && AUTO_DISCHARGE="${val}" ;;
                (DELL_MODE)       DELL_MODE="${val}" ;;
                (UI_LANG)         UI_LANG="${val}" ;;
            esac
        done < "${target_conf}"
    fi

    if [[ "${UI_LANG}" != "en" && "${UI_LANG}" != "pt" ]]; then
        UI_LANG="pt"
    fi
}

save_config() {
    local start_val="${1:-${START_THRESHOLD}}"
    local end_val="${2:-${END_THRESHOLD}}"
    local auto_discharge="${3:-${AUTO_DISCHARGE:-true}}"
    local dell_mode="${4:-${DELL_MODE:-custom}}"
    local ui_lang="${5:-${UI_LANG:-pt}}"

    mkdir -p "$(dirname "${CONF_FILE}")"
    cat > "${CONF_FILE}" << EOF
# Configuration for Universal Linux Battery Manager
START_THRESHOLD=${start_val}
END_THRESHOLD=${end_val}
AUTO_DISCHARGE=${auto_discharge}
DELL_MODE="${dell_mode}"
UI_LANG="${ui_lang}"
EOF
    chmod 644 "${CONF_FILE}"
}

# ========================== INTERNATIONALIZATION (PT / EN) ==================

setup_strings() {
    if [[ "${UI_LANG:-pt}" == "en" ]]; then
        L_TITLE="Universal Linux Battery Manager"
        L_BAT="Battery"
        L_AC_ON="AC Connected"
        L_AC_OFF="On Battery"
        L_LIMITS="Limits"
        L_ENABLED="ENABLED"
        L_DISABLED="DISABLED"
        L_MENU_PROMPT="Select an option (Arrows Up/Down, 0-6, or ESC to exit):"
        L_OPT1="1 [i] View Detailed Battery Status"
        if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
            L_OPT2="2 [*] Disable Smart Auto-Discharge"
        else
            L_OPT2="2 [*] Enable Smart Auto-Discharge"
        fi
        L_OPT3="3 [#] Change Charge Limits (${START_THRESHOLD}% - ${END_THRESHOLD}%)"
        L_OPT4="4 [!] Force Immediate Discharge on AC"
        L_OPT5="5 [~] Restore Factory Defaults (100%)"
        L_OPT6="6 [L] Language / Idioma: [English -> Portugues]"
        L_OPT0="0 [X] Exit Program"
        L_FOOTER_MENU="[ENTER] Select                         [ESC / q] Exit"
        L_FOOTER_MSG="        Press [ENTER] or [ESC] to continue"
        L_FOOTER_INPUT="      [ENTER] Confirm            [ESC] Cancel / Back"
        L_FOOTER_STATUS="      [ENTER] Back to Menu               [ESC / q] Exit"
        L_STATUS_TITLE="Battery Status"
        L_VALUE_LABEL="Value"
        L_YES="Yes"
        L_NO="No (ESC)"
        L_MSG_AD_OFF_TITLE="Auto-Discharge Disabled"
        L_MSG_AD_OFF_BODY="Smart Auto-Discharge on AC power has been DISABLED."
        L_MSG_AD_ON_TITLE="Auto-Discharge Enabled"
        L_MSG_AD_ON_BODY=$(printf "Smart Auto-Discharge has been ENABLED!\nIf booted at 100%% on AC, it drains down to %s%%." "${START_THRESHOLD}")
        L_IN_START_TITLE="Start Threshold (Resume)"
        L_IN_START_PROMPT="Enter % to START charging (e.g. 78):"
        L_IN_END_TITLE="Stop Threshold (Limit)"
        L_IN_END_PROMPT="Enter % to STOP charging (e.g. 80, 90):"
        L_MSG_LIM_OK_TITLE="Success"
        L_MSG_LIM_ERR_TITLE="Validation Error"
        L_MSG_FD_OK_TITLE="Immediate Discharge"
        L_MSG_FD_OK_BODY="Force-discharge mode activated on AC down to ${START_THRESHOLD}%."
        L_MSG_FD_ERR_TITLE="Notice"
        L_MSG_FD_ERR_BODY="Could not activate force-discharge (unsupported or already <= ${START_THRESHOLD}%)."
        L_YN_RESTORE_TITLE="Confirm Restore"
        L_YN_RESTORE_PROMPT="Restore charge thresholds to factory defaults (100%)?"
        L_MSG_RESTORE_TITLE="Restored"
        L_MSG_RESTORE_BODY="Thresholds restored to 100% and saved to configuration."
    else
        L_TITLE="Gerenciador de Bateria Universal"
        L_BAT="Bateria"
        L_AC_ON="Tomada Conectada"
        L_AC_OFF="Na Bateria"
        L_LIMITS="Limites"
        L_ENABLED="ATIVADO"
        L_DISABLED="DESATIVADO"
        L_MENU_PROMPT="Escolha uma opcao (Setas Cima/Baixo, 0-6 ou ESC para sair):"
        L_OPT1="1 [i] Ver Status Detalhado da Bateria"
        if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
            L_OPT2="2 [*] Desativar Descarga Inteligente"
        else
            L_OPT2="2 [*] Ativar Descarga Inteligente"
        fi
        L_OPT3="3 [#] Alterar Limites de Carga (${START_THRESHOLD}% - ${END_THRESHOLD}%)"
        L_OPT4="4 [!] Forcar Descarga Imediata na Tomada"
        L_OPT5="5 [~] Restaurar Padrao de Fabrica (100%)"
        L_OPT6="6 [L] Idioma / Language: [Portugues -> English]"
        L_OPT0="0 [X] Sair do Programa"
        L_FOOTER_MENU="[ENTER] Selecionar                     [ESC / q] Sair"
        L_FOOTER_MSG="        Pressione [ENTER] ou [ESC] para continuar"
        L_FOOTER_INPUT="      [ENTER] Confirmar          [ESC] Cancelar / Voltar"
        L_FOOTER_STATUS="      [ENTER] Voltar ao Menu             [ESC / q] Sair"
        L_STATUS_TITLE="Status da Bateria"
        L_VALUE_LABEL="Valor"
        L_YES="Sim"
        L_NO="Nao (ESC)"
        L_MSG_AD_OFF_TITLE="Auto-Discharge Desativado"
        L_MSG_AD_OFF_BODY="A Descarga Inteligente na tomada foi DESATIVADA."
        L_MSG_AD_ON_TITLE="Auto-Discharge Ativado"
        L_MSG_AD_ON_BODY=$(printf "A Descarga Inteligente foi ATIVADA!\nSe ligar em 100%%, drenara na tomada ate %s%%." "${START_THRESHOLD}")
        L_IN_START_TITLE="Limite Inicial de Carga"
        L_IN_START_PROMPT="Digite a % para INICIAR a recarga (ex: 78):"
        L_IN_END_TITLE="Limite Maximo de Carga"
        L_IN_END_PROMPT="Digite a % para PARAR a recarga (ex: 80, 90):"
        L_MSG_LIM_OK_TITLE="Sucesso"
        L_MSG_LIM_ERR_TITLE="Erro de Validacao"
        L_MSG_FD_OK_TITLE="Descarga Imediata"
        L_MSG_FD_OK_BODY="Modo force-discharge ativado na tomada ate atingir ${START_THRESHOLD}%."
        L_MSG_FD_ERR_TITLE="Aviso"
        L_MSG_FD_ERR_BODY="Nao foi possivel ativar a descarga (nao suportado ou carga <= ${START_THRESHOLD}%)."
        L_YN_RESTORE_TITLE="Confirmar Restauracao"
        L_YN_RESTORE_PROMPT="Deseja restaurar os limites para o padrao de fabrica (100%)?"
        L_MSG_RESTORE_TITLE="Restaurado"
        L_MSG_RESTORE_BODY="Limites restaurados para 100% e salvos na configuracao."
    fi
}

# ========================== HELPER FUNCTIONS ================================

log_info() {
    echo "[INFO] $*"
    logger -t "${SCRIPT_NAME}" --id=$$ "INFO: $*" 2>/dev/null || true
}

log_warn() {
    echo "[WARN] $*" >&2
    logger -t "${SCRIPT_NAME}" --id=$$ -p user.warning "WARN: $*" 2>/dev/null || true
}

log_error() {
    echo "[ERROR] $*" >&2
    logger -t "${SCRIPT_NAME}" --id=$$ -p user.err "ERROR: $*" 2>/dev/null || true
}

cleanup_tui() {
    if (( TUI_ACTIVE == 1 )); then
        printf '\033[?25h\033[0m\033[2J\033[H' > /dev/tty 2>/dev/null || true
        TUI_ACTIVE=0
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        cleanup_tui
        if [[ "${UI_LANG:-pt}" == "en" ]]; then
            log_error "This command requires root privileges. Please run with 'sudo'."
        else
            log_error "Este comando requer privilegios de root. Execute com 'sudo'."
        fi
        exit 1
    fi
}

is_pid_matching() {
    local pid="$1"
    [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1
    [[ "${pid}" != "$$" ]] || return 1
    if [[ -d "/proc/${pid}" ]]; then
        if [[ -f "/proc/${pid}/cmdline" ]]; then
            grep -qa -E "linux-battery-manager|${SCRIPT_NAME}" "/proc/${pid}/cmdline" 2>/dev/null && return 0
            return 1
        fi
        return 0
    fi
    kill -0 "${pid}" 2>/dev/null && return 0
    return 1
}

is_ac_online() {
    for psy in /sys/class/power_supply/*; do
        if [[ -d "${psy}" ]]; then
            local type online
            type=$(cat "${psy}/type" 2>/dev/null || echo "")
            online=$(cat "${psy}/online" 2>/dev/null || echo "0")
            if [[ "${online}" == "1" && "${type,,}" != "battery" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

is_force_discharge_supported() {
    [[ -f "${BEHAVIOUR_FILE}" ]] && grep -q "force-discharge" "${BEHAVIOUR_FILE}" 2>/dev/null
}

get_charge_behaviour() {
    if [[ -f "${BEHAVIOUR_FILE}" ]]; then
        grep -o '\[[^]]*\]' "${BEHAVIOUR_FILE}" 2>/dev/null | tr -d '[]' || echo "auto"
    else
        echo "N/A"
    fi
}

set_charge_behaviour() {
    local behaviour="$1"
    if is_force_discharge_supported; then
        if echo "${behaviour}" > "${BEHAVIOUR_FILE}" 2>/dev/null; then
            log_info "Charge behaviour set to: ${behaviour}"
        else
            log_warn "Failed to set behaviour to ${behaviour}. Kernel might be busy."
        fi
    else
        log_warn "charge_behaviour unavailable or force-discharge unsupported on this machine."
    fi
}

read_battery_energy() {
    local mode="$1"
    if [[ -f "${BAT_PATH}/energy_${mode}" ]]; then
        awk '{printf "%.2f Wh", $1/1000000}' "${BAT_PATH}/energy_${mode}" 2>/dev/null || echo "?"
    elif [[ -f "${BAT_PATH}/charge_${mode}" ]]; then
        awk '{printf "%.2f Ah", $1/1000000}' "${BAT_PATH}/charge_${mode}" 2>/dev/null || echo "?"
    else
        echo "N/A"
    fi
}

detect_dell_backend() {
    if command -v smbios-battery-ctl >/dev/null 2>&1; then
        echo "libsmbios"
    elif [[ -f "${WMI_MODE_FILE}" ]]; then
        echo "dell_wmi_sysman"
    elif [[ -e "${END_THRESHOLD_FILE}" ]]; then
        echo "sysfs"
    elif command -v cctk >/dev/null 2>&1; then
        echo "cctk"
    else
        echo "none"
    fi
}

# Safe ordered sysfs threshold writer to avoid kernel EINVAL when start >= end
write_sysfs_thresholds() {
    local start_val="$1"
    local end_val="$2"

    if [[ -e "${START_THRESHOLD_FILE}" && -e "${END_THRESHOLD_FILE}" ]]; then
        local cur_start="0"
        cur_start=$(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo "0")
        [[ "${cur_start}" =~ ^[0-9]+$ ]] || cur_start="0"

        if (( end_val < cur_start )); then
            echo "${start_val}" > "${START_THRESHOLD_FILE}" 2>/dev/null || return 1
            echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || return 1
        else
            echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || return 1
            echo "${start_val}" > "${START_THRESHOLD_FILE}" 2>/dev/null || return 1
        fi
        return 0
    elif [[ -e "${END_THRESHOLD_FILE}" ]]; then
        echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || return 1
        return 0
    fi

    return 1
}

# Calculate safe default start threshold for single-limit inputs
calculate_default_start() {
    local end_val="$1"
    local vendor
    vendor=$(detect_vendor)

    if ! [[ "${end_val}" =~ ^[0-9]+$ ]]; then
        echo "0"
        return
    fi

    case "${vendor}" in
        (asus)
            echo "0"
            ;;
        (dell)
            local s=$(( end_val - 5 ))
            if (( s < 50 )); then s=50; fi
            if (( s >= end_val )); then s=$(( end_val - 1 )); fi
            echo "${s}"
            ;;
        (*)
            local s=$(( end_val - 2 ))
            if (( s < 1 )); then s=1; fi
            echo "${s}"
            ;;
    esac
}

# Kickstart charging if battery is below target end threshold on AC but held in hysteresis idle
kickstart_charging() {
    local target_start="${1:-${START_THRESHOLD}}"
    local target_end="${2:-${END_THRESHOLD}}"

    if ! is_ac_online; then
        return 0
    fi

    if [[ ! -e "${START_THRESHOLD_FILE}" || ! -e "${END_THRESHOLD_FILE}" ]]; then
        return 0
    fi

    # Factory default restore does not need kickstart
    if (( target_start == 0 && target_end == 100 )); then
        return 0
    fi

    local cur_cap cur_status cur_start
    cur_cap=$(cat "${BAT_PATH}/capacity" 2>/dev/null || echo "")
    cur_status=$(cat "${BAT_PATH}/status" 2>/dev/null || echo "")
    cur_start=$(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo "0")

    [[ "${cur_cap}" =~ ^[0-9]+$ ]] || return 0
    [[ "${cur_start}" =~ ^[0-9]+$ ]] || cur_start="0"
    [[ "${target_end}" =~ ^[0-9]+$ ]] || target_end="100"

    # Only kickstart if plugged in, below end threshold, and sitting idle due to hysteresis (cap >= start)
    if (( cur_cap < target_end && cur_cap >= cur_start )) && \
       [[ "${cur_status}" == "Not charging" || "${cur_status}" == "Unknown" || "${cur_status}" == "Idle" ]]; then
        local temp_start=$(( target_end > 1 ? target_end - 1 : 1 ))
        log_info "Battery below limit (${cur_cap}% < ${target_end}%) in hysteresis hold. Kickstarting charge..."

        # Temporarily raise start threshold to trigger EC hardware charging circuit
        echo "${temp_start}" > "${START_THRESHOLD_FILE}" 2>/dev/null || true

        local i
        for (( i=0; i<3; i++ )); do
            sleep 1
            cur_status=$(cat "${BAT_PATH}/status" 2>/dev/null || echo "")
            if [[ "${cur_status}" == "Charging" ]]; then
                log_info "Charge kickstart confirmed: battery is now Charging."
                break
            fi
        done

        # Restore configured start threshold. Once initiated, EC hardware continues charging until target_end
        echo "${target_start}" > "${START_THRESHOLD_FILE}" 2>/dev/null || true
        log_info "Start threshold restored to ${target_start}% (charging continues up to ${target_end}%)."
    fi
}

# ========================== HARDWARE CHECK ==================================

check_hardware() {
    load_config
    local errors=0
    local vendor
    vendor=$(detect_vendor)

    echo "==============================================================="
    if [[ "${UI_LANG}" == "en" ]]; then
        echo "  Hardware Check — ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    else
        echo "  Verificacao de Hardware — ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    fi
    echo "==============================================================="
    echo

    local dmi_vendor dmi_model
    dmi_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
    dmi_model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")
    echo "System / Sistema: ${dmi_vendor} (${dmi_model})"
    echo "Vendor / Fabricante: $(detect_vendor_display)"
    echo

    if [[ -d "${BAT_PATH}" ]]; then
        echo "[OK] Battery found: ${BAT_PATH}"
        echo "     Manufacturer: $(cat "${BAT_PATH}/manufacturer" 2>/dev/null || echo 'unknown')"
        echo "     Model:        $(cat "${BAT_PATH}/model_name" 2>/dev/null || echo 'unknown')"
        echo "     Technology:   $(cat "${BAT_PATH}/technology" 2>/dev/null || echo 'unknown')"
        echo "     Capacity:     $(cat "${BAT_PATH}/capacity" 2>/dev/null || echo '?')%"
        echo "     Status:       $(cat "${BAT_PATH}/status" 2>/dev/null || echo 'unknown')"
        echo "     Cycles:       $(cat "${BAT_PATH}/cycle_count" 2>/dev/null || echo '?')"
    else
        echo "[ERR] Battery NOT found at ${BAT_PATH}"
        errors=$(( errors + 1 ))
    fi
    echo

    if [[ -e "${END_THRESHOLD_FILE}" ]]; then
        echo "[OK] charge_control_end_threshold AVAILABLE (Value: $(cat "${END_THRESHOLD_FILE}" 2>/dev/null || echo '?')%)"
    else
        if [[ "${vendor}" == "dell" && "$(detect_dell_backend)" != "none" ]]; then
            echo "[INFO] charge_control_end_threshold available via Dell SMBIOS/WMI"
        else
            echo "[ERR] charge_control_end_threshold NOT available"
            errors=$(( errors + 1 ))
        fi
    fi

    if [[ -e "${START_THRESHOLD_FILE}" ]]; then
        echo "[OK] charge_control_start_threshold AVAILABLE (Value: $(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo '?')%)"
    else
        if [[ "${vendor}" == "asus" ]]; then
            echo "[INFO] charge_control_start_threshold managed automatically by ASUS firmware (~75%)"
        else
            echo "[INFO] charge_control_start_threshold not directly exposed"
        fi
    fi
    echo

    if is_force_discharge_supported; then
        echo "[OK] Smart Auto-Discharge (force-discharge) SUPPORTED by hardware!"
        echo "     Current mode: $(get_charge_behaviour)"
    else
        echo "[INFO] force-discharge not natively supported by current hardware"
    fi
    echo

    echo "==============================================================="
    if (( errors == 0 )); then
        echo "  [OK] Hardware 100% compatible!"
    else
        echo "  [WARN] Warnings or errors found. Check messages above."
    fi
    echo "==============================================================="
    echo

    return $(( errors > 0 ? 1 : 0 ))
}

# ========================== APPLY THRESHOLDS ================================

apply_thresholds() {
    local start_val="$1"
    local end_val="$2"
    local vendor
    vendor=$(detect_vendor)

    if ! [[ "${start_val}" =~ ^[0-9]+$ ]] || ! [[ "${end_val}" =~ ^[0-9]+$ ]]; then
        log_error "Invalid values: start='${start_val}', end='${end_val}'. Must be integers."
        return 1
    fi

    case "${vendor}" in
        (lenovo)
            if (( start_val < 0 || start_val > 99 || end_val < 1 || end_val > 100 )); then
                log_error "Invalid limits for ThinkPad (start: 0-99, end: 1-100)."
                return 1
            fi
            if (( start_val > 0 && start_val >= end_val )); then
                log_error "start_threshold (${start_val}%) must be less than end_threshold (${end_val}%)."
                return 1
            fi

            if ! write_sysfs_thresholds "${start_val}" "${end_val}"; then
                log_error "Failed to write threshold files in ${BAT_PATH}."
                return 1
            fi
            log_info "[OK] ThinkPad limits applied: Start=${start_val}% | Stop=${end_val}%"
            kickstart_charging "${start_val}" "${end_val}"
            ;;

        (asus)
            if (( end_val < 1 || end_val > 100 )); then
                log_error "Invalid ASUS limit (1-100)."
                return 1
            fi
            if [[ -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || return 1
                log_info "[OK] ASUS limit applied: Stop=${end_val}% (Resume ~${start_val}%)"
            else
                log_error "File ${END_THRESHOLD_FILE} not found."
                return 1
            fi
            ;;

        (dell)
            # Allow 0/100 standard mode restoration on Dell
            if (( start_val == 0 && end_val == 100 )); then
                local dell_be
                dell_be=$(detect_dell_backend)
                case "${dell_be}" in
                    (libsmbios)
                        smbios-battery-ctl --set-charging-mode=standard >/dev/null 2>&1 || true
                        ;;
                    (dell_wmi_sysman)
                        [[ -f "${WMI_MODE_FILE}" ]] && echo "Standard" > "${WMI_MODE_FILE}" 2>/dev/null || true
                        ;;
                    (sysfs)
                        write_sysfs_thresholds 0 100 || true
                        ;;
                    (cctk)
                        cctk --PrimaryBattChargeCfg=Standard >/dev/null 2>&1 || true
                        ;;
                esac
                log_info "[OK] Dell standard charging mode (100%) applied."
                return 0
            fi

            if (( start_val < 50 || start_val > 95 || end_val < 55 || end_val > 100 || start_val >= end_val )); then
                log_error "Invalid Dell limits (Start: 50-95, Stop: 55-100, Start < Stop)."
                return 1
            fi
            local dell_be
            dell_be=$(detect_dell_backend)
            case "${dell_be}" in
                (libsmbios)
                    if ! { smbios-battery-ctl --set-custom-charge-interval "${start_val}" "${end_val}" >/dev/null 2>&1 || \
                           smbios-battery-ctl "--set-custom-charge-interval=${start_val}-${end_val}" >/dev/null 2>&1; }; then
                        log_error "Failed to set Dell custom charge interval via libsmbios."
                        return 1
                    fi
                    smbios-battery-ctl --set-charging-mode=custom >/dev/null 2>&1 || true
                    log_info "[OK] Dell limits applied via libsmbios (${start_val}% - ${end_val}%)."
                    ;;
                (dell_wmi_sysman)
                    if [[ -f "${WMI_START_FILE}" && -f "${WMI_STOP_FILE}" && -f "${WMI_MODE_FILE}" ]]; then
                        echo "Custom" > "${WMI_MODE_FILE}" 2>/dev/null || return 1
                        echo "${start_val}" > "${WMI_START_FILE}" 2>/dev/null || return 1
                        echo "${end_val}" > "${WMI_STOP_FILE}" 2>/dev/null || return 1
                        log_info "[OK] Dell limits applied via dell_wmi_sysman."
                    else
                        log_error "Dell WMI sysman files not found."
                        return 1
                    fi
                    ;;
                (sysfs)
                    if ! write_sysfs_thresholds "${start_val}" "${end_val}"; then
                        log_error "Failed to apply Dell limits via sysfs."
                        return 1
                    fi
                    log_info "[OK] Dell limits applied via sysfs."
                    ;;
                (cctk)
                    if ! cctk "--PrimaryBattChargeCfg=Custom:${start_val}-${end_val}" >/dev/null 2>&1; then
                        log_error "Failed to apply Dell limits via cctk."
                        return 1
                    fi
                    log_info "[OK] Dell limits applied via cctk."
                    ;;
                (*)
                    log_error "No supported Dell battery backend available."
                    return 1
                    ;;
            esac
            ;;

        (*)
            if (( start_val < 0 || start_val > 99 || end_val < 1 || end_val > 100 || (start_val > 0 && start_val >= end_val) )); then
                log_error "Invalid limits (start: 0-99, end: 1-100, start < end)."
                return 1
            fi
            if ! write_sysfs_thresholds "${start_val}" "${end_val}"; then
                log_error "Threshold files not found or not writable in ${BAT_PATH}."
                return 1
            fi
            log_info "[OK] Generic limits applied: ${start_val}% - ${end_val}%"
            kickstart_charging "${start_val}" "${end_val}"
            ;;
    esac

    return 0
}

restore_defaults() {
    local update_conf="${1:-true}"
    log_info "Restoring factory default settings (100%)..."

    rm -f "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
    if [[ -e "${BEHAVIOUR_FILE}" ]]; then
        echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
    fi

    local vendor
    vendor=$(detect_vendor)

    case "${vendor}" in
        (dell)
            if command -v smbios-battery-ctl >/dev/null 2>&1; then
                smbios-battery-ctl --set-charging-mode=standard >/dev/null 2>&1 || true
            elif [[ -f "${WMI_MODE_FILE}" ]]; then
                echo "Standard" > "${WMI_MODE_FILE}" 2>/dev/null || true
            elif command -v cctk >/dev/null 2>&1; then
                cctk --PrimaryBattChargeCfg=Standard >/dev/null 2>&1 || true
            fi
            ;;
    esac

    write_sysfs_thresholds 0 100 2>/dev/null || true

    if [[ "${update_conf}" == "true" && -f "${CONF_FILE}" ]]; then
        load_config
        save_config 0 100 "${AUTO_DISCHARGE}" "standard" "${UI_LANG}"
    fi

    log_info "[OK] Thresholds restored to factory default (100%)."
}

# ========================== SMART AUTO-DISCHARGE DAEMON =====================

run_daemon() {
    check_root
    log_info "Starting ${SCRIPT_NAME} continuous monitoring daemon..."

    local discharge_in_progress=0
    local sleep_pid=""
    local last_kickstart_cap=""

    echo $$ > "${PID_FILE}" 2>/dev/null || true

    cleanup_daemon() {
        if [[ -n "${sleep_pid}" ]]; then
            kill -TERM "${sleep_pid}" 2>/dev/null || true
        fi
        rm -f "${PID_FILE}" "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
        log_info "Daemon stopped. Ensuring 'auto' charge behaviour..."
        if is_force_discharge_supported; then
            echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
        fi
        exit 0
    }
    trap cleanup_daemon SIGINT SIGTERM SIGHUP EXIT

    reload_daemon() {
        discharge_in_progress=0
        last_kickstart_cap=""
        if [[ -n "${sleep_pid}" ]]; then
            kill -TERM "${sleep_pid}" 2>/dev/null || true
        fi
    }
    trap reload_daemon SIGUSR1

    load_config
    apply_thresholds "${START_THRESHOLD}" "${END_THRESHOLD}" || true

    local cur_cap=""
    local cur_status=""
    local cur_sys_end=""
    local current_behaviour=""

    while true; do
        load_config

        cur_cap=$(cat "${BAT_PATH}/capacity" 2>/dev/null || echo "")
        cur_status=$(cat "${BAT_PATH}/status" 2>/dev/null || echo "")

        if [[ -n "${cur_cap}" && "${cur_cap}" =~ ^[0-9]+$ ]]; then
            if [[ -e "${END_THRESHOLD_FILE}" ]]; then
                cur_sys_end=$(cat "${END_THRESHOLD_FILE}" 2>/dev/null || echo "")
                if [[ "${cur_sys_end}" != "${END_THRESHOLD}" ]]; then
                    log_info "Sysfs threshold changed (${cur_sys_end} -> ${END_THRESHOLD}). Re-applying..."
                    apply_thresholds "${START_THRESHOLD}" "${END_THRESHOLD}" || true
                fi
            fi

            if is_force_discharge_supported; then
                current_behaviour=$(get_charge_behaviour)
            else
                current_behaviour="auto"
            fi

            if is_ac_online; then
                if [[ -n "${last_kickstart_cap}" && "${last_kickstart_cap}" != "${cur_cap}" ]]; then
                    last_kickstart_cap=""
                fi

                # Kickstart charging if held in hysteresis idle on AC below target end threshold
                if [[ ${discharge_in_progress} -eq 0 && ! -f "${MANUAL_DISCHARGE_FLAG}" ]] && \
                   [[ "${current_behaviour}" != "force-discharge" ]] && \
                   [[ "${cur_status}" == "Not charging" || "${cur_status}" == "Unknown" || "${cur_status}" == "Idle" ]] && \
                   (( cur_cap < END_THRESHOLD )); then
                    local cur_sys_start
                    cur_sys_start=$(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo "0")
                    [[ "${cur_sys_start}" =~ ^[0-9]+$ ]] || cur_sys_start="0"
                    if (( cur_cap >= cur_sys_start )) && [[ "${last_kickstart_cap}" != "${cur_cap}" ]]; then
                        kickstart_charging "${START_THRESHOLD}" "${END_THRESHOLD}"
                        last_kickstart_cap="${cur_cap}"
                    fi
                fi
            else
                last_kickstart_cap=""
            fi

            if is_force_discharge_supported; then

                # Safety guard: never allow force-discharge below 20%
                if (( cur_cap <= 20 )) && [[ "${current_behaviour}" == "force-discharge" ]]; then
                    log_warn "SAFETY: Low battery (${cur_cap}%). Aborting force-discharge."
                    set_charge_behaviour "auto"
                    discharge_in_progress=0
                    rm -f "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
                elif [[ -f "${MANUAL_DISCHARGE_FLAG}" ]]; then
                    local target_start=$(( START_THRESHOLD > 20 ? START_THRESHOLD : 20 ))
                    if ! is_ac_online || (( cur_cap <= target_start )); then
                        log_info "Manual discharge target (${target_start}%) reached or AC unplugged. Returning to 'auto'."
                        set_charge_behaviour "auto"
                        discharge_in_progress=0
                        rm -f "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
                    elif [[ "${current_behaviour}" != "force-discharge" ]]; then
                        set_charge_behaviour "force-discharge"
                    fi
                elif [[ "${AUTO_DISCHARGE:-true}" == "true" ]] && (( END_THRESHOLD < 100 && START_THRESHOLD > 0 )); then
                    if is_ac_online; then
                        if (( cur_cap > END_THRESHOLD )); then
                            if [[ "${current_behaviour}" != "force-discharge" ]]; then
                                log_info "Battery above threshold (${cur_cap}% > ${END_THRESHOLD}%)."
                                log_info "Activating 'force-discharge': draining on AC down to ${START_THRESHOLD}%..."
                                set_charge_behaviour "force-discharge"
                                discharge_in_progress=1
                            fi
                        elif (( cur_cap <= START_THRESHOLD )); then
                            if [[ "${current_behaviour}" == "force-discharge" || ${discharge_in_progress} -eq 1 ]]; then
                                log_info "Start threshold reached (${cur_cap}% <= ${START_THRESHOLD}%)."
                                log_info "Restoring 'auto' mode: recharging to ${END_THRESHOLD}% and resting on AC."
                                set_charge_behaviour "auto"
                                discharge_in_progress=0
                            fi
                        fi
                    else
                        if [[ "${current_behaviour}" == "force-discharge" ]]; then
                            set_charge_behaviour "auto"
                        fi
                        if (( cur_cap <= START_THRESHOLD )); then
                            discharge_in_progress=0
                        fi
                    fi
                else
                    if [[ "${current_behaviour}" == "force-discharge" ]]; then
                        set_charge_behaviour "auto"
                    fi
                    discharge_in_progress=0
                fi
            fi
        fi

        sleep 20 &
        sleep_pid=$!
        wait "${sleep_pid}" 2>/dev/null || true
        sleep_pid=""
    done
}

stop_daemon_action() {
    rm -f "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
    if is_force_discharge_supported; then
        echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
    fi
    log_info "Service stopped. Charge behaviour kept in 'auto'."
}

# ========================== ENABLE / DISABLE AUTO-DISCHARGE =================

set_auto_discharge_cmd() {
    check_root
    load_config
    local choice="${1:-toggle}"

    case "${choice,,}" in
        (on|enable|true|1|ativar|ativado)
            save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "true" "${DELL_MODE}" "${UI_LANG}"
            log_info "[OK] Smart Auto-Discharge ENABLED."
            ;;
        (off|disable|false|0|desativar|desativado)
            save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "false" "${DELL_MODE}" "${UI_LANG}"
            rm -f "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
            if is_force_discharge_supported; then
                echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
            fi
            if [[ -f "${PID_FILE}" ]]; then
                local d_pid
                d_pid=$(cat "${PID_FILE}" 2>/dev/null || true)
                if [[ -n "${d_pid}" ]] && is_pid_matching "${d_pid}"; then
                    kill -USR1 "${d_pid}" 2>/dev/null || true
                fi
            fi
            log_info "[OK] Smart Auto-Discharge DISABLED."
            ;;
        (toggle)
            if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
                set_auto_discharge_cmd "off"
            else
                set_auto_discharge_cmd "on"
            fi
            ;;
        (status)
            log_info "Auto-Discharge Status: ${AUTO_DISCHARGE}"
            ;;
        (*)
            log_error "Invalid option: '${choice}'. Use 'on' or 'off'."
            return 1
            ;;
    esac
}

# ========================== LANGUAGE SWITCH COMMAND =========================

set_language_cmd() {
    check_root
    load_config
    local next_lang="${1:-toggle}"
    case "${next_lang,,}" in
        (en|english|ingles)
            UI_LANG="en"
            ;;
        (pt|pt-br|portugues|portuguese)
            UI_LANG="pt"
            ;;
        (toggle)
            if [[ "${UI_LANG}" == "en" ]]; then
                UI_LANG="pt"
            else
                UI_LANG="en"
            fi
            ;;
        (*)
            log_error "Invalid language: '${next_lang}'. Use 'pt' or 'en'."
            return 1
            ;;
    esac
    save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "${AUTO_DISCHARGE}" "${DELL_MODE}" "${UI_LANG}"
    log_info "[OK] Interface language set to: ${UI_LANG}"
}

# ========================== MANUAL DISCHARGE ================================

force_discharge_cmd() {
    check_root
    load_config

    if ! is_force_discharge_supported; then
        log_error "Current hardware does not support 'force-discharge' via sysfs."
        return 1
    fi

    local cur_cap
    cur_cap=$(cat "${BAT_PATH}/capacity" 2>/dev/null || echo "0")
    local target_start=$(( START_THRESHOLD > 20 ? START_THRESHOLD : 20 ))

    if (( cur_cap <= target_start )); then
        log_info "Battery is already at ${cur_cap}% (<= limit ${target_start}%). Discharge not needed."
        return 1
    fi

    echo "${target_start}" > "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
    log_info "Forcing immediate discharge on AC (from ${cur_cap}% down to ${target_start}%)..."
    set_charge_behaviour "force-discharge"
}

stop_discharge_cmd() {
    check_root
    rm -f "${MANUAL_DISCHARGE_FLAG}" 2>/dev/null || true
    if ! is_force_discharge_supported; then
        log_error "Current hardware does not support 'charge_behaviour'."
        return 1
    fi
    log_info "Cancelling forced discharge. Returning to 'auto' mode..."
    set_charge_behaviour "auto"
    if [[ -f "${PID_FILE}" ]]; then
        local d_pid
        d_pid=$(cat "${PID_FILE}" 2>/dev/null || true)
        if [[ -n "${d_pid}" ]] && is_pid_matching "${d_pid}"; then
            kill -USR1 "${d_pid}" 2>/dev/null || true
        fi
    fi
}

# ========================== INIT SYSTEM DETECTION & MANAGEMENT =============

detect_init_system() {
    if [[ -d /run/systemd/system ]]; then
        echo "systemd"
        return 0
    fi
    if [[ -d /run/openrc || -f /run/openrc/softlevel ]] || (command -v rc-status >/dev/null 2>&1 && rc-status -r >/dev/null 2>&1); then
        echo "openrc"
        return 0
    fi
    if [[ -d /run/runit ]] || pidof runit >/dev/null 2>&1 || [[ -f /etc/runit/1 ]] || \
       (command -v sv >/dev/null 2>&1 && { [[ -d /var/service ]] || [[ -d /etc/service ]] || [[ -d /run/runit/service ]]; }); then
        echo "runit"
        return 0
    fi
    if [[ -d /run/dinit ]] || (command -v dinitctl >/dev/null 2>&1 && pidof dinit >/dev/null 2>&1); then
        echo "dinit"
        return 0
    fi
    if [[ -d /etc/init.d ]] && (command -v start-stop-daemon >/dev/null 2>&1 || command -v service >/dev/null 2>&1); then
        echo "sysvinit"
        return 0
    fi
    echo "unknown"
}

detect_init_display() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)   echo "systemd" ;;
        (openrc)    echo "OpenRC" ;;
        (runit)     echo "Runit" ;;
        (dinit)     echo "dinit" ;;
        (sysvinit)  echo "SysVinit" ;;
        (*)         echo "Generic / Standalone" ;;
    esac
}

is_init_service_installed() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)   [[ -f "${INIT_SYSTEMD_SERVICE}" ]] ;;
        (openrc)    [[ -f "${INIT_OPENRC_SERVICE}" ]] && grep -q "openrc-run" "${INIT_OPENRC_SERVICE}" 2>/dev/null ;;
        (runit)     [[ -d "${INIT_RUNIT_SERVICE_DIR}" ]] ;;
        (dinit)     [[ -f "${INIT_DINIT_SERVICE}" ]] ;;
        (sysvinit)  [[ -f "${INIT_SYSV_SERVICE}" ]] && ! grep -q "openrc-run" "${INIT_SYSV_SERVICE}" 2>/dev/null ;;
        (*)         return 1 ;;
    esac
}

is_init_service_active() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)
            systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null
            ;;
        (openrc)
            if command -v rc-service >/dev/null 2>&1; then
                rc-service "${SCRIPT_NAME}" status 2>/dev/null | grep -qi "started"
            else
                if [[ -f "${PID_FILE}" ]]; then
                    local p; p=$(cat "${PID_FILE}" 2>/dev/null || true)
                    is_pid_matching "${p}"
                else
                    pgrep -f "${SCRIPT_NAME} daemon" >/dev/null 2>&1
                fi
            fi
            ;;
        (runit)
            if command -v sv >/dev/null 2>&1; then
                sv status "${SCRIPT_NAME}" 2>/dev/null | grep -q "^run:"
            else
                pgrep -f "${SCRIPT_NAME} daemon" >/dev/null 2>&1
            fi
            ;;
        (dinit)
            if command -v dinitctl >/dev/null 2>&1; then
                dinitctl status "${SCRIPT_NAME}" 2>/dev/null | grep -q "STARTED"
            else
                pgrep -f "${SCRIPT_NAME} daemon" >/dev/null 2>&1
            fi
            ;;
        (sysvinit)
            if [[ -f "${PID_FILE}" ]]; then
                local p; p=$(cat "${PID_FILE}" 2>/dev/null || true)
                if is_pid_matching "${p}"; then
                    return 0
                fi
            fi
            if command -v service >/dev/null 2>&1; then
                service "${SCRIPT_NAME}" status >/dev/null 2>&1
            else
                pgrep -f "${SCRIPT_NAME} daemon" >/dev/null 2>&1
            fi
            ;;
        (*)
            pgrep -f "${SCRIPT_NAME} daemon" >/dev/null 2>&1
            ;;
    esac
}

is_init_service_enabled() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)
            systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null
            ;;
        (openrc)
            if command -v rc-update >/dev/null 2>&1; then
                rc-update show 2>/dev/null | grep -qi "${SCRIPT_NAME}"
            else
                [[ -e "/etc/runlevels/default/${SCRIPT_NAME}" ]]
            fi
            ;;
        (runit)
            [[ -L "${INIT_RUNIT_ENABLE_DIR_VAR}/${SCRIPT_NAME}" || -L "${INIT_RUNIT_ENABLE_DIR_ETC}/${SCRIPT_NAME}" || -L "${INIT_RUNIT_ENABLE_DIR_RUN}/${SCRIPT_NAME}" ]]
            ;;
        (dinit)
            if command -v dinitctl >/dev/null 2>&1; then
                dinitctl is-enabled "${SCRIPT_NAME}" 2>/dev/null || [[ -f "/etc/dinit.d/boot.d/${SCRIPT_NAME}" ]]
            else
                [[ -f "/etc/dinit.d/boot.d/${SCRIPT_NAME}" ]]
            fi
            ;;
        (sysvinit)
            compgen -G "/etc/rc*.d/S*${SCRIPT_NAME}" >/dev/null 2>&1
            ;;
        (*)
            return 1
            ;;
    esac
}

start_init_service() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)
            systemctl daemon-reload 2>/dev/null || true
            systemctl restart "${SERVICE_NAME}"
            ;;
        (openrc)
            rc-service "${SCRIPT_NAME}" restart 2>/dev/null || rc-service "${SCRIPT_NAME}" start
            ;;
        (runit)
            if command -v sv >/dev/null 2>&1; then
                sv restart "${SCRIPT_NAME}" 2>/dev/null || sv up "${SCRIPT_NAME}"
            fi
            ;;
        (dinit)
            if command -v dinitctl >/dev/null 2>&1; then
                dinitctl restart "${SCRIPT_NAME}" 2>/dev/null || dinitctl start "${SCRIPT_NAME}"
            fi
            ;;
        (sysvinit)
            if command -v service >/dev/null 2>&1; then
                service "${SCRIPT_NAME}" restart 2>/dev/null || service "${SCRIPT_NAME}" start
            elif [[ -x "${INIT_SYSV_SERVICE}" ]]; then
                "${INIT_SYSV_SERVICE}" restart 2>/dev/null || "${INIT_SYSV_SERVICE}" start
            fi
            ;;
        (*)
            nohup "${SCRIPT_INSTALL_PATH}" daemon >/dev/null 2>&1 &
            ;;
    esac
}

stop_init_service() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)
            if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
                systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
            fi
            ;;
        (openrc)
            if command -v rc-service >/dev/null 2>&1; then
                rc-service "${SCRIPT_NAME}" stop 2>/dev/null || true
            fi
            ;;
        (runit)
            if command -v sv >/dev/null 2>&1; then
                sv down "${SCRIPT_NAME}" 2>/dev/null || true
            fi
            ;;
        (dinit)
            if command -v dinitctl >/dev/null 2>&1; then
                dinitctl stop "${SCRIPT_NAME}" 2>/dev/null || true
            fi
            ;;
        (sysvinit)
            if command -v service >/dev/null 2>&1; then
                service "${SCRIPT_NAME}" stop 2>/dev/null || true
            elif [[ -x "${INIT_SYSV_SERVICE}" ]]; then
                "${INIT_SYSV_SERVICE}" stop 2>/dev/null || true
            fi
            ;;
    esac

    if [[ -f "${PID_FILE}" ]]; then
        local p
        p=$(cat "${PID_FILE}" 2>/dev/null || true)
        if [[ -n "${p}" && "${p}" != "$$" ]] && is_pid_matching "${p}"; then
            kill -TERM "${p}" 2>/dev/null || true
        fi
        rm -f "${PID_FILE}" 2>/dev/null || true
    fi
    stop_daemon_action
}

enable_init_service() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)
            systemctl daemon-reload 2>/dev/null || true
            systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
            ;;
        (openrc)
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add "${SCRIPT_NAME}" default 2>/dev/null || true
            fi
            ;;
        (runit)
            local target_dir=""
            if [[ -d "${INIT_RUNIT_ENABLE_DIR_VAR}" ]]; then
                target_dir="${INIT_RUNIT_ENABLE_DIR_VAR}"
            elif [[ -d "${INIT_RUNIT_ENABLE_DIR_ETC}" ]]; then
                target_dir="${INIT_RUNIT_ENABLE_DIR_ETC}"
            elif [[ -d "${INIT_RUNIT_ENABLE_DIR_RUN}" ]]; then
                target_dir="${INIT_RUNIT_ENABLE_DIR_RUN}"
            fi
            if [[ -n "${target_dir}" && -d "${INIT_RUNIT_SERVICE_DIR}" ]]; then
                ln -sfn "${INIT_RUNIT_SERVICE_DIR}" "${target_dir}/${SCRIPT_NAME}"
            fi
            ;;
        (dinit)
            if command -v dinitctl >/dev/null 2>&1; then
                dinitctl enable "${SCRIPT_NAME}" 2>/dev/null || true
            fi
            ;;
        (sysvinit)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "${SCRIPT_NAME}" defaults 2>/dev/null || true
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig --add "${SCRIPT_NAME}" 2>/dev/null || true
                chkconfig "${SCRIPT_NAME}" on 2>/dev/null || true
            fi
            ;;
    esac
}

disable_init_service() {
    local init_sys
    init_sys=$(detect_init_system)
    case "${init_sys}" in
        (systemd)
            if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
                systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
            fi
            ;;
        (openrc)
            if command -v rc-update >/dev/null 2>&1; then
                rc-update del "${SCRIPT_NAME}" default 2>/dev/null || true
            fi
            ;;
        (runit)
            rm -f "${INIT_RUNIT_ENABLE_DIR_VAR}/${SCRIPT_NAME}" 2>/dev/null || true
            rm -f "${INIT_RUNIT_ENABLE_DIR_ETC}/${SCRIPT_NAME}" 2>/dev/null || true
            rm -f "${INIT_RUNIT_ENABLE_DIR_RUN}/${SCRIPT_NAME}" 2>/dev/null || true
            ;;
        (dinit)
            if command -v dinitctl >/dev/null 2>&1; then
                dinitctl disable "${SCRIPT_NAME}" 2>/dev/null || true
            fi
            ;;
        (sysvinit)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d -f "${SCRIPT_NAME}" remove 2>/dev/null || true
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig "${SCRIPT_NAME}" off 2>/dev/null || true
                chkconfig --del "${SCRIPT_NAME}" 2>/dev/null || true
            fi
            ;;
    esac
}

install_sleep_hooks() {
    local hook_script="/etc/linux-battery-manager/sleep-hook"
    mkdir -p "/etc/linux-battery-manager"
    cat > "${hook_script}" << 'HOOK_EOF'
#!/bin/sh
# Re-apply battery thresholds immediately upon waking up
case "$1" in
    (post|thaw|resume)
        /usr/local/bin/linux-battery-manager apply >/dev/null 2>&1 || true
        ;;
esac
HOOK_EOF
    chmod 755 "${hook_script}"

    if [[ -d "${SLEEP_HOOK_DIR_SYSTEMD}" ]]; then
        ln -sf "${hook_script}" "${SLEEP_HOOK_DIR_SYSTEMD}/linux-battery-manager" 2>/dev/null || true
    fi
    if [[ -d "${SLEEP_HOOK_DIR_ELOGIND_LIB}" ]]; then
        ln -sf "${hook_script}" "${SLEEP_HOOK_DIR_ELOGIND_LIB}/linux-battery-manager" 2>/dev/null || true
    fi
    if [[ -d "${SLEEP_HOOK_DIR_ELOGIND_ETC}" ]]; then
        ln -sf "${hook_script}" "${SLEEP_HOOK_DIR_ELOGIND_ETC}/linux-battery-manager" 2>/dev/null || true
    fi
    if [[ -d "${SLEEP_HOOK_DIR_PM}" ]]; then
        ln -sf "${hook_script}" "${SLEEP_HOOK_DIR_PM}/99-linux-battery-manager" 2>/dev/null || true
    fi
}

remove_sleep_hooks() {
    rm -f "${SLEEP_HOOK_DIR_SYSTEMD}/linux-battery-manager" 2>/dev/null || true
    rm -f "${SLEEP_HOOK_DIR_ELOGIND_LIB}/linux-battery-manager" 2>/dev/null || true
    rm -f "${SLEEP_HOOK_DIR_ELOGIND_ETC}/linux-battery-manager" 2>/dev/null || true
    rm -f "${SLEEP_HOOK_DIR_PM}/99-linux-battery-manager" 2>/dev/null || true
    rm -f "/etc/linux-battery-manager/sleep-hook" 2>/dev/null || true
}

# ========================== INSTALLATION / MIGRATION ========================

install_service() {
    check_root
    load_config

    local init_sys init_name
    init_sys=$(detect_init_system)
    init_name=$(detect_init_display)

    echo "Installing ${SCRIPT_NAME} v${SCRIPT_VERSION} (Init system: ${init_name})..."
    echo

    if ! check_hardware; then
        echo "Hardware warnings detected, proceeding with installation..."
    fi
    echo

    for s in "${LEGACY_SERVICES[@]}"; do
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet "${s}" 2>/dev/null; then
                log_info "Stopping legacy service: ${s}"
                systemctl stop "${s}" 2>/dev/null || true
            fi
            if systemctl is-enabled --quiet "${s}" 2>/dev/null; then
                log_info "Disabling legacy service: ${s}"
                systemctl disable "${s}" 2>/dev/null || true
            fi
        fi
        rm -f "/etc/systemd/system/${s}" 2>/dev/null || true
        rm -f "/etc/init.d/${s%.service}" 2>/dev/null || true
    done

    for b in "${LEGACY_BINARIES[@]}"; do
        rm -f "${b}" 2>/dev/null || true
    done

    mkdir -p "${BACKUP_DIR}"
    if [[ -f "${LEGACY_CONF_FILE}" && ! -f "${CONF_FILE}" ]]; then
        mv -f "${LEGACY_CONF_FILE}" "${CONF_FILE}"
        log_info "Migrated configuration from ${LEGACY_CONF_FILE} to ${CONF_FILE}"
    fi

    if [[ ! -f "${CONF_FILE}" ]]; then
        save_config "${DEFAULT_START_THRESHOLD}" "${DEFAULT_END_THRESHOLD}" "${DEFAULT_AUTO_DISCHARGE}" "custom" "${DEFAULT_UI_LANG}"
        log_info "Default configuration saved to: ${CONF_FILE}"
    else
        load_config
        save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "${AUTO_DISCHARGE}" "${DELL_MODE}" "${UI_LANG}"
        log_info "Existing configuration preserved at: ${CONF_FILE}"
    fi

    local src_real dst_real
    src_real=$(realpath "$0" 2>/dev/null || echo "$0")
    dst_real=$(realpath "${SCRIPT_INSTALL_PATH}" 2>/dev/null || echo "${SCRIPT_INSTALL_PATH}")
    if [[ "${src_real}" != "${dst_real}" ]]; then
        cp -f "$0" "${SCRIPT_INSTALL_PATH}"
    fi
    chmod 755 "${SCRIPT_INSTALL_PATH}"
    ln -sf "${SCRIPT_INSTALL_PATH}" "${SCRIPT_ALIAS_PATH}"
    log_info "Binary installed at: ${SCRIPT_INSTALL_PATH} (and alias ${SCRIPT_ALIAS_PATH})"

    case "${init_sys}" in
        (systemd)
            cat > "${INIT_SYSTEMD_SERVICE}" << 'UNIT_EOF'
[Unit]
Description=Universal Linux Battery Charge Limit & Auto-Discharge Manager
Documentation=https://github.com/AlanSchaffer/linux-battery-manager
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=simple
Restart=always
RestartSec=10s
ExecStart=/usr/local/bin/linux-battery-manager daemon
ExecStopPost=/usr/local/bin/linux-battery-manager post-stop

ProtectHome=yes
PrivateTmp=yes

StandardOutput=journal
StandardError=journal
SyslogIdentifier=linux-battery-manager

[Install]
WantedBy=multi-user.target
UNIT_EOF
            log_info "systemd service created: ${INIT_SYSTEMD_SERVICE}"
            ;;

        (openrc)
            cat > "${INIT_OPENRC_SERVICE}" << 'OPENRC_EOF'
#!/sbin/openrc-run
description="Universal Linux Battery Charge Limit & Auto-Discharge Manager"
supervisor="supervise-daemon"
command="/usr/local/bin/linux-battery-manager"
command_args="daemon"
retry="SIGTERM/10 SIGKILL/5"

depend() {
    need localmount
    after bootmisc
}

stop_post() {
    /usr/local/bin/linux-battery-manager post-stop >/dev/null 2>&1 || true
}
OPENRC_EOF
            chmod 755 "${INIT_OPENRC_SERVICE}"
            log_info "OpenRC service created: ${INIT_OPENRC_SERVICE}"
            ;;

        (runit)
            mkdir -p "${INIT_RUNIT_SERVICE_DIR}"
            cat > "${INIT_RUNIT_SERVICE_DIR}/run" << 'RUNIT_RUN_EOF'
#!/bin/sh
exec 2>&1
exec /usr/local/bin/linux-battery-manager daemon
RUNIT_RUN_EOF
            cat > "${INIT_RUNIT_SERVICE_DIR}/finish" << 'RUNIT_FINISH_EOF'
#!/bin/sh
/usr/local/bin/linux-battery-manager post-stop >/dev/null 2>&1 || true
RUNIT_FINISH_EOF
            chmod 755 "${INIT_RUNIT_SERVICE_DIR}/run" "${INIT_RUNIT_SERVICE_DIR}/finish"
            log_info "Runit service created: ${INIT_RUNIT_SERVICE_DIR}"
            ;;

        (dinit)
            mkdir -p /etc/dinit.d
            cat > "${INIT_DINIT_SERVICE}" << 'DINIT_EOF'
type = process
command = /usr/local/bin/linux-battery-manager daemon
stop-command = /usr/local/bin/linux-battery-manager post-stop
restart = yes
smooth-recovery = yes
pid-file = /run/linux-battery-manager.pid
DINIT_EOF
            log_info "dinit service created: ${INIT_DINIT_SERVICE}"
            ;;

        (sysvinit|*)
            cat > "${INIT_SYSV_SERVICE}" << 'SYSV_EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          linux-battery-manager
# Required-Start:    $local_fs $remote_fs
# Required-Stop:     $local_fs $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Universal Linux Battery Charge Limit Manager
### END INIT INFO

PIDFILE="/run/linux-battery-manager.pid"
DAEMON="/usr/local/bin/linux-battery-manager"
NAME="linux-battery-manager"

case "$1" in
    (start)
        echo "Starting $NAME..."
        if command -v start-stop-daemon >/dev/null 2>&1; then
            start-stop-daemon --start --background --make-pidfile --pidfile "$PIDFILE" --exec "$DAEMON" -- daemon
        else
            nohup "$DAEMON" daemon >/dev/null 2>&1 &
            echo $! > "$PIDFILE"
        fi
        ;;
    (stop)
        echo "Stopping $NAME..."
        if command -v start-stop-daemon >/dev/null 2>&1; then
            start-stop-daemon --stop --pidfile "$PIDFILE" --oknodo --retry 5
        elif [ -f "$PIDFILE" ]; then
            PID_TO_KILL=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$PID_TO_KILL" ] && [ "$PID_TO_KILL" != "$$" ]; then
                if [ -d "/proc/$PID_TO_KILL" ]; then
                    if [ ! -f "/proc/$PID_TO_KILL/cmdline" ] || grep -qa "$NAME" "/proc/$PID_TO_KILL/cmdline" 2>/dev/null; then
                        kill -TERM "$PID_TO_KILL" 2>/dev/null || true
                    fi
                elif kill -0 "$PID_TO_KILL" 2>/dev/null; then
                    kill -TERM "$PID_TO_KILL" 2>/dev/null || true
                fi
            fi
        fi
        rm -f "$PIDFILE"
        "$DAEMON" post-stop >/dev/null 2>&1 || true
        ;;
    (restart|force-reload)
        $0 stop
        sleep 1
        $0 start
        ;;
    (status)
        if command -v start-stop-daemon >/dev/null 2>&1; then
            start-stop-daemon --status --pidfile "$PIDFILE"
        elif [ -f "$PIDFILE" ]; then
            PID_CHECK=$(cat "$PIDFILE" 2>/dev/null)
            if [ -n "$PID_CHECK" ] && [ "$PID_CHECK" != "$$" ]; then
                if [ -d "/proc/$PID_CHECK" ]; then
                    if [ ! -f "/proc/$PID_CHECK/cmdline" ] || grep -qa "$NAME" "/proc/$PID_CHECK/cmdline" 2>/dev/null; then
                        echo "$NAME is running."
                        exit 0
                    fi
                elif kill -0 "$PID_CHECK" 2>/dev/null; then
                    echo "$NAME is running."
                    exit 0
                fi
            fi
            echo "$NAME is not running."
            exit 1
        else
            echo "$NAME is not running."
            exit 1
        fi
        ;;
    (*)
        echo "Usage: $0 {start|stop|restart|status}" >&2
        exit 1
        ;;
esac
exit 0
SYSV_EOF
            chmod 755 "${INIT_SYSV_SERVICE}"
            log_info "SysVinit service created: ${INIT_SYSV_SERVICE}"
            ;;
    esac

    install_sleep_hooks
    enable_init_service
    start_init_service
    log_info "Service enabled and started successfully (${init_name})."

    echo
    echo "==============================================================="
    echo "  [OK] Installation completed successfully!"
    echo "  Hardware detected: $(detect_vendor_display)"
    echo "  Init system:       ${init_name}"
    echo
    echo "  Quick commands:"
    echo "    sudo linux-battery-manager          — Open Interactive TUI"
    echo "    sudo linux_battery_manager          — Open Interactive TUI"
    echo "    sudo linux-battery-manager on       — Enable Smart Auto-Discharge"
    echo "    sudo linux-battery-manager off      — Disable Smart Auto-Discharge"
    echo "    sudo linux-battery-manager status   — Show detailed status"
    echo "    sudo linux-battery-manager set 75 80 — Set charge limits"
    echo "    sudo linux-battery-manager lang en  — Switch UI to English/PT"
    echo "==============================================================="
}

# ========================== DISABLE / ENABLE / REMOVE =======================

disable_service() {
    check_root
    local init_name
    init_name=$(detect_init_display)
    log_info "Disabling service (${init_name})..."

    stop_init_service
    disable_init_service

    restore_defaults "false"
    echo
    log_info "[OK] Service disabled and hardware limits restored to 100%."
    log_info "To re-enable: sudo linux-battery-manager enable"
}

enable_service() {
    check_root
    local init_name
    init_name=$(detect_init_display)
    if ! is_init_service_installed; then
        log_error "Service not installed for ${init_name}. Run 'install' first."
        exit 1
    fi

    enable_init_service
    start_init_service
    log_info "[OK] Service enabled and started (${init_name})."
}

remove_service() {
    check_root
    local init_sys init_name
    init_sys=$(detect_init_system)
    init_name=$(detect_init_display)

    echo "Removing ${SCRIPT_NAME} (${init_name})..."
    echo

    stop_init_service
    disable_init_service
    restore_defaults "false"
    remove_sleep_hooks

    case "${init_sys}" in
        (systemd)
            rm -f "${INIT_SYSTEMD_SERVICE}"
            if command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload 2>/dev/null || true
                log_info "systemd reloaded."
            fi
            ;;
        (openrc)
            rm -f "${INIT_OPENRC_SERVICE}"
            ;;
        (runit)
            rm -rf "${INIT_RUNIT_SERVICE_DIR}"
            rm -f "${INIT_RUNIT_ENABLE_DIR_VAR}/${SCRIPT_NAME}"
            rm -f "${INIT_RUNIT_ENABLE_DIR_ETC}/${SCRIPT_NAME}"
            rm -f "${INIT_RUNIT_ENABLE_DIR_RUN}/${SCRIPT_NAME}"
            ;;
        (dinit)
            rm -f "${INIT_DINIT_SERVICE}"
            rm -f "/etc/dinit.d/boot.d/${SCRIPT_NAME}" 2>/dev/null || true
            ;;
        (sysvinit)
            rm -f "${INIT_SYSV_SERVICE}"
            ;;
    esac

    rm -f "${SCRIPT_INSTALL_PATH}"
    rm -f "${SCRIPT_ALIAS_PATH}"
    rm -f "${CONF_FILE}"
    rm -f "${LEGACY_CONF_FILE}"
    rm -f "${PID_FILE}"
    rm -f "${MANUAL_DISCHARGE_FLAG}"

    for b in "${LEGACY_BINARIES[@]}"; do
        rm -f "${b}" 2>/dev/null || true
    done

    echo
    echo "==============================================================="
    echo "  [OK] Uninstallation completed successfully."
    echo "  Charge limits restored to factory defaults (100%)."
    echo "==============================================================="
}

# ========================== STATUS ==========================================

show_status() {
    load_config
    local vendor model cur_start cur_end beh
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
    model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")
    cur_start=$(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo "N/A")
    cur_end=$(cat "${END_THRESHOLD_FILE}" 2>/dev/null || echo "N/A")
    beh=$(get_charge_behaviour)

    if [[ "${UI_LANG}" == "en" ]]; then
        echo "==============================================================="
        echo "  Status — ${SCRIPT_NAME} v${SCRIPT_VERSION} ($(detect_vendor_display))"
        echo "==============================================================="
        echo "Device:             ${vendor} (${model})"
        if [[ -d "${BAT_PATH}" ]]; then
            echo "Battery:"
            echo "  Current charge:   $(cat "${BAT_PATH}/capacity" 2>/dev/null || echo '?')%"
            echo "  Status:           $(cat "${BAT_PATH}/status" 2>/dev/null || echo '?')"
            echo "  Current energy:   $(read_battery_energy now)"
            echo "  Full energy:      $(read_battery_energy full)"
            echo "  Cycle count:      $(cat "${BAT_PATH}/cycle_count" 2>/dev/null || echo '?')"
        else
            echo "  [ERR] Battery not found"
        fi
        echo
        echo "External Power:"
        if is_ac_online; then
            echo "  AC Power:         [AC] Connected"
        else
            echo "  AC Power:         [BAT] Disconnected (running on battery)"
        fi
        echo
        echo "Hardware Charge Thresholds:"
        echo "  Start threshold:  ${cur_start}%"
        echo "  Stop threshold:   ${cur_end}%"
        echo
        echo "Smart Auto-Discharge:"
        if is_force_discharge_supported; then
            echo "  Hardware Support: [OK] Supported (force-discharge)"
            echo "  Current Mode:     ${beh}"
            if [[ "${beh}" == "force-discharge" ]]; then
                echo "  Discharge State:  [ACTIVE] Draining down to ${START_THRESHOLD}%"
            else
                echo "  Discharge State:  Idle / Automatic"
            fi
            echo "  Feature Status:   $( [[ "${AUTO_DISCHARGE:-true}" == "true" ]] && echo "[ON] ENABLED" || echo "[OFF] DISABLED" )"
        else
            echo "  Hardware Support: [INFO] Not supported on this machine"
        fi
        echo
        local init_display
        init_display=$(detect_init_display)
        echo "Service (${init_display}):"
        if is_init_service_installed; then
            echo "  Installed:        [YES]"
            echo "  Enabled on boot:  $(is_init_service_enabled && echo '[YES]' || echo '[NO]')"
            echo "  Active (running): $(is_init_service_active && echo '[YES]' || echo '[NO]')"
        else
            echo "  Installed:        [NO]"
        fi
        echo "==============================================================="
    else
        echo "==============================================================="
        echo "  Status — ${SCRIPT_NAME} v${SCRIPT_VERSION} ($(detect_vendor_display))"
        echo "==============================================================="
        echo "Dispositivo:        ${vendor} (${model})"
        if [[ -d "${BAT_PATH}" ]]; then
            echo "Bateria:"
            echo "  Carga atual:      $(cat "${BAT_PATH}/capacity" 2>/dev/null || echo '?')%"
            echo "  Status:           $(cat "${BAT_PATH}/status" 2>/dev/null || echo '?')"
            echo "  Energia atual:    $(read_battery_energy now)"
            echo "  Energia total:    $(read_battery_energy full)"
            echo "  Ciclos:           $(cat "${BAT_PATH}/cycle_count" 2>/dev/null || echo '?')"
        else
            echo "  [ERRO] Bateria nao encontrada"
        fi
        echo
        echo "Alimentacao Externa:"
        if is_ac_online; then
            echo "  Tomada (AC):      [AC] Conectada"
        else
            echo "  Tomada (AC):      [BAT] Desconectada (operando na bateria)"
        fi
        echo
        echo "Limites de Carga do Hardware:"
        echo "  Inicio (start):   ${cur_start}%"
        echo "  Parada (stop):    ${cur_end}%"
        echo
        echo "Descarga Inteligente (Auto-Discharge):"
        if is_force_discharge_supported; then
            echo "  Suporte Hardware: [OK] Suportado (force-discharge)"
            echo "  Modo Atual:       ${beh}"
            if [[ "${beh}" == "force-discharge" ]]; then
                echo "  Estado Descarga:  [ATIVA] Drenando ate ${START_THRESHOLD}%"
            else
                echo "  Estado Descarga:  Em repouso / Automatico"
            fi
            echo "  Funcionalidade:   $( [[ "${AUTO_DISCHARGE:-true}" == "true" ]] && echo "[ON] ATIVADA" || echo "[OFF] DESATIVADA" )"
        else
            echo "  Suporte Hardware: [INFO] Nao suportado neste equipamento"
        fi
        echo
        local init_display
        init_display=$(detect_init_display)
        echo "Servico (${init_display}):"
        if is_init_service_installed; then
            echo "  Instalado:        [SIM]"
            echo "  Habilitado boot:  $(is_init_service_enabled && echo '[SIM]' || echo '[NAO]')"
            echo "  Ativo (rodando):  $(is_init_service_active && echo '[SIM]' || echo '[NAO]')"
        else
            echo "  Instalado:        [NAO]"
        fi
        echo "==============================================================="
    fi
}

# ============================================================================
# CENTERED NATIVE TUI ENGINE (ZERO EMOJIS, PURE ASCII/BOX DRAWING, SAFE ARITH)
# ============================================================================

LAST_KEY=""
TUI_ROW=1
TUI_COL=1
readonly BOX_WIDTH=68
readonly INNER_WIDTH=66
readonly MAX_TEXT_WIDTH=63

tui_calc_center() {
    local box_h="${1:-18}"
    local box_w="${2:-${BOX_WIDTH}}"
    local rows=24
    local cols=80
    local size=""

    size=$(stty size < /dev/tty 2>/dev/null || true)
    if [[ "${size}" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
        rows="${BASH_REMATCH[1]}"
        cols="${BASH_REMATCH[2]}"
    fi

    TUI_ROW=$(( (rows - box_h) / 2 + 1 ))
    TUI_COL=$(( (cols - box_w) / 2 + 1 ))
    if (( TUI_ROW < 1 )); then TUI_ROW=1; fi
    if (( TUI_COL < 1 )); then TUI_COL=1; fi
}

tui_draw_row() {
    local r="$1"
    local content="${2:-}"
    local right_col=$(( TUI_COL + BOX_WIDTH - 1 ))

    # Truncate plain text lines (without ANSI escapes) so long DMI names never overflow box borders
    if [[ "${content}" != *"\033"* ]] && (( ${#content} > MAX_TEXT_WIDTH )); then
        content="${content:0:$(( MAX_TEXT_WIDTH - 3 ))}..."
    fi

    printf '\033[%d;%dH│%*s│\033[%d;%dH%b\033[%d;%dH│' \
        "${r}" "${TUI_COL}" "${INNER_WIDTH}" "" \
        "${r}" "$(( TUI_COL + 2 ))" "${content}" \
        "${r}" "${right_col}" > /dev/tty
}

tui_draw_item() {
    local r="$1"
    local selected_flag="$2"
    local text="$3"
    local right_col=$(( TUI_COL + BOX_WIDTH - 1 ))
    local text_len=${#text}
    local pad_len=$(( 61 - text_len ))
    if (( pad_len < 0 )); then
        text="${text:0:58}..."
        pad_len=0
    fi
    local pad=""
    if (( pad_len > 0 )); then
        printf -v pad '%*s' "${pad_len}" ""
    fi

    if (( selected_flag == 1 )); then
        printf '\033[%d;%dH│  \033[7;1m %s%s\033[0m  │' \
            "${r}" "${TUI_COL}" "${text}" "${pad}" > /dev/tty
    else
        printf '\033[%d;%dH│   %s%s  │' \
            "${r}" "${TUI_COL}" "${text}" "${pad}" > /dev/tty
    fi
    printf '\033[%d;%dH│' "${r}" "${right_col}" > /dev/tty
}

tui_draw_top() {
    local r="$1"
    local title="${2:-}"
    local line_fill="──────────────────────────────────────────────────────────────────"
    printf '\033[%d;%dH┌%s┐' "${r}" "${TUI_COL}" "${line_fill}" > /dev/tty
    if [[ -n "${title}" ]]; then
        local t_len=${#title}
        local t_col=$(( TUI_COL + (BOX_WIDTH - t_len - 2) / 2 ))
        printf '\033[%d;%dH \033[1;36m%s\033[0m ' "${r}" "${t_col}" "${title}" > /dev/tty
    fi
}

tui_draw_sep() {
    local r="$1"
    printf '\033[%d;%dH├──────────────────────────────────────────────────────────────────┤' "${r}" "${TUI_COL}" > /dev/tty
}

tui_draw_bottom() {
    local r="$1"
    printf '\033[%d;%dH└──────────────────────────────────────────────────────────────────┘' "${r}" "${TUI_COL}" > /dev/tty
}

read_tty_key() {
    LAST_KEY=""
    local k1="" k2="" k3=""

    if ! IFS= read -rsn1 k1 < /dev/tty 2>/dev/null; then
        LAST_KEY="ESC"
        return 0
    fi

    if [[ -z "${k1}" ]]; then
        LAST_KEY="ENTER"
        return 0
    fi

    if [[ "${k1}" == $'\x1b' ]]; then
        if ! IFS= read -rsn1 -t 0.05 k2 < /dev/tty 2>/dev/null || [[ -z "${k2}" ]]; then
            LAST_KEY="ESC"
            return 0
        fi
        if [[ "${k2}" == "[" || "${k2}" == "O" ]]; then
            IFS= read -rsn1 -t 0.05 k3 < /dev/tty 2>/dev/null || true
            case "${k3}" in
                (A) LAST_KEY="UP" ;;
                (B) LAST_KEY="DOWN" ;;
                (C) LAST_KEY="RIGHT" ;;
                (D) LAST_KEY="LEFT" ;;
                (*) LAST_KEY="OTHER_SEQ" ;;
            esac
            return 0
        fi
        LAST_KEY="ESC"
        return 0
    fi

    LAST_KEY="${k1}"
}

tui_msgbox() {
    local title="$1"
    local msg="$2"
    setup_strings

    local lines=()
    while IFS= read -r line; do
        lines+=("${line}")
    done <<< "${msg}"

    local box_h=$(( ${#lines[@]} + 7 ))
    tui_calc_center "${box_h}" "${BOX_WIDTH}"
    local r="${TUI_ROW}"

    printf '\033[2J\033[H\033[?25l' > /dev/tty
    tui_draw_top "${r}" "${title}"; r=$(( r + 1 ))
    tui_draw_row "${r}" ""; r=$(( r + 1 ))
    for line in "${lines[@]}"; do
        tui_draw_row "${r}" "${line}"; r=$(( r + 1 ))
    done
    tui_draw_row "${r}" ""; r=$(( r + 1 ))
    tui_draw_sep "${r}"; r=$(( r + 1 ))
    tui_draw_row "${r}" "${L_FOOTER_MSG}"; r=$(( r + 1 ))
    tui_draw_bottom "${r}"

    while true; do
        read_tty_key
        case "${LAST_KEY}" in
            (ENTER|ESC|" "|q|Q) break ;;
        esac
    done
}

INPUT_RESULT=""
tui_inputbox() {
    local title="$1"
    local prompt_msg="$2"
    local default_val="$3"
    local buf="${default_val}"
    setup_strings

    while true; do
        tui_calc_center 9 "${BOX_WIDTH}"
        local r="${TUI_ROW}"

        printf '\033[2J\033[H\033[?25l' > /dev/tty
        tui_draw_top "${r}" "${title}"; r=$(( r + 1 ))
        tui_draw_row "${r}" ""; r=$(( r + 1 ))
        tui_draw_row "${r}" "${prompt_msg}"; r=$(( r + 1 ))
        tui_draw_row "${r}" ""; r=$(( r + 1 ))
        tui_draw_row "${r}" "${L_VALUE_LABEL}: \033[1;33m${buf}_\033[0m"; r=$(( r + 1 ))
        tui_draw_row "${r}" ""; r=$(( r + 1 ))
        tui_draw_sep "${r}"; r=$(( r + 1 ))
        tui_draw_row "${r}" "${L_FOOTER_INPUT}"; r=$(( r + 1 ))
        tui_draw_bottom "${r}"

        read_tty_key
        case "${LAST_KEY}" in
            (ESC)
                return 1
                ;;
            (ENTER)
                INPUT_RESULT="${buf}"
                return 0
                ;;
            ($'\x7f'|$'\x08')
                if [[ -n "${buf}" ]]; then
                    buf="${buf%?}"
                fi
                ;;
            ([0-9])
                if (( ${#buf} < 3 )); then
                    buf+="${LAST_KEY}"
                fi
                ;;
        esac
    done
}

tui_yesno() {
    local title="$1"
    local question="$2"
    local sel=0
    setup_strings

    while true; do
        tui_calc_center 8 "${BOX_WIDTH}"
        local r="${TUI_ROW}"

        printf '\033[2J\033[H\033[?25l' > /dev/tty
        tui_draw_top "${r}" "${title}"; r=$(( r + 1 ))
        tui_draw_row "${r}" ""; r=$(( r + 1 ))
        tui_draw_row "${r}" "${question}"; r=$(( r + 1 ))
        tui_draw_row "${r}" ""; r=$(( r + 1 ))
        if (( sel == 0 )); then
            tui_draw_row "${r}" "               \033[7;1m < ${L_YES} > \033[0m              < ${L_NO} >"; r=$(( r + 1 ))
        else
            tui_draw_row "${r}" "                < ${L_YES} >              \033[7;1m < ${L_NO} > \033[0m"; r=$(( r + 1 ))
        fi
        tui_draw_row "${r}" ""; r=$(( r + 1 ))
        tui_draw_bottom "${r}"

        read_tty_key
        case "${LAST_KEY}" in
            (LEFT|RIGHT|UP|DOWN|h|l|j|k|$'\t')
                sel=$(( 1 - sel ))
                ;;
            (y|Y|s|S)
                return 0
                ;;
            (n|N|q|Q|ESC)
                return 1
                ;;
            (ENTER)
                return ${sel}
                ;;
        esac
    done
}

tui_show_status_box() {
    setup_strings
    local status_lines=()
    while IFS= read -r line; do
        if [[ "${line}" == ===* ]]; then
            continue
        fi
        status_lines+=("${line}")
    done < <(show_status)

    local box_h=$(( ${#status_lines[@]} + 5 ))
    tui_calc_center "${box_h}" "${BOX_WIDTH}"
    local r="${TUI_ROW}"

    printf '\033[2J\033[H\033[?25l' > /dev/tty
    tui_draw_top "${r}" "${L_STATUS_TITLE}"; r=$(( r + 1 ))
    for sline in "${status_lines[@]}"; do
        tui_draw_row "${r}" "${sline}"; r=$(( r + 1 ))
    done
    tui_draw_sep "${r}"; r=$(( r + 1 ))
    tui_draw_row "${r}" "${L_FOOTER_STATUS}"; r=$(( r + 1 ))
    tui_draw_bottom "${r}"

    while true; do
        read_tty_key
        case "${LAST_KEY}" in
            (ESC|q|Q)
                cleanup_tui
                exit 0
                ;;
            (ENTER|" ")
                break
                ;;
        esac
    done
}

show_interactive_menu() {
    if ! ( : > /dev/tty ) 2>/dev/null; then
        show_status
        exit 0
    fi

    TUI_ACTIVE=1
    trap cleanup_tui EXIT INT TERM
    printf '\033[?25l' > /dev/tty

    local selected=0
    local total_items=7
    local ac_label auto_state cur_cap vendor_name

    while true; do
        load_config
        setup_strings
        vendor_name=$(detect_vendor_display)
        cur_cap=$(cat "${BAT_PATH}/capacity" 2>/dev/null || echo "?")

        if is_ac_online; then
            ac_label="${L_AC_ON} [AC]"
        else
            ac_label="${L_AC_OFF} [BAT]"
        fi

        if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
            auto_state="\033[1;32m${L_ENABLED} [ON]\033[0m"
        else
            auto_state="\033[1;31m${L_DISABLED} [OFF]\033[0m"
        fi

        local items=(
            "${L_OPT1}"
            "${L_OPT2}"
            "${L_OPT3}"
            "${L_OPT4}"
            "${L_OPT5}"
            "${L_OPT6}"
            "${L_OPT0}"
        )

        tui_calc_center 18 "${BOX_WIDTH}"
        local r="${TUI_ROW}"

        printf '\033[2J\033[H\033[?25l' > /dev/tty
        tui_draw_top "${r}" "${L_TITLE}"; r=$(( r + 1 ))
        tui_draw_row "${r}" "${L_BAT}: \033[1m${cur_cap}%\033[0m (${ac_label}) | \033[1;36m${vendor_name}\033[0m"; r=$(( r + 1 ))
        tui_draw_row "${r}" "Auto-Discharge: [${auto_state}] | ${L_LIMITS}: \033[1m${START_THRESHOLD}% - ${END_THRESHOLD}%\033[0m"; r=$(( r + 1 ))
        tui_draw_sep "${r}"; r=$(( r + 1 ))
        tui_draw_row "${r}" "${L_MENU_PROMPT}"; r=$(( r + 1 ))
        tui_draw_row "${r}" ""; r=$(( r + 1 ))

        for i in "${!items[@]}"; do
            if (( i == selected )); then
                tui_draw_item "${r}" 1 "${items[$i]}"
            else
                tui_draw_item "${r}" 0 "${items[$i]}"
            fi
            r=$(( r + 1 ))
        done

        tui_draw_row "${r}" ""; r=$(( r + 1 ))
        tui_draw_sep "${r}"; r=$(( r + 1 ))
        tui_draw_row "${r}" "  ${L_FOOTER_MENU}"; r=$(( r + 1 ))
        tui_draw_bottom "${r}"

        read_tty_key
        local action=""

        case "${LAST_KEY}" in
            (ESC|q|Q|0)
                cleanup_tui
                exit 0
                ;;
            (UP|k|K)
                selected=$(( (selected - 1 + total_items) % total_items ))
                continue
                ;;
            (DOWN|j|J)
                selected=$(( (selected + 1) % total_items ))
                continue
                ;;
            (1) selected=0; action="1" ;;
            (2) selected=1; action="2" ;;
            (3) selected=2; action="3" ;;
            (4) selected=3; action="4" ;;
            (5) selected=4; action="5" ;;
            (6|l|L) selected=5; action="6" ;;
            (ENTER)
                case "${selected}" in
                    (0) action="1" ;;
                    (1) action="2" ;;
                    (2) action="3" ;;
                    (3) action="4" ;;
                    (4) action="5" ;;
                    (5) action="6" ;;
                    (6)
                        cleanup_tui
                        exit 0
                        ;;
                esac
                ;;
            (*)
                continue
                ;;
        esac

        case "${action}" in
            (1)
                tui_show_status_box
                ;;

            (2)
                check_root
                if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
                    set_auto_discharge_cmd "off" >/dev/null
                    setup_strings
                    tui_msgbox "${L_MSG_AD_OFF_TITLE}" "${L_MSG_AD_OFF_BODY}"
                else
                    set_auto_discharge_cmd "on" >/dev/null
                    setup_strings
                    tui_msgbox "${L_MSG_AD_ON_TITLE}" "${L_MSG_AD_ON_BODY}"
                fi
                ;;

            (3)
                check_root
                local new_start="" new_end=""
                local v
                v=$(detect_vendor)

                if ! tui_inputbox "${L_IN_END_TITLE}" "${L_IN_END_PROMPT}" "${END_THRESHOLD}"; then
                    continue
                fi
                new_end="${INPUT_RESULT}"

                if [[ "${v}" == "asus" ]]; then
                    new_start="0"
                else
                    local rec_start
                    rec_start=$(calculate_default_start "${new_end}")
                    local prompt_start
                    if [[ "${UI_LANG}" == "pt" ]]; then
                        prompt_start="Informe a % para INICIAR recarga (Recomendado: ${rec_start}):"
                    else
                        prompt_start="Enter % to START charging (Recommended: ${rec_start}):"
                    fi

                    if ! tui_inputbox "${L_IN_START_TITLE}" "${prompt_start}" "${rec_start}"; then
                        continue
                    fi
                    new_start="${INPUT_RESULT}"
                fi

                if apply_thresholds "${new_start}" "${new_end}" >/dev/null 2>&1; then
                    save_config "${new_start}" "${new_end}" "${AUTO_DISCHARGE}" "custom" "${UI_LANG}"
                    if [[ "${UI_LANG}" == "en" ]]; then
                        tui_msgbox "${L_MSG_LIM_OK_TITLE}" "Thresholds updated: Start = ${new_start}% | Stop = ${new_end}%"
                    else
                        tui_msgbox "${L_MSG_LIM_OK_TITLE}" "Limites atualizados: Inicio = ${new_start}% | Parada = ${new_end}%"
                    fi
                else
                    if [[ "${UI_LANG}" == "en" ]]; then
                        tui_msgbox "${L_MSG_LIM_ERR_TITLE}" "Invalid values (${new_start}% - ${new_end}%). Ensure Start < Stop."
                    else
                        tui_msgbox "${L_MSG_LIM_ERR_TITLE}" "Valores invalidos (${new_start}% - ${new_end}%). Verifique se Inicio < Parada."
                    fi
                fi
                ;;

            (4)
                check_root
                if force_discharge_cmd >/dev/null 2>&1; then
                    tui_msgbox "${L_MSG_FD_OK_TITLE}" "${L_MSG_FD_OK_BODY}"
                else
                    tui_msgbox "${L_MSG_FD_ERR_TITLE}" "${L_MSG_FD_ERR_BODY}"
                fi
                ;;

            (5)
                check_root
                if tui_yesno "${L_YN_RESTORE_TITLE}" "${L_YN_RESTORE_PROMPT}"; then
                    restore_defaults "true" >/dev/null 2>&1
                    tui_msgbox "${L_MSG_RESTORE_TITLE}" "${L_MSG_RESTORE_BODY}"
                fi
                ;;

            (6)
                if [[ "${UI_LANG}" == "en" ]]; then
                    UI_LANG="pt"
                else
                    UI_LANG="en"
                fi
                if [[ $EUID -eq 0 ]]; then
                    save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "${AUTO_DISCHARGE}" "${DELL_MODE}" "${UI_LANG}"
                fi
                ;;
        esac
    done
}

# ========================== INTEGRITY TESTS =================================

run_test() {
    load_config
    echo "==============================================================="
    echo "  Integrity Test — ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "==============================================================="
    echo

    local passed=0
    local failed=0
    local info_count=0

    echo -n "  [1/5] Battery detected............................ "
    if [[ -d "${BAT_PATH}" ]]; then
        echo "[PASS]"
        passed=$(( passed + 1 ))
    else
        echo "[FAIL]"
        failed=$(( failed + 1 ))
    fi

    echo -n "  [2/5] Vendor recognized........................... "
    local v
    v=$(detect_vendor)
    if [[ "${v}" != "generic" ]]; then
        echo "[PASS] ($(detect_vendor_display))"
        passed=$(( passed + 1 ))
    else
        echo "[INFO] ($(detect_vendor_display))"
        info_count=$(( info_count + 1 ))
    fi

    echo -n "  [3/5] Threshold interface available............... "
    if [[ -e "${END_THRESHOLD_FILE}" || -f "${WMI_MODE_FILE}" ]] || command -v smbios-battery-ctl >/dev/null 2>&1 || command -v cctk >/dev/null 2>&1; then
        echo "[PASS]"
        passed=$(( passed + 1 ))
    else
        echo "[FAIL]"
        failed=$(( failed + 1 ))
    fi

    echo -n "  [4/5] force-discharge support..................... "
    if is_force_discharge_supported; then
        echo "[PASS]"
        passed=$(( passed + 1 ))
    else
        echo "[INFO] (not supported)"
        info_count=$(( info_count + 1 ))
    fi

    local init_name
    init_name=$(detect_init_display)
    echo -n "  [5/5] ${init_name} service active"
    local test_label="  [5/5] ${init_name} service active"
    local pad_count=$(( 52 - ${#test_label} ))
    if (( pad_count < 1 )); then pad_count=1; fi
    printf '%*s ' "${pad_count}" '' | tr ' ' '.'
    if is_init_service_active; then
        echo "[PASS]"
        passed=$(( passed + 1 ))
    else
        echo "[FAIL / INACTIVE]"
        failed=$(( failed + 1 ))
    fi

    echo
    echo "==============================================================="
    if (( info_count > 0 )); then
        echo "  Result: ${passed} passed, ${info_count} info, ${failed} failed"
    else
        echo "  Result: ${passed} passed, ${failed} failed"
    fi
    echo "==============================================================="

    return $(( failed > 0 ? 1 : 0 ))
}

# ========================== SET THRESHOLDS (CLI) ============================

set_thresholds_cmd() {
    check_root
    load_config
    local start_val="$1"
    local end_val="$2"

    if apply_thresholds "${start_val}" "${end_val}"; then
        save_config "${start_val}" "${end_val}" "${AUTO_DISCHARGE}" "custom" "${UI_LANG}"
    else
        return 1
    fi
}

# ========================== USAGE ===========================================

show_usage() {
    load_config
    local init_name
    init_name=$(detect_init_display)
    if [[ "${UI_LANG}" == "en" ]]; then
        cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Universal Intelligent Battery Manager for Linux (Lenovo, ASUS, Dell)
Supported Inits: systemd, OpenRC, Runit, dinit, SysVinit [Detected: ${init_name}]

QUICK USAGE:
    sudo $(basename "$0")                  Open interactive TUI menu
    sudo $(basename "$0") on               Enable Smart Auto-Discharge
    sudo $(basename "$0") off              Disable Smart Auto-Discharge
    sudo $(basename "$0") status           Show detailed battery status
    sudo $(basename "$0") set <limit> [or: <start> <end>] Set charge limits (e.g. set 80 or set 75 80)
    sudo $(basename "$0") lang <pt|en>     Change interface language

OTHER COMMANDS:
    menu                   Open interactive TUI menu
    auto-discharge <on|off>Enable or disable smart auto-discharge
    discharge              Force immediate discharge on AC down to start limit
    stop-discharge         Cancel forced discharge and return to auto mode
    restore                Restore factory defaults (100%)
    check                  Verify hardware compatibility
    test                   Run 5-step system integrity tests
    install                Install universal manager and enable system service
    enable                 Re-enable system service (${init_name})
    disable                Temporarily disable service and restore 100%
    stop                   Stop running service/daemon
    remove                 Completely uninstall script, config, and service
    help                   Show this help message
EOF
    else
        cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Gerenciador Inteligente de Bateria Universal para Linux (Lenovo, ASUS, Dell)
Inits Suportados: systemd, OpenRC, Runit, dinit, SysVinit [Detectado: ${init_name}]

USO RAPIDO:
    sudo $(basename "$0")                  Abre o menu interativo TUI
    sudo $(basename "$0") on               Ativa a Descarga Inteligente
    sudo $(basename "$0") off              Desativa a Descarga Inteligente
    sudo $(basename "$0") status           Exibe status detalhado
    sudo $(basename "$0") set <limite> [ou: <ini> <fim>]  Ajusta limites (ex: set 80 ou set 75 80)
    sudo $(basename "$0") lang <pt|en>     Altera o idioma da interface

OUTROS COMANDOS:
    menu                   Abre o menu interativo TUI
    auto-discharge <on|off>Ativa ou desativa a descarga inteligente
    discharge              Forca descarga imediata na tomada ate o inicio
    stop-discharge         Cancela a descarga forcada e volta ao modo auto
    restore                Restaura padrao de fabrica (100%)
    check                  Verifica compatibilidade do hardware
    test                   Executa bateria de testes do sistema
    install                Instala o gerenciador universal e ativa o servico
    enable                 Reabilita o servico no sistema (${init_name})
    disable                Desabilita o servico temporariamente
    stop                   Para o servico/daemon em execucao
    remove                 Desinstala completamente o script e servico
    help                   Exibe esta ajuda
EOF
    fi
}

# ========================== MAIN ============================================

main() {
    load_config
    local command="${1:-menu}"

    case "${command}" in
        (menu)
            show_interactive_menu
            ;;
        (on)
            set_auto_discharge_cmd "on"
            ;;
        (off)
            set_auto_discharge_cmd "off"
            ;;
        (auto-discharge)
            set_auto_discharge_cmd "${2:-status}"
            ;;
        (lang|language|idioma)
            set_language_cmd "${2:-toggle}"
            ;;
        (check)
            check_hardware || true
            ;;
        (apply)
            check_root
            local start_arg="${START_THRESHOLD}"
            local end_arg="${END_THRESHOLD}"
            if [[ $# -eq 2 ]]; then
                end_arg="$2"
                start_arg=$(calculate_default_start "${end_arg}")
            elif [[ $# -ge 3 ]]; then
                start_arg="$2"
                end_arg="$3"
            fi
            apply_thresholds "${start_arg}" "${end_arg}"
            ;;
        (set)
            if [[ $# -lt 2 ]]; then
                log_error "Usage: sudo $(basename "$0") set <limit> [or: set <start> <end>]"
                log_error "Example: sudo $(basename "$0") set 80   (or: set 75 80)"
                exit 1
            fi
            if [[ $# -eq 2 ]]; then
                local target_end="$2"
                local target_start
                target_start=$(calculate_default_start "${target_end}")
                set_thresholds_cmd "${target_start}" "${target_end}"
            else
                set_thresholds_cmd "$2" "$3"
            fi
            ;;
        (daemon)
            run_daemon
            ;;
        (stop)
            check_root
            stop_init_service
            ;;
        (post-stop)
            stop_daemon_action
            ;;
        (discharge)
            force_discharge_cmd
            ;;
        (stop-discharge)
            stop_discharge_cmd
            ;;
        (restore)
            check_root
            restore_defaults "true"
            ;;
        (status)
            show_status
            ;;
        (test)
            run_test || true
            ;;
        (install)
            install_service
            ;;
        (enable)
            enable_service
            ;;
        (disable)
            disable_service
            ;;
        (remove)
            remove_service
            ;;
        (help|--help|-h)
            show_usage
            ;;
        (*)
            log_error "Unknown command: ${command}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"

