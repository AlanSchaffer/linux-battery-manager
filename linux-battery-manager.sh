#!/usr/bin/env bash
# ============================================================================
# gerenciador-bateria.sh (v2.1.0 Universal)
# Gerenciador Inteligente de Bateria para Linux
# Compatível nativamente com Lenovo (ThinkPad), ASUS e Dell / Alienware
#
# Recursos:
#   • Detecção 100% automática da fabricante do hardware
#   • Controle de limites de início e parada (Start / End Thresholds)
#   • Descarga Inteligente na Tomada (Auto-Discharge via charge_behaviour)
#   • TUI Nativa de Baixa Latência (Setas, Vim keys, Atalhos e ESC instantâneo)
#   • Daemon em segundo plano no systemd com persistência pós-suspensão
#   • Comandos ultrarrápidos e intuitivos (on, off, status, set, menu)
#
# Autor: Alan
# Licença: MIT
# ============================================================================

set -euo pipefail

# ========================== CONFIGURAÇÃO GERAL ==============================
readonly SCRIPT_NAME="gerenciador-bateria"
readonly SCRIPT_VERSION="2.1.0"

# Valores padrão de limites (%)
DEFAULT_START_THRESHOLD=75
DEFAULT_END_THRESHOLD=80
DEFAULT_AUTO_DISCHARGE=true

# Detecção dinâmica de bateria (BAT0, BAT1, BATT, CMB0)
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

# Caminhos específicos da Dell (dell_wmi_sysman)
readonly WMI_SYSMAN_DIR="/sys/class/firmware-attributes/dell-smbios/attributes"
readonly WMI_MODE_FILE="${WMI_SYSMAN_DIR}/PrimaryBattChargeCfg/current_value"
readonly WMI_START_FILE="${WMI_SYSMAN_DIR}/CustomChargeStart/current_value"
readonly WMI_STOP_FILE="${WMI_SYSMAN_DIR}/CustomChargeStop/current_value"

# Caminhos de instalação e configuração universal
readonly CONF_FILE="/etc/gerenciador-bateria.conf"
readonly SERVICE_NAME="gerenciador-bateria.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly SCRIPT_INSTALL_PATH="/usr/local/bin/gerenciador-bateria"
readonly SCRIPT_ALIAS_PATH="/usr/local/bin/gerenciador_bateria"
readonly BACKUP_DIR="/etc/gerenciador-bateria/backups"

# Serviços legados anteriores para migração limpa
readonly LEGACY_SERVICES=(
    "thinkpad-battery-charge-limit.service"
    "asus-battery-charge-limit.service"
    "dell-battery-charge-limit.service"
)

# ========================== DETECÇÃO DE FABRICANTE ==========================

detect_vendor() {
    local vendor
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Desconhecido")
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
        generic) echo "Genérico / Outro" ;;
    esac
}

# ========================== CARREGAR / SALVAR CONFIGURAÇÃO ==================

load_config() {
    START_THRESHOLD="${DEFAULT_START_THRESHOLD}"
    END_THRESHOLD="${DEFAULT_END_THRESHOLD}"
    AUTO_DISCHARGE="${DEFAULT_AUTO_DISCHARGE}"
    DELL_MODE="custom"

    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONF_FILE}" 2>/dev/null || true
    fi
}

save_config() {
    local start_val="$1"
    local end_val="$2"
    local auto_discharge="${3:-${AUTO_DISCHARGE:-true}}"
    local dell_mode="${4:-${DELL_MODE:-custom}}"

    mkdir -p "$(dirname "${CONF_FILE}")"
    cat > "${CONF_FILE}" << EOF
# Configuração do Gerenciador de Bateria Universal
START_THRESHOLD=${start_val}
END_THRESHOLD=${end_val}
AUTO_DISCHARGE=${auto_discharge}
DELL_MODE="${dell_mode}"
EOF
    chmod 644 "${CONF_FILE}"
}

# ========================== FUNÇÕES AUXILIARES ===============================

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
        log_error "Este comando requer privilégios de root. Execute com 'sudo'."
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
        log_info "Comportamento de carga ajustado para: ${behaviour}"
    else
        log_warn "charge_behaviour não disponível ou force-discharge não suportado neste equipamento."
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

# ========================== VERIFICAÇÃO DE HARDWARE =========================

check_hardware() {
    local errors=0
    local vendor
    vendor=$(detect_vendor)

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Verificação de Hardware — ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "═══════════════════════════════════════════════════════════════"
    echo

    local dmi_vendor dmi_model
    dmi_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Desconhecido")
    dmi_model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Desconhecido")
    echo "💻 Sistema: ${dmi_vendor} (${dmi_model})"
    echo "🏷️  Fabricante Detectada: $(detect_vendor_display)"
    echo

    if [[ -d "${BAT_PATH}" ]]; then
        echo "✅ Bateria encontrada: ${BAT_PATH}"
        echo "   Fabricante: $(cat "${BAT_PATH}/manufacturer" 2>/dev/null || echo 'desconhecido')"
        echo "   Modelo:     $(cat "${BAT_PATH}/model_name" 2>/dev/null || echo 'desconhecido')"
        echo "   Tecnologia: $(cat "${BAT_PATH}/technology" 2>/dev/null || echo 'desconhecida')"
        echo "   Carga:      $(cat "${BAT_PATH}/capacity" 2>/dev/null || echo '?')%"
        echo "   Status:     $(cat "${BAT_PATH}/status" 2>/dev/null || echo 'desconhecido')"
        echo "   Ciclos:     $(cat "${BAT_PATH}/cycle_count" 2>/dev/null || echo '?')"
    else
        echo "❌ Bateria NÃO encontrada em ${BAT_PATH}"
        ((errors += 1))
    fi
    echo

    if [[ -e "${END_THRESHOLD_FILE}" ]]; then
        echo "✅ charge_control_end_threshold DISPONÍVEL (Valor: $(cat "${END_THRESHOLD_FILE}" 2>/dev/null || echo '?')%)"
    else
        if [[ "${vendor}" == "dell" && "$(detect_dell_backend)" != "none" ]]; then
            echo "ℹ️  charge_control_end_threshold via Dell SMBIOS/WMI disponível"
        else
            echo "❌ charge_control_end_threshold NÃO disponível"
            ((errors += 1))
        fi
    fi

    if [[ -e "${START_THRESHOLD_FILE}" ]]; then
        echo "✅ charge_control_start_threshold DISPONÍVEL (Valor: $(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo '?')%)"
    else
        if [[ "${vendor}" == "asus" ]]; then
            echo "ℹ️  charge_control_start_threshold gerenciado automaticamente pelo firmware ASUS (~75%)"
        else
            echo "ℹ️  charge_control_start_threshold não exposto diretamente"
        fi
    fi
    echo

    if is_force_discharge_supported; then
        echo "✅ Descarga Inteligente (force-discharge) SUPORTADA pelo hardware!"
        echo "   Modo atual: $(get_charge_behaviour)"
    else
        echo "ℹ️  force-discharge não suportado nativamente pelo hardware atual"
    fi
    echo

    echo "═══════════════════════════════════════════════════════════════"
    if [[ $errors -eq 0 ]]; then
        echo "  ✅ Hardware 100% compatível!"
    else
        echo "  ⚠️  Encontrados avisos ou erros. Verifique as mensagens acima."
    fi
    echo "═══════════════════════════════════════════════════════════════"
    echo

    return $errors
}

# ========================== APLICAR LIMITES ==================================

apply_thresholds() {
    local start_val="$1"
    local end_val="$2"
    local vendor
    vendor=$(detect_vendor)

    if ! [[ "${start_val}" =~ ^[0-9]+$ ]] || ! [[ "${end_val}" =~ ^[0-9]+$ ]]; then
        log_error "Valores inválidos: start='${start_val}', end='${end_val}'. Devem ser números inteiros."
        return 1
    fi

    case "${vendor}" in
        lenovo)
            if (( start_val < 0 || start_val > 99 || end_val < 1 || end_val > 100 )); then
                log_error "Limites inválidos para ThinkPad (start: 0-99, end: 1-100)."
                return 1
            fi
            if (( start_val > 0 && start_val >= end_val )); then
                log_error "start_threshold (${start_val}%) deve ser menor que end_threshold (${end_val}%)."
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
                log_error "Arquivos de threshold não encontrados em ${BAT_PATH}."
                return 1
            fi
            log_info "✅ Limites ThinkPad aplicados: Início=${start_val}% | Parada=${end_val}%"
            ;;

        asus)
            if (( end_val < 1 || end_val > 100 )); then
                log_error "Limite ASUS inválido (1-100)."
                return 1
            fi
            if [[ -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${end_val}" > "${END_THRESHOLD_FILE}"
                log_info "✅ Limite ASUS aplicado: Parada=${end_val}% (Retomada em ~${start_val}%)"
            else
                log_error "Arquivo ${END_THRESHOLD_FILE} não encontrado."
                return 1
            fi
            ;;

        dell)
            if (( start_val < 50 || start_val > 95 || end_val < 55 || end_val > 100 || start_val >= end_val )); then
                log_error "Limites inválidos para Dell (Start: 50-95, Stop: 55-100, Start < Stop)."
                return 1
            fi
            local dell_be
            dell_be=$(detect_dell_backend)
            case "${dell_be}" in
                libsmbios)
                    smbios-battery-ctl --set-custom-charge-interval "${start_val}" "${end_val}" >/dev/null 2>&1 || \
                    smbios-battery-ctl "--set-custom-charge-interval=${start_val}-${end_val}" >/dev/null 2>&1 || true
                    smbios-battery-ctl --set-charging-mode=custom >/dev/null 2>&1 || true
                    log_info "✅ Limites Dell aplicados via libsmbios (${start_val}% - ${end_val}%)."
                    ;;
                dell_wmi_sysman)
                    if [[ -f "${WMI_START_FILE}" && -f "${WMI_STOP_FILE}" && -f "${WMI_MODE_FILE}" ]]; then
                        echo "Custom" > "${WMI_MODE_FILE}" 2>/dev/null || true
                        echo "${start_val}" > "${WMI_START_FILE}" 2>/dev/null || true
                        echo "${end_val}" > "${WMI_STOP_FILE}" 2>/dev/null || true
                        log_info "✅ Limites Dell aplicados via dell_wmi_sysman."
                    fi
                    ;;
                sysfs)
                    [[ -e "${START_THRESHOLD_FILE}" ]] && echo "${start_val}" > "${START_THRESHOLD_FILE}" 2>/dev/null || true
                    [[ -e "${END_THRESHOLD_FILE}" ]] && echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || true
                    log_info "✅ Limites Dell aplicados via sysfs."
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
                log_error "Limites inválidos (start: 0-99, end: 1-100, start < end)."
                return 1
            fi
            if [[ -e "${START_THRESHOLD_FILE}" && -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${start_val}" > "${START_THRESHOLD_FILE}" 2>/dev/null || true
                echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || true
            elif [[ -e "${END_THRESHOLD_FILE}" ]]; then
                echo "${end_val}" > "${END_THRESHOLD_FILE}" 2>/dev/null || true
            fi
            log_info "✅ Limites genéricos aplicados: ${start_val}% - ${end_val}%"
            ;;
    esac

    return 0
}

restore_defaults() {
    log_info "Restaurando configurações para o padrão de fábrica (100%)..."
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

    log_info "✅ Limites restaurados para o padrão (100%)."
}

# ========================== DESCARGA INTELIGENTE (DAEMON) ====================

run_daemon() {
    check_root
    log_info "Iniciando ${SCRIPT_NAME} em modo daemon de monitoramento contínuo..."

    local discharge_in_progress=0

    cleanup_daemon() {
        log_info "Daemon encerrado. Garantindo modo de carga 'auto'..."
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
                    log_info "Threshold alterado no sysfs (${cur_sys_end} -> ${END_THRESHOLD}). Reaplicando..."
                    apply_thresholds "${START_THRESHOLD}" "${END_THRESHOLD}" || true
                fi
            fi

            if [[ "${AUTO_DISCHARGE:-true}" == "true" ]] && is_force_discharge_supported; then
                local current_behaviour
                current_behaviour=$(get_charge_behaviour)

                if is_ac_online; then
                    if (( cur_cap > END_THRESHOLD )); then
                        if [[ "${current_behaviour}" != "force-discharge" ]]; then
                            log_info "Bateria acima do limite (${cur_cap}% > ${END_THRESHOLD}%)."
                            log_info "Ativando 'force-discharge': drenando na tomada até ${START_THRESHOLD}%..."
                            set_charge_behaviour "force-discharge"
                            discharge_in_progress=1
                        fi
                    elif (( cur_cap <= START_THRESHOLD )); then
                        if [[ "${current_behaviour}" == "force-discharge" || ${discharge_in_progress} -eq 1 ]]; then
                            log_info "Limite de início alcançado (${cur_cap}% <= ${START_THRESHOLD}%)."
                            log_info "Restaurando modo 'auto': recarregará até ${END_THRESHOLD}% e manterá bypass AC."
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
                    log_warn "SEGURANÇA: Bateria em nível baixo (${cur_cap}%). Cancelando força de descarga."
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
    log_info "Serviço finalizado. Modo de carga mantido em 'auto'."
}

# ========================== ATIVAR / DESATIVAR AUTO-DISCHARGE ================

set_auto_discharge_cmd() {
    check_root
    load_config
    local choice="${1:-toggle}"

    case "${choice,,}" in
        on|enable|true|1|ativar|ativado)
            save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "true"
            log_info "✅ Descarga Inteligente (Auto-Discharge) ATIVADA."
            log_info "Se o notebook ligar em 100%, ele descarregará na tomada até ${START_THRESHOLD}%."
            ;;
        off|disable|false|0|desativar|desativado)
            save_config "${START_THRESHOLD}" "${END_THRESHOLD}" "false"
            if is_force_discharge_supported; then
                echo "auto" > "${BEHAVIOUR_FILE}" 2>/dev/null || true
            fi
            log_info "✅ Descarga Inteligente (Auto-Discharge) DESATIVADA."
            log_info "O notebook manterá os limites sem forçar descarga na tomada."
            ;;
        toggle)
            if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
                set_auto_discharge_cmd "off"
            else
                set_auto_discharge_cmd "on"
            fi
            ;;
        status)
            log_info "Status do Auto-Discharge: ${AUTO_DISCHARGE}"
            ;;
        *)
            log_error "Opção inválida: '${choice}'. Use 'on' ou 'off'."
            return 1
            ;;
    esac
}

# ========================== DESCARGA MANUAL ==================================

force_discharge_cmd() {
    check_root
    load_config

    if ! is_force_discharge_supported; then
        log_error "O hardware atual não suporta 'force-discharge' via sysfs."
        return 1
    fi

    local cur_cap
    cur_cap=$(cat "${BAT_PATH}/capacity" 2>/dev/null || echo "0")

    if (( cur_cap <= START_THRESHOLD )); then
        log_info "A bateria já está em ${cur_cap}% (<= limite ${START_THRESHOLD}%). Descarga desnecessária."
        return 0
    fi

    log_info "Forçando descarga imediata na tomada (de ${cur_cap}% até ${START_THRESHOLD}%)..."
    set_charge_behaviour "force-discharge"
}

stop_discharge_cmd() {
    check_root
    if ! is_force_discharge_supported; then
        log_error "O hardware atual não possui suporte a 'charge_behaviour'."
        return 1
    fi
    log_info "Cancelando descarga forçada. Retornando ao modo 'auto'..."
    set_charge_behaviour "auto"
}

# ========================== INSTALAÇÃO / MIGRAÇÃO ===========================

install_service() {
    check_root

    echo "Instalando ${SCRIPT_NAME} Universal..."
    echo

    if ! check_hardware; then
        echo "Avisos detectados no hardware, prosseguindo com a instalação..."
    fi
    echo

    for s in "${LEGACY_SERVICES[@]}"; do
        if systemctl is-active --quiet "${s}" 2>/dev/null; then
            log_info "Parando serviço legado: ${s}"
            systemctl stop "${s}" 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet "${s}" 2>/dev/null; then
            log_info "Desabilitando serviço legado: ${s}"
            systemctl disable "${s}" 2>/dev/null || true
        fi
        rm -f "/etc/systemd/system/${s}" 2>/dev/null || true
    done

    mkdir -p "${BACKUP_DIR}"
    if [[ ! -f "${CONF_FILE}" ]]; then
        save_config "${DEFAULT_START_THRESHOLD}" "${DEFAULT_END_THRESHOLD}" "${DEFAULT_AUTO_DISCHARGE}"
        log_info "Configuração padrão salva em: ${CONF_FILE}"
    else
        log_info "Configuração existente preservada em: ${CONF_FILE}"
    fi

    cp "$0" "${SCRIPT_INSTALL_PATH}"
    chmod 755 "${SCRIPT_INSTALL_PATH}"
    ln -sf "${SCRIPT_INSTALL_PATH}" "${SCRIPT_ALIAS_PATH}"
    log_info "Binário instalado em: ${SCRIPT_INSTALL_PATH} (e alias ${SCRIPT_ALIAS_PATH})"

    cat > "${SERVICE_FILE}" << 'UNIT_EOF'
[Unit]
Description=Universal Battery Charge Limit & Auto-Discharge Manager
Documentation=https://github.com
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=simple
Restart=always
RestartSec=10s
ExecStart=/usr/local/bin/gerenciador-bateria daemon
ExecStop=/usr/local/bin/gerenciador-bateria stop

ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=no
ReadWritePaths=-/sys/class/power_supply -/sys/devices -/sys/class/firmware-attributes -/etc

StandardOutput=journal
StandardError=journal
SyslogIdentifier=gerenciador-bateria

[Install]
WantedBy=multi-user.target
UNIT_EOF

    log_info "Serviço systemd criado: ${SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    log_info "Serviço universal habilitado e iniciado com sucesso."

    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  ✅ Instalação concluída com sucesso!"
    echo "  Hardware detectado: $(detect_vendor_display)"
    echo
    echo "  Comandos rápidos (com hífen ou underline):"
    echo "    sudo gerenciador-bateria         — Abre o Menu Interativo"
    echo "    sudo gerenciador_bateria         — Abre o Menu Interativo"
    echo "    sudo gerenciador-bateria on      — Ativa descarga inteligente"
    echo "    sudo gerenciador-bateria off     — Desativa descarga inteligente"
    echo "    sudo gerenciador-bateria status  — Exibe status detalhado"
    echo "    sudo gerenciador-bateria set 75 80 — Ajusta limites"
    echo "═══════════════════════════════════════════════════════════════"
}

# ========================== DESABILITAR / HABILITAR / REMOVER =================

disable_service() {
    check_root
    log_info "Desabilitando serviço..."

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}"
        log_info "Serviço parado."
    fi

    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl disable "${SERVICE_NAME}"
        log_info "Serviço desabilitado."
    fi

    restore_defaults
    echo
    log_info "✅ Serviço desabilitado e limites restaurados para 100%."
    log_info "Para reabilitar: sudo gerenciador-bateria enable"
}

enable_service() {
    check_root
    if [[ ! -f "${SERVICE_FILE}" ]]; then
        log_error "Serviço não instalado. Execute 'install' primeiro."
        exit 1
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    log_info "✅ Serviço habilitado e iniciado."
}

remove_service() {
    check_root
    echo "Removendo ${SCRIPT_NAME}..."
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

    systemctl daemon-reload
    log_info "systemd recarregado."

    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  ✅ Remoção concluída com sucesso."
    echo "  Os limites foram restaurados para o padrão de fábrica (100%)."
    echo "═══════════════════════════════════════════════════════════════"
}

# ========================== STATUS ===========================================

show_status() {
    load_config
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Status — ${SCRIPT_NAME} v${SCRIPT_VERSION} ($(detect_vendor_display))"
    echo "═══════════════════════════════════════════════════════════════"
    echo

    local vendor model
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Desconhecido")
    model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Desconhecido")
    echo "Dispositivo:        ${vendor} (${model})"

    if [[ -d "${BAT_PATH}" ]]; then
        echo "Bateria:"
        echo "  Carga atual:      $(cat "${BAT_PATH}/capacity" 2>/dev/null || echo '?')%"
        echo "  Status:           $(cat "${BAT_PATH}/status" 2>/dev/null || echo '?')"
        echo "  Energia atual:    $(read_battery_energy now)"
        echo "  Energia total:    $(read_battery_energy full)"
        echo "  Ciclos:           $(cat "${BAT_PATH}/cycle_count" 2>/dev/null || echo '?')"
    else
        echo "  ❌ Bateria não encontrada"
    fi
    echo

    echo "Alimentação Externa:"
    if is_ac_online; then
        echo "  Tomada (AC):      🔌 Conectada"
    else
        echo "  Tomada (AC):      🔋 Desconectada (operando na bateria)"
    fi
    echo

    echo "Limites de Carga do Hardware:"
    local cur_start cur_end
    cur_start=$(cat "${START_THRESHOLD_FILE}" 2>/dev/null || echo "N/A")
    cur_end=$(cat "${END_THRESHOLD_FILE}" 2>/dev/null || echo "N/A")
    echo "  Início da recarga (start): ${cur_start}%"
    echo "  Fim da recarga (stop/end): ${cur_end}%"
    echo

    echo "Descarga Inteligente (Auto-Discharge):"
    local beh
    beh=$(get_charge_behaviour)
    if is_force_discharge_supported; then
        echo "  Suporte de Hardware:      ✅ Suportado (force-discharge)"
        echo "  Comportamento Atual:      ${beh}"
        if [[ "${beh}" == "force-discharge" ]]; then
            echo "  Estado da Descarga:       ⚡ ATIVA (Drenando até ${START_THRESHOLD}%)"
        else
            echo "  Estado da Descarga:       Em repouso / Automático"
        fi
        echo "  Funcionalidade:           $( [[ "${AUTO_DISCHARGE:-true}" == "true" ]] && echo "✅ ATIVADA" || echo "❌ DESATIVADA" )"
    else
        echo "  Suporte de Hardware:      ℹ️  Não suportado neste equipamento"
    fi
    echo

    echo "Serviço systemd (${SERVICE_NAME}):"
    if [[ -f "${SERVICE_FILE}" ]]; then
        echo "  Instalado:        ✅ Sim"
        if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
            echo "  Habilitado:       ✅ Sim (no boot)"
        else
            echo "  Habilitado:       ❌ Não"
        fi
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            echo "  Ativo:            ✅ Sim"
        else
            echo "  Ativo:            ❌ Não"
        fi
    else
        echo "  Instalado:        ❌ Não"
    fi
    echo
}

# ============================================================================
# ENGINE TUI NATIVA DE BAIXA LATÊNCIA (ESC INSTANTÂNEO DIRETO DO /dev/tty)
# ============================================================================

# Variável global preenchida por read_tty_key (SEM subshell para não perder timeout do tty)
LAST_KEY=""

read_tty_key() {
    LAST_KEY=""
    local k1="" k2="" k3=""

    # Lê 1 caractere diretamente do /dev/tty
    if ! IFS= read -rsn1 k1 < /dev/tty 2>/dev/null; then
        LAST_KEY="ESC"
        return 0
    fi

    # Se for Enter (vazio em read -n1)
    if [[ -z "${k1}" ]]; then
        LAST_KEY="ENTER"
        return 0
    fi

    # Se começar com byte ESC (0x1B)
    if [[ "${k1}" == $'\x1b' ]]; then
        # Lê próximo byte com timeout curtíssimo (20ms) direto do /dev/tty
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
        # Alt+Tecla ou ESC duplo: trata como ESC imediato
        LAST_KEY="ESC"
        return 0
    fi

    LAST_KEY="${k1}"
}

# Restaura cursor ao sair
cleanup_tui() {
    printf '\033[?25h\033[0m' > /dev/tty 2>/dev/null || true
}

# Exibe popup de mensagem estilizado (Fecha com Enter, Espaço, q ou ESC)
tui_msgbox() {
    local title="$1"
    local msg="$2"
    printf '\033[2J\033[H' > /dev/tty
    echo "┌──────────────────────────────────────────────────────────────────┐" > /dev/tty
    printf "│  \033[1;36m%-62s\033[0m  │\n" "${title}" > /dev/tty
    echo "├──────────────────────────────────────────────────────────────────┤" > /dev/tty
    echo "│                                                                  │" > /dev/tty
    while IFS= read -r line; do
        printf "│  %-62s  │\n" "${line}" > /dev/tty
    done <<< "${msg}"
    echo "│                                                                  │" > /dev/tty
    echo "├──────────────────────────────────────────────────────────────────┤" > /dev/tty
    echo "│            Pressione [ENTER] ou [ESC] para continuar             │" > /dev/tty
    echo "└──────────────────────────────────────────────────────────────────┘" > /dev/tty

    while true; do
        read_tty_key
        case "${LAST_KEY}" in
            ENTER|ESC|" "|q|Q) break ;;
        esac
    done
}

# Input box com suporte a cancelamento imediato no ESC
INPUT_RESULT=""
tui_inputbox() {
    local title="$1"
    local prompt_msg="$2"
    local default_val="$3"
    local buf="${default_val}"

    while true; do
        printf '\033[2J\033[H\033[?25h' > /dev/tty
        echo "┌──────────────────────────────────────────────────────────────────┐" > /dev/tty
        printf "│  \033[1;36m%-62s\033[0m  │\n" "${title}" > /dev/tty
        echo "├──────────────────────────────────────────────────────────────────┤" > /dev/tty
        printf "│  %-62s  │\n" "${prompt_msg}" > /dev/tty
        echo "│                                                                  │" > /dev/tty
        printf "│  Valor: \033[1;33m%-55s\033[0m  │\n" "${buf}_" > /dev/tty
        echo "│                                                                  │" > /dev/tty
        echo "├──────────────────────────────────────────────────────────────────┤" > /dev/tty
        echo "│        [ENTER] Confirmar          [ESC] Cancelar / Voltar        │" > /dev/tty
        echo "└──────────────────────────────────────────────────────────────────┘" > /dev/tty

        read_tty_key
        case "${LAST_KEY}" in
            ESC)
                printf '\033[?25l' > /dev/tty
                return 1
                ;;
            ENTER)
                printf '\033[?25l' > /dev/tty
                INPUT_RESULT="${buf}"
                return 0
                ;;
            $'\x7f'|$'\x08') # Backspace
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

# Confirmação Sim/Não com suporte a Setas e ESC
tui_yesno() {
    local title="$1"
    local question="$2"
    local sel=0 # 0 = Sim, 1 = Não

    while true; do
        printf '\033[2J\033[H\033[?25l' > /dev/tty
        echo "┌──────────────────────────────────────────────────────────────────┐" > /dev/tty
        printf "│  \033[1;33m%-62s\033[0m  │\n" "${title}" > /dev/tty
        echo "├──────────────────────────────────────────────────────────────────┤" > /dev/tty
        echo "│                                                                  │" > /dev/tty
        printf "│  %-62s  │\n" "${question}" > /dev/tty
        echo "│                                                                  │" > /dev/tty
        if (( sel == 0 )); then
            printf "│                 \033[7;1m < Sim > \033[0m              < Não (ESC) >             │\n" > /dev/tty
        else
            printf "│                  < Sim >              \033[7;1m < Não (ESC) > \033[0m            │\n" > /dev/tty
        fi
        echo "│                                                                  │" > /dev/tty
        echo "└──────────────────────────────────────────────────────────────────┘" > /dev/tty

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

show_interactive_menu() {
    if [[ ! -t 0 ]]; then
        show_status
        exit 0
    fi

    trap cleanup_tui EXIT INT TERM
    printf '\033[?25l' > /dev/tty

    local selected=0
    local total_items=6
    local ac_label auto_state toggle_label cur_cap vendor_name
    vendor_name=$(detect_vendor_display)

    while true; do
        load_config
        cur_cap=$(cat "${BAT_PATH}/capacity" 2>/dev/null || echo "?")

        if is_ac_online; then
            ac_label="Tomada Conectada 🔌"
        else
            ac_label="Na Bateria 🔋"
        fi

        if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
            auto_state="ATIVADO ✅"
            toggle_label="Desativar Descarga Inteligente"
        else
            auto_state="DESATIVADO ❌"
            toggle_label="Ativar Descarga Inteligente"
        fi

        local items=(
            "1 📊 Ver Status Detalhado da Bateria"
            "2 ⚡ ${toggle_label}"
            "3 🎯 Alterar Limites de Carga (${START_THRESHOLD}% - ${END_THRESHOLD}%)"
            "4 ⚡ Forçar Descarga Imediata na Tomada"
            "5 🔌 Restaurar Padrão de Fábrica (100%)"
            "0 🚪 Sair do Programa"
        )

        # Renderiza o Menu TUI
        printf '\033[2J\033[H\033[?25l' > /dev/tty
        echo "┌──────────────── Gerenciador de Bateria Universal ────────────────┐" > /dev/tty
        printf "│ Bateria: \033[1m%s%%\033[0m (%s) | \033[1;36m%s\033[0m\n" "${cur_cap}" "${ac_label}" "${vendor_name}" > /dev/tty
        printf "│ Auto-Discharge: [%s] | Limites: \033[1m%s%% - %s%%\033[0m\n" "${auto_state}" "${START_THRESHOLD}" "${END_THRESHOLD}" > /dev/tty
        echo "├──────────────────────────────────────────────────────────────────┤" > /dev/tty
        echo "│ Escolha uma opção (Setas ↑/↓, Números 0-5 ou ESC para sair):     │" > /dev/tty
        echo "│                                                                  │" > /dev/tty

        for i in "${!items[@]}"; do
            if (( i == selected )); then
                printf "│   \033[7;1m %-58s \033[0m   │\n" "${items[$i]}" > /dev/tty
            else
                printf "│    %-58s    │\n" "${items[$i]}" > /dev/tty
            fi
        done

        echo "│                                                                  │" > /dev/tty
        echo "├──────────────────────────────────────────────────────────────────┤" > /dev/tty
        echo "│          [ENTER] Selecionar               [ESC / q] Sair         │" > /dev/tty
        echo "└──────────────────────────────────────────────────────────────────┘" > /dev/tty

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
            ENTER)
                case "${selected}" in
                    0) action="1" ;;
                    1) action="2" ;;
                    2) action="3" ;;
                    3) action="4" ;;
                    4) action="5" ;;
                    5)
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

        # Executa a ação selecionada
        case "${action}" in
            1)
                printf '\033[2J\033[H' > /dev/tty
                show_status > /dev/tty
                echo "───────────────────────────────────────────────────────────────" > /dev/tty
                echo "Pressione [ENTER] para voltar ao menu ou [ESC / q] para sair..." > /dev/tty
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
                ;;

            2)
                check_root
                if [[ "${AUTO_DISCHARGE:-true}" == "true" ]]; then
                    set_auto_discharge_cmd "off" >/dev/null
                    tui_msgbox "Auto-Discharge Desativado" "A Descarga Inteligente na tomada foi DESATIVADA."
                else
                    set_auto_discharge_cmd "on" >/dev/null
                    tui_msgbox "Auto-Discharge Ativado" "$(printf "A Descarga Inteligente foi ATIVADA!\nSe ligar em 100%%, drenará na tomada até %s%%." "${START_THRESHOLD}")"
                fi
                ;;

            3)
                check_root
                local new_start="" new_end=""
                if ! tui_inputbox "Limite de Início" "Digite a % para INICIAR a recarga (ex: 75):" "${START_THRESHOLD}"; then
                    continue
                fi
                new_start="${INPUT_RESULT}"

                if ! tui_inputbox "Limite de Parada" "Digite a % para PARAR a recarga (ex: 80):" "${END_THRESHOLD}"; then
                    continue
                fi
                new_end="${INPUT_RESULT}"

                if apply_thresholds "${new_start}" "${new_end}" >/dev/null 2>&1; then
                    save_config "${new_start}" "${new_end}" "${AUTO_DISCHARGE}"
                    tui_msgbox "Sucesso" "Limites atualizados: Início = ${new_start}% | Parada = ${new_end}%"
                else
                    tui_msgbox "Erro de Validação" "Valores inválidos (${new_start}% - ${new_end}%). Verifique se Início < Parada."
                fi
                ;;

            4)
                check_root
                if force_discharge_cmd >/dev/null 2>&1; then
                    tui_msgbox "Descarga Imediata" "Modo force-discharge ativado na tomada até atingir ${START_THRESHOLD}%."
                else
                    tui_msgbox "Aviso" "Não foi possível ativar a descarga forçada neste hardware."
                fi
                ;;

            5)
                check_root
                if tui_yesno "Confirmar Restauração" "Deseja restaurar os limites para o padrão de fábrica (100%)?"; then
                    restore_defaults >/dev/null 2>&1
                    tui_msgbox "Restaurado" "Limites restaurados para 100% com sucesso."
                fi
                ;;
        esac
    done
}

# ========================== TESTES ============================================

run_test() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Teste de Integridade — ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "═══════════════════════════════════════════════════════════════"
    echo

    local passed=0
    local failed=0

    echo -n "  [1/5] Bateria detectada........................... "
    if [[ -d "${BAT_PATH}" ]]; then
        echo "✅ PASS"
        ((passed += 1))
    else
        echo "❌ FAIL"
        ((failed += 1))
    fi

    echo -n "  [2/5] Fabricante reconhecida...................... "
    local v
    v=$(detect_vendor)
    if [[ "${v}" != "generic" ]]; then
        echo "✅ PASS ($(detect_vendor_display))"
        ((passed += 1))
    else
        echo "ℹ️  INFO ($(detect_vendor_display))"
    fi

    echo -n "  [3/5] Interface de limite disponível.............. "
    if [[ -e "${END_THRESHOLD_FILE}" || -f "${WMI_MODE_FILE}" ]] || command -v smbios-battery-ctl >/dev/null 2>&1; then
        echo "✅ PASS"
        ((passed += 1))
    else
        echo "❌ FAIL"
        ((failed += 1))
    fi

    echo -n "  [4/5] Suporte a force-discharge................... "
    if is_force_discharge_supported; then
        echo "✅ PASS"
        ((passed += 1))
    else
        echo "ℹ️  INFO (não suportado)"
    fi

    echo -n "  [5/5] Serviço systemd ativo....................... "
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo "✅ PASS"
        ((passed += 1))
    else
        echo "❌ FAIL / INATIVO"
        ((failed += 1))
    fi

    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Resultado: ${passed} passou, ${failed} falhou"
    echo "═══════════════════════════════════════════════════════════════"

    return ${failed}
}

# ========================== AJUSTAR LIMITES (SET) ============================

set_thresholds_cmd() {
    check_root
    local start_val="$1"
    local end_val="$2"

    if apply_thresholds "${start_val}" "${end_val}"; then
        save_config "${start_val}" "${end_val}" "${AUTO_DISCHARGE}"
    else
        return 1
    fi
}

# ========================== USO ==============================================

show_usage() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Gerenciador Inteligente de Bateria Universal para Linux (Lenovo, ASUS, Dell)

USO RÁPIDO:
    sudo $(basename "$0")                  Abre o menu interativo amigável
    sudo $(basename "$0") on               Ativa a Descarga Inteligente
    sudo $(basename "$0") off              Desativa a Descarga Inteligente
    sudo $(basename "$0") status           Exibe status detalhado
    sudo $(basename "$0") set <ini> <fim>  Ajusta limites (ex: set 75 80)

OUTROS COMANDOS:
    menu                   Abre o menu interativo
    auto-discharge <on|off>Ativa ou desativa a descarga inteligente
    discharge              Força descarga imediata na tomada até o início
    stop-discharge         Cancela a descarga forçada e volta ao modo auto
    restore                Restaura padrão de fábrica (100%)
    check                  Verifica compatibilidade do hardware
    test                   Executa bateria de testes do sistema
    install                Instala o gerenciador universal e ativa o serviço
    enable                 Reabilita o serviço no systemd
    disable                Desabilita o serviço temporariamente
    remove                 Desinstala completamente o script e serviço
    help                   Exibe esta ajuda
EOF
}

# ========================== MAIN =============================================

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
                log_error "Uso: sudo $(basename "$0") set <inicio> <fim>"
                log_error "Exemplo: sudo $(basename "$0") set 75 80"
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
            log_error "Comando desconhecido: ${command}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"