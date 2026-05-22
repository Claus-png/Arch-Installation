#!/usr/bin/env bash

run_oobe() {
    whiptail --title "First boot setup" --msgbox "Welcome! This wizard helps with first-boot setup, Wi-Fi, and optional extra packages." 10 72

    if ! whiptail --yesno "Would you like to set an additional user password now?" 8 60 3>&1 1>&2 2>&3; then
        return 0
    fi

    local pass1 pass2
    while true; do
        pass1=$(_password_input "Set password" "Enter additional password:") || return 1
        pass2=$(_password_input "Confirm password" "Confirm additional password:") || return 1
        if [[ "$pass1" == "$pass2" ]]; then
            echo "$(whoami):$pass1" | chpasswd >/dev/null 2>&1 || true
            break
        fi
        _msg "Passwords did not match, try again."
    done

    whiptail --title "Wi-Fi" --msgbox "Run iwctl to connect to your Wi-Fi network.\n\nIf you need a guided setup, use the iwctl command now." 10 72

    if whiptail --yesno "Would you like to install optional extra packs?" 8 60 3>&1 1>&2 2>&3; then
        whiptail --title "Extra packages" --checklist "Choose additional packs:" 16 72 6 \
            "Gaming Pack" "Steam, Lutris, MangoHUD, Wine" OFF \
            "Dev Pack" "Docker, Node, Python, VS Code" OFF \
            "AI Pack" "Ollama, LM Studio" OFF 3>&1 1>&2 2>&3 >/dev/null || true
    fi

    if find / -maxdepth 3 \( -name '*.tar.gz' -o -name '*.zip' \) 2>/dev/null | grep -q 'backup\|kde\|kitty'; then
        if whiptail --yesno "A backup archive was found. Restore it now?" 8 60 3>&1 1>&2 2>&3; then
            _msg "Restore step is not implemented in this minimal OOBE yet."
        fi
    fi
}
