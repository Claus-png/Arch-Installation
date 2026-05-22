#!/usr/bin/env bash

stage_06_summary() {
    local luks_flag="no"
    [[ "${USE_LUKS:-no}" == "yes" ]] && luks_flag="yes"

    whiptail --title "Summary" --yesno \
"Disk: ${DISK:-unknown}\nUser: ${USERNAME:-unknown}\nHostname: ${HOSTNAME:-unknown}\nLUKS: ${luks_flag}\nPackages: ${SELECTED_PACKAGES:-none}\n\nProceed with installation?" 16 72
}
