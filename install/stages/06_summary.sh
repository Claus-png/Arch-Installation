#!/usr/bin/env bash

stage_06_summary() {
    local luks_flag="no"
    [[ "${USE_LUKS:-no}" == "yes" ]] && luks_flag="yes"

    whiptail --title "Финальный обзор" --yesno \
"Диск: ${DISK:-unknown}\nПользователь: ${USERNAME:-unknown}\nХост: ${HOSTNAME:-unknown}\nLUKS: ${luks_flag}\nПакеты: ${SELECTED_PACKAGES:-базовый набор}\n\nБэкап: восстанавливается отдельно через backup_tui.sh\n\nНачать установку?" 18 74
}
