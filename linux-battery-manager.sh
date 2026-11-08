#!/usr/bin/env bash
# ============================================================================
# linux-battery-manager (v2.2.0 Universal)
# Universal Intelligent Battery Charge Limit & Auto-Discharge Manager for Linux
# Natively compatible with Lenovo (ThinkPad), ASUS, and Dell / Alienware
# Don't work with HP! (i don´t know, i didn't use with a hp laptop)
#
# Features:
#   - 100% automatic hardware vendor detection
#   - Start and Stop charge threshold control
#   - Smart AC Auto-Discharge (via charge_behaviour)
#   - Centered, Zero-Latency Native TUI (Zero emojis, universal compatibility)
#   - Built-in Bilingual Interface (Portuguese & English with persistent config)
#   - Background systemd daemon with post-suspend persistence
#   - Fast CLI commands (on, off, status, set, menu, lang)
#
# Author: Alan Schaffer
# License: MIT
# ============================================================================

set -euo pipefail

# ========================== GENERAL CONFIGURATION ===========================
readonly SCRIPT_NAME="linux-battery-manager"
readonly SCRIPT_VERSION="2.2.0"

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
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly SCRIPT_INSTALL_PATH="/usr/local/bin/linux-battery-manager"
readonly SCRIPT_ALIAS_PATH="/usr/local/bin/linux_battery_manager"
readonly BACKUP_DIR="/etc/linux-battery-manager/backups"

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

# ========================== VENDOR DETECTION ================================

detect_vendor() {
    local vendor
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
    case "${vendor,,}" in
        *lenovo*)           echo "lenovo" ;;
        *asus*|*asustek*)   echo "asus" ;;
        *dell*|*alienware*) echo "dell" ;;
        *)                  echo "generic" ;;
    esac
}

detect_vendor_display() {
    local v
    v=$(detect_vendor)
    case "${v}" in
        lenovo)  echo "Lenovo ThinkPad" ;;
        asus)    echo "ASUS" ;;
        dell)    echo "Dell / Alienware" ;;
        generic)
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

    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONF_FILE}" 2>/dev/null || true
    elif [[ -f "${LEGACY_CONF_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${LEGACY_CONF_FILE}" 2>/dev/null || true
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
        L_IN_START_TITLE="Start Threshold"
        L_IN_START_PROMPT="Enter % to START charging (e.g. 75):"
        L_IN_END_TITLE="Stop Threshold"
        L_IN_END_PROMPT="Enter % to STOP charging (e.g. 80):"
        L_MSG_LIM_OK_TITLE="Success"
        L_MSG_LIM_ERR_TITLE="Validation Error"
        L_MSG_FD_OK_TITLE="Immediate Discharge"
        L_MSG_FD_OK_BODY="Force-discharge mode activated on AC down to ${START_THRESHOLD}%."
        L_MSG_FD_ERR_TITLE="Notice"
        L_MSG_FD_ERR_BODY="Could not activate force-discharge on this hardware."
        L_YN_RESTORE_TITLE="Confirm Restore"
        L_YN_RESTORE_PROMPT="Restore charge thresholds to factory defaults (100%)?"
        L_MSG_RESTORE_TITLE="Restored"
        L_MSG_RESTORE_BODY="Thresholds restored to 100% successfully."
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
        L_IN_START_TITLE="Limite de Inicio"
        L_IN_START_PROMPT="Digite a % para INICIAR a recarga (ex: 75):"
        L_IN_END_TITLE="Limite de Parada"
        L_IN_END_PROMPT="Digite a % para PARAR a recarga (ex: 80):"
        L_MSG_LIM_OK_TITLE="Sucesso"
        L_MSG_LIM_ERR_TITLE="Erro de Validacao"
        L_MSG_FD_OK_TITLE="Descarga Imediata"
        L_MSG_FD_OK_BODY="Modo force-discharge ativado na tomada ate atingir ${START_THRESHOLD}%."
        L_MSG_FD_ERR_TITLE="Aviso"
        L_MSG_FD_ERR_BODY="Nao foi possivel ativar a descarga forcada neste hardware."
        L_YN_RESTORE_TITLE="Confirmar Restauracao"
        L_YN_RESTORE_PROMPT="Deseja restaurar os limites para o padrao de fabrica (100%)?"
        L_MSG_RESTORE_TITLE="Restaurado"
        L_MSG_RESTORE_BODY="Limites restaurados para 100% com sucesso."
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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        if [[ "${UI_LANG:-pt}" == "en" ]]; then
            log_error "This command requires root privileges. Please run with 'sudo'."
        else
            log_error "Este comando requer privilegios de root. Execute com 'sudo'."
        fi
        exit 1
    fi
}

is_ac_online() {
    for psy in /sys/class/power_supply/*; do
        if [[ -d "${psy}" ]]; then
            local type online
            type=$(cat "${psy}/type" 2>/dev/null || echo "")
            online=$(cat "${psy}/online" 2>/dev/null || echo "0")
            if [[ ("${type}" == "Mains" || "${type}" == "USB") && "${online}" == "1" ]]; then
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
        echo "${behaviour}" > "${BEHAVIOUR_FILE}"
        log_info "Charge behaviour set to: ${behaviour}"
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
        ((errors += 1))
    fi
    echo

    if [[ -e "${END_THRESHOLD_FILE}" ]]; then
        echo "[OK] charge_control_end_threshold AVAILABLE (Value: $(cat "${END_THRESHOLD_FILE}" 2>/dev/null || echo '?')%)"
    else
        if [[ "${vendor}" == "dell" && "$(detect_dell_backend)" != "none" ]]; then
            echo "[INFO] charge_control_end_threshold available via Dell SMBIOS/WMI"
        else
            echo "[ERR] charge_control_end_threshold NOT available"
            ((errors += 1))
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
    if [[ $errors -eq 0 ]]; then
        echo "  [OK] Hardware 100% compatible!"
    else
        echo "  [WARN] Warnings or errors found. Check messages above."
    fi
    echo "==============================================================="
    echo

    return $errors
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
        lenovo)
            if (( start_val < 0 || start_val > 99 || end_val < 1 || end_val > 100 )); then
                log_error "Invalid limits for ThinkPad (start: 0-99, end: 1-100)."
                return 1
            fi
            if (( start_val > 0 && start_val >= end_val )); then
                log_error "start_threshold (${start_val}%) must be less than end_threshold (${end_val}%)."
                return 1
            fi

            local cur_start="0"
            [[ -e "${START_THRESHOLD_FILE}" ]] && cur_start=$(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo "0")
            [[ "${cur_start}" =~ ^[0-9]+$ ]] || cur_start="0"

            if [[ -e "${START_THRESHOLD_FILE}" ]]; then
                if (( end_val < cur_start )); then
                    echo "${start_val}" > "${START_THRESHOLD_FILE}"
                    echo "${end_val}" > "${END_THRESHOLD_FILE}"
                else
                    echo "${end_val}" > "${END_THRESHOLD_FILE}"
                    echo "${start_val}" > "${START_THRESHOLD_FILE}"
                fi
            elif [[ -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${end_val}" > "${END_THRESHOLD_FILE}"
            else
                log_error "Threshold files not found in ${BAT_PATH}."
                return 1
            fi
            log_info "[OK] ThinkPad limits applied: Start=${start_val}% | Stop=${end_val}%"
            ;;

        asus)
            if (( end_val < 1 || end_val > 100 )); then
                log_error "Invalid ASUS limit (1-100)."
                return 1
            fi
            if [[ -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${end_val}" > "${END_THRESHOLD_FILE}"
                log_info "[OK] ASUS limit applied: Stop=${end_val}% (Resume ~${start_val}%)"
            else
                log_error "File ${END_THRESHOLD_FILE} not found."
                return 1
            fi
            ;;

        dell)
            if (( start_val < 50 || start_val > 95 || end_val < 55 || end_val > 100 || start_val >= end_val )); then
                log_error "Invalid Dell limits (Start: 50-95, Stop: 55-100, Start < Stop)."
                return 1
            fi
            local dell_be
            dell_be=$(detect_dell_backend)
            case "${dell_be}" in
                libsmbios)
                    smbios-battery-ctl --set-custom-charge-interval "${start_val}" "${end_val}" >/dev/null 2>&1 || \
                    smbios-battery-ctl "--set-custom-charge-interval=${start_val}-${end_val}" >/dev/null 2>&1 || true
                    smbios-battery-ctl --set-charging-mode=custom >/dev/null 2>&1 || true
                    log_info "[OK] Dell limits applied via libsmbios (${start_val}% - ${end_val}%)."
                    ;;
                dell_wmi_sysman)
                    if [[ -f "${WMI_START_FILE}" && -f "${WMI_STOP_FILE}" && -f "${WMI_MODE_FILE}" ]]; then
                        echo "Custom" > "${WMI_MODE_FILE}" 2>/dev/null || true
                        echo "${start_val}" > "${WMI_START_FILE}" 2>/dev/null || true
                        echo "${end_val}" > "${WMI_STOP_FILE}" 2>/dev/null || true
                        log_info "[OK] Dell limits applied via dell_wmi_sysman."
                    fi
                    ;;
                sysfs)
                    [[ -e "${START_THRESHOLD_FILE}" ]] && echo "${start_val}" > "${START_THRESHOLD_FILE}" 2>/dev/null || true
                    [[ -e "${END_THRESHOLD_FILE}" ]] && echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || true
                    log_info "[OK] Dell limits applied via sysfs."
                    ;;
                *)
                    if [[ -e "${END_THRESHOLD_FILE}" ]]; then
                        echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || true
                    fi
                    ;;
            esac
            ;;

        *)
            if (( start_val < 0 || start_val > 99 || end_val < 1 || end_val > 100 || (start_val > 0 && start_val >= end_val) )); then
                log_error "Invalid limits (start: 0-99, end: 1-100, start < end)."
                return 1
            fi
            if [[ -e "${START_THRESHOLD_FILE}" && -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${start_val}" > "${START_THRESHOLD_FILE}" 2>/dev/null || true
                echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || true
            elif [[ -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || true
            fi
            log_info "[OK] Generic limits applied: ${start_val}% - ${end_val}%"
            ;;
    esac

    return 0
}

restore_defaults() {
    log_info "Restoring factory default settings (100%)..."
    if [[ -e "${BEHAVIOUR_FILE}" ]]; then
        echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
    fi

    local vendor
    vendor=$(detect_vendor)

    case "${vendor}" in
        dell)
            if command -v smbios-battery-ctl >/dev/null 2>&1; then
                smbios-battery-ctl --set-charging-mode=standard >/dev/null 2>&1 || true
            elif [[ -f "${WMI_MODE_FILE}" ]]; then
                echo "Standard" > "${WMI_MODE_FILE}" 2>/dev/null || true
            fi
            ;;
    esac

    if [[ -e "${END_THRESHOLD_FILE}" ]]; then
        echo 100 > "${END_THRESHOLD_FILE}" 2>/dev/null || true
    fi
    if [[ -e "${START_THRESHOLD_FILE}" ]]; then
        echo 0 > "${START_THRESHOLD_FILE}" 2>/dev/null || true
    fi

    log_info "[OK] Thresholds restored to factory default (100%)."
}

# ========================== SMART AUTO-DISCHARGE DAEMON =====================

run_daemon() {
    check_root
    log_info "Starting ${SCRIPT_NAME} continuous monitoring daemon..."

    local discharge_in_progress=0

    cleanup_daemon() {
        log_info "Daemon stopped. Ensuring 'auto' charge behaviour..."
        if is_force_discharge_supported; then
            echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
        fi
        exit 0
    }
    trap cleanup_daemon SIGINT SIGTERM SIGHUP EXIT

    load_config
    apply_thresholds "${START_THRESHOLD}" "${END_THRESHOLD}" || true

    while true; do
        load_config

        local cur_cap
        cur_cap=$(cat "${BAT_PATH}/capacity" 2>/dev/null || echo "")

        if [[ -n "${cur_cap}" && "${cur_cap}" =~ ^[0-9]+$ ]]; then
            if [[ -e "${END_THRESHOLD_FILE}" ]]; then
                local cur_sys_end
                cur_sys_end=$(cat "${END_THRESHOLD_FILE}" 2>/dev/null || echo "")
                if [[ "${cur_sys_end}" != "${END_THRESHOLD}" ]]; then
                    log_info "Sysfs threshold changed (${cur_sys_end} -> ${END_THRESHOLD}). Re-applying..."
                    apply_thresholds "${START_THRESHOLD}" "${END_THRESHOLD}" || true
                fi
            fi

            if [[ "${AUTO_DISCHARGE:-true}" == "true" ]] && is_force_discharge_supported; then
                local current_behaviour
                current_behaviour=$(get_charge_behaviour)

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

                if (( cur_cap <= 20 )) && [[ "$(get_charge_behaviour)" == "force-discharge" ]]; then
                    log_warn "SAFETY: Low battery (${cur_cap}%). Aborting force-discharge."
                    set_charge_behaviour "auto"
                    discharge_in_progress=0
                fi
            else
                if [[ "$(get_charge_behaviour)" == "force-discharge" ]]; then
                    set_charge_behaviour "auto"
                    discharge_in_progress=0
                fi
            fi
        fi

        sleep 20 &
        wait $! || true
    done
}

stop_daemon_action() {
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
        on|enable|true|1|ativar|ativado)
            save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "true" "${DELL_MODE}" "${UI_LANG}"
            log_info "[OK] Smart Auto-Discharge ENABLED."
            ;;
        off|disable|false|0|desativar|desativado)
            save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "false" "${DELL_MODE}" "${UI_LANG}"
            if is_force_discharge_supported; then
                echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
            fi
            log_info "[OK] Smart Auto-Discharge DISABLED."
            ;;
        toggle)
            if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
                set_auto_discharge_cmd "off"
            else
                set_auto_discharge_cmd "on"
            fi
            ;;
        status)
            log_info "Auto-Discharge Status: ${AUTO_DISCHARGE}"
            ;;
        *)
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
        en|english|ingles)
            UI_LANG="en"
            ;;
        pt|pt-br|portugues|portuguese)
            UI_LANG="pt"
            ;;
        toggle)
            if [[ "${UI_LANG}" == "en" ]]; then
                UI_LANG="pt"
            else
                UI_LANG="en"
            fi
            ;;
        *)
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

    if (( cur_cap <= START_THRESHOLD )); then
        log_info "Battery is already at ${cur_cap}% (<= limit ${START_THRESHOLD}%). Discharge not needed."
        return 0
    fi

    log_info "Forcing immediate discharge on AC (from ${cur_cap}% down to ${START_THRESHOLD}%)..."
    set_charge_behaviour "force-discharge"
}

stop_discharge_cmd() {
    check_root
    if ! is_force_discharge_supported; then
        log_error "Current hardware does not support 'charge_behaviour'."
        return 1
    fi
    log_info "Cancelling forced discharge. Returning to 'auto' mode..."
    set_charge_behaviour "auto"
}

# ========================== INSTALLATION / MIGRATION ========================

install_service() {
    check_root
    load_config

    echo "Installing ${SCRIPT_NAME} v${SCRIPT_VERSION}..."
    echo

    if ! check_hardware; then
        echo "Hardware warnings detected, proceeding with installation..."
    fi
    echo

    # Clean up legacy services (including old gerenciador-bateria.service)
    for s in "${LEGACY_SERVICES[@]}"; do
        if systemctl is-active --quiet "${s}" 2>/dev/null; then
            log_info "Stopping legacy service: ${s}"
            systemctl stop "${s}" 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet "${s}" 2>/dev/null; then
            log_info "Disabling legacy service: ${s}"
            systemctl disable "${s}" 2>/dev/null || true
        fi
        rm -f "/etc/systemd/system/${s}" 2>/dev/null || true
    done

    # Clean up old binaries
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

    cp "$0" "${SCRIPT_INSTALL_PATH}"
    chmod 755 "${SCRIPT_INSTALL_PATH}"
    ln -sf "${SCRIPT_INSTALL_PATH}" "${SCRIPT_ALIAS_PATH}"
    log_info "Binary installed at: ${SCRIPT_INSTALL_PATH} (and alias ${SCRIPT_ALIAS_PATH})"

    cat > "${SERVICE_FILE}" << 'UNIT_EOF'
[Unit]
Description=Universal Linux Battery Charge Limit & Auto-Discharge Manager
Documentation=https://github.com
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=simple
Restart=always
RestartSec=10s
ExecStart=/usr/local/bin/linux-battery-manager daemon
ExecStop=/usr/local/bin/linux-battery-manager stop

ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=no
ReadWritePaths=-/sys/class/power_supply -/sys/devices -/sys/class/firmware-attributes -/etc

StandardOutput=journal
StandardError=journal
SyslogIdentifier=linux-battery-manager

[Install]
WantedBy=multi-user.target
UNIT_EOF

    log_info "systemd service created: ${SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    log_info "Service enabled and started successfully."

    echo
    echo "==============================================================="
    echo "  [OK] Installation completed successfully!"
    echo "  Hardware detected: $(detect_vendor_display)"
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
    log_info "Disabling service..."

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}"
        log_info "Service stopped."
    fi

    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl disable "${SERVICE_NAME}"
        log_info "Service disabled."
    fi

    restore_defaults
    echo
    log_info "[OK] Service disabled and limits restored to 100%."
    log_info "To re-enable: sudo linux-battery-manager enable"
}

enable_service() {
    check_root
    if [[ ! -f "${SERVICE_FILE}" ]]; then
        log_error "Service not installed. Run 'install' first."
        exit 1
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    log_info "[OK] Service enabled and started."
}

remove_service() {
    check_root
    echo "Removing ${SCRIPT_NAME}..."
    echo

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}"
    fi

    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl disable "${SERVICE_NAME}"
    fi

    restore_defaults

    rm -f "${SERVICE_FILE}"
    rm -f "${SCRIPT_INSTALL_PATH}"
    rm -f "${SCRIPT_ALIAS_PATH}"
    rm -f "${CONF_FILE}"
    rm -f "${LEGACY_CONF_FILE}"

    for b in "${LEGACY_BINARIES[@]}"; do
        rm -f "${b}" 2>/dev/null || true
    done

    systemctl daemon-reload
    log_info "systemd reloaded."

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
        echo "systemd Service (${SERVICE_NAME}):"
        if [[ -f "${SERVICE_FILE}" ]]; then
            echo "  Installed:        [YES]"
            echo "  Enabled on boot:  $(systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null && echo '[YES]' || echo '[NO]')"
            echo "  Active (running): $(systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null && echo '[YES]' || echo '[NO]')"
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
        echo "Servico systemd (${SERVICE_NAME}):"
        if [[ -f "${SERVICE_FILE}" ]]; then
            echo "  Instalado:        [SIM]"
            echo "  Habilitado boot:  $(systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null && echo '[SIM]' || echo '[NAO]')"
            echo "  Ativo (rodando):  $(systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null && echo '[SIM]' || echo '[NAO]')"
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

# Calculates exact terminal center safely without triggering set -e on arithmetic
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

# Draws a row with exact left/right borders anchored by ANSI column coordinates
tui_draw_row() {
    local r="$1"
    local content="${2:-}"
    local right_col=$(( TUI_COL + BOX_WIDTH - 1 ))
    printf '\033[%d;%dH│%*s│\033[%d;%dH%b\033[%d;%dH│' \
        "${r}" "${TUI_COL}" "${INNER_WIDTH}" "" \
        "${r}" "$(( TUI_COL + 2 ))" "${content}" \
        "${r}" "${right_col}" > /dev/tty
}

# Draws a selectable menu item with full-width inverse highlight bar
tui_draw_item() {
    local r="$1"
    local selected_flag="$2"
    local text="$3"
    local right_col=$(( TUI_COL + BOX_WIDTH - 1 ))
    if (( selected_flag == 1 )); then
        printf '\033[%d;%dH│  \033[7;1m%-62s\033[0m  │' \
            "${r}" "${TUI_COL}" " ${text}" > /dev/tty
        printf '\033[%d;%dH│' "${r}" "${right_col}" > /dev/tty
    else
        printf '\033[%d;%dH│  %-62s  │' \
            "${r}" "${TUI_COL}" " ${text}" > /dev/tty
        printf '\033[%d;%dH│' "${r}" "${right_col}" > /dev/tty
    fi
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
        if ! IFS= read -rsn1 -t 0.02 k2 < /dev/tty 2>/dev/null || [[ -z "${k2}" ]]; then
            LAST_KEY="ESC"
            return 0
        fi
        if [[ "${k2}" == "[" || "${k2}" == "O" ]]; then
            IFS= read -rsn1 -t 0.02 k3 < /dev/tty 2>/dev/null || true
            case "${k3}" in
                A) LAST_KEY="UP" ;;
                B) LAST_KEY="DOWN" ;;
                C) LAST_KEY="RIGHT" ;;
                D) LAST_KEY="LEFT" ;;
                *) LAST_KEY="OTHER_SEQ" ;;
            esac
            return 0
        fi
        LAST_KEY="ESC"
        return 0
    fi

    LAST_KEY="${k1}"
}

cleanup_tui() {
    printf '\033[?25h\033[0m' > /dev/tty 2>/dev/null || true
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
            ENTER|ESC|" "|q|Q) break ;;
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
            ESC)
                return 1
                ;;
            ENTER)
                INPUT_RESULT="${buf}"
                return 0
                ;;
            $'\x7f'|$'\x08')
                if [[ -n "${buf}" ]]; then
                    buf="${buf%?}"
                fi
                ;;
            [0-9])
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
            LEFT|RIGHT|UP|DOWN|h|l|j|k|$'\t')
                sel=$(( 1 - sel ))
                ;;
            y|Y|s|S)
                return 0
                ;;
            n|N|q|Q|ESC)
                return 1
                ;;
            ENTER)
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
            ESC|q|Q)
                cleanup_tui
                printf '\033[2J\033[H' > /dev/tty
                exit 0
                ;;
            ENTER|" ")
                break
                ;;
        esac
    done
}

show_interactive_menu() {
    # Verify if /dev/tty is accessible; otherwise fallback to status output
    if ! ( : > /dev/tty ) 2>/dev/null; then
        show_status
        exit 0
    fi

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
            ESC|q|Q|0)
                cleanup_tui
                printf '\033[2J\033[H' > /dev/tty
                exit 0
                ;;
            UP|k|K)
                selected=$(( (selected - 1 + total_items) % total_items ))
                continue
                ;;
            DOWN|j|J)
                selected=$(( (selected + 1) % total_items ))
                continue
                ;;
            1) selected=0; action="1" ;;
            2) selected=1; action="2" ;;
            3) selected=2; action="3" ;;
            4) selected=3; action="4" ;;
            5) selected=4; action="5" ;;
            6|l|L) selected=5; action="6" ;;
            ENTER)
                case "${selected}" in
                    0) action="1" ;;
                    1) action="2" ;;
                    2) action="3" ;;
                    3) action="4" ;;
                    4) action="5" ;;
                    5) action="6" ;;
                    6)
                        cleanup_tui
                        printf '\033[2J\033[H' > /dev/tty
                        exit 0
                        ;;
                esac
                ;;
            *)
                continue
                ;;
        esac

        case "${action}" in
            1)
                tui_show_status_box
                ;;

            2)
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

            3)
                check_root
                local new_start="" new_end=""
                if ! tui_inputbox "${L_IN_START_TITLE}" "${L_IN_START_PROMPT}" "${START_THRESHOLD}"; then
                    continue
                fi
                new_start="${INPUT_RESULT}"

                if ! tui_inputbox "${L_IN_END_TITLE}" "${L_IN_END_PROMPT}" "${END_THRESHOLD}"; then
                    continue
                fi
                new_end="${INPUT_RESULT}"

                if apply_thresholds "${new_start}" "${new_end}" >/dev/null 2>&1; then
                    save_config "${new_start}" "${new_end}" "${AUTO_DISCHARGE}" "${DELL_MODE}" "${UI_LANG}"
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

            4)
                check_root
                if force_discharge_cmd >/dev/null 2>&1; then
                    tui_msgbox "${L_MSG_FD_OK_TITLE}" "${L_MSG_FD_OK_BODY}"
                else
                    tui_msgbox "${L_MSG_FD_ERR_TITLE}" "${L_MSG_FD_ERR_BODY}"
                fi
                ;;

            5)
                check_root
                if tui_yesno "${L_YN_RESTORE_TITLE}" "${L_YN_RESTORE_PROMPT}"; then
                    restore_defaults >/dev/null 2>&1
                    tui_msgbox "${L_MSG_RESTORE_TITLE}" "${L_MSG_RESTORE_BODY}"
                fi
                ;;

            6)
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

    echo -n "  [1/5] Battery detected............................ "
    if [[ -d "${BAT_PATH}" ]]; then
        echo "[PASS]"
        ((passed += 1))
    else
        echo "[FAIL]"
        ((failed += 1))
    fi

    echo -n "  [2/5] Vendor recognized........................... "
    local v
    v=$(detect_vendor)
    if [[ "${v}" != "generic" ]]; then
        echo "[PASS] ($(detect_vendor_display))"
        ((passed += 1))
    else
        echo "[INFO] ($(detect_vendor_display))"
    fi

    echo -n "  [3/5] Threshold interface available............... "
    if [[ -e "${END_THRESHOLD_FILE}" || -f "${WMI_MODE_FILE}" ]] || command -v smbios-battery-ctl >/dev/null 2>&1; then
        echo "[PASS]"
        ((passed += 1))
    else
        echo "[FAIL]"
        ((failed += 1))
    fi

    echo -n "  [4/5] force-discharge support..................... "
    if is_force_discharge_supported; then
        echo "[PASS]"
        ((passed += 1))
    else
        echo "[INFO] (not supported)"
    fi

    echo -n "  [5/5] systemd service active...................... "
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo "[PASS]"
        ((passed += 1))
    else
        echo "[FAIL / INACTIVE]"
        ((failed += 1))
    fi

    echo
    echo "==============================================================="
    echo "  Result: ${passed} passed, ${failed} failed"
    echo "==============================================================="

    return ${failed}
}

# ========================== SET THRESHOLDS (CLI) ============================

set_thresholds_cmd() {
    check_root
    load_config
    local start_val="$1"
    local end_val="$2"

    if apply_thresholds "${start_val}" "${end_val}"; then
        save_config "${start_val}" "${end_val}" "${AUTO_DISCHARGE}" "${DELL_MODE}" "${UI_LANG}"
    else
        return 1
    fi
}

# ========================== USAGE ===========================================

show_usage() {
    load_config
    if [[ "${UI_LANG}" == "en" ]]; then
        cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Universal Intelligent Battery Manager for Linux (Lenovo, ASUS, Dell)

QUICK USAGE:
    sudo $(basename "$0")                  Open interactive TUI menu
    sudo $(basename "$0") on               Enable Smart Auto-Discharge
    sudo $(basename "$0") off              Disable Smart Auto-Discharge
    sudo $(basename "$0") status           Show detailed battery status
    sudo $(basename "$0") set <start> <end>Set charge limits (e.g. set 75 80)
    sudo $(basename "$0") lang <pt|en>     Change interface language

OTHER COMMANDS:
    menu                   Open interactive TUI menu
    auto-discharge <on|off>Enable or disable smart auto-discharge
    discharge              Force immediate discharge on AC down to start limit
    stop-discharge         Cancel forced discharge and return to auto mode
    restore                Restore factory defaults (100%)
    check                  Verify hardware compatibility
    test                   Run 5-step system integrity tests
    install                Install universal manager and enable systemd service
    enable                 Re-enable systemd service
    disable                Temporarily disable service and restore 100%
    remove                 Completely uninstall script, config, and service
    help                   Show this help message
EOF
    else
        cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Gerenciador Inteligente de Bateria Universal para Linux (Lenovo, ASUS, Dell)

USO RAPIDO:
    sudo $(basename "$0")                  Abre o menu interativo TUI
    sudo $(basename "$0") on               Ativa a Descarga Inteligente
    sudo $(basename "$0") off              Desativa a Descarga Inteligente
    sudo $(basename "$0") status           Exibe status detalhado
    sudo $(basename "$0") set <ini> <fim>  Ajusta limites (ex: set 75 80)
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
    enable                 Reabilita o servico no systemd
    disable                Desabilita o servico temporariamente
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
        menu)
            show_interactive_menu
            ;;
        on)
            set_auto_discharge_cmd "on"
            ;;
        off)
            set_auto_discharge_cmd "off"
            ;;
        auto-discharge)
            set_auto_discharge_cmd "${2:-status}"
            ;;
        lang|language|idioma)
            set_language_cmd "${2:-toggle}"
            ;;
        check)
            check_hardware || true
            ;;
        apply)
            check_root
            local end_arg="${2:-${END_THRESHOLD}}"
            local start_arg="${3:-${START_THRESHOLD}}"
            apply_thresholds "${start_arg}" "${end_arg}"
            ;;
        set)
            if [[ $# -lt 3 ]]; then
                log_error "Usage: sudo $(basename "$0") set <start> <end>"
                log_error "Example: sudo $(basename "$0") set 75 80"
                exit 1
            fi
            set_thresholds_cmd "$2" "$3"
            ;;
        daemon)
            run_daemon
            ;;
        stop)
            stop_daemon_action
            ;;
        discharge)
            force_discharge_cmd
            ;;
        stop-discharge)
            stop_discharge_cmd
            ;;
        restore)
            check_root
            restore_defaults
            ;;
        status)
            show_status
            ;;
        test)
            run_test || true
            ;;
        install)
            install_service
            ;;
        enable)
            enable_service
            ;;
        disable)
            disable_service
            ;;
        remove)
            remove_service
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"