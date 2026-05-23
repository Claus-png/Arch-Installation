#!/usr/bin/env bash

run_pacman() {
    local -a args=("$@")
    if [[ "$EUID" -eq 0 ]]; then
        pacman -S --needed --noconfirm "${args[@]}"
        return
    fi
    if sudo -n true >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm "${args[@]}"
        return
    fi
    _msg "Недостаточно прав для установки пакетов. Запустите OOBE от пользователя с sudo."
    return 1
}

install_oobe_packages() {
    local selected="$1"
    local -a repo_pkgs=()
    local -a aur_pkgs=()

    for pack in $selected; do
        case "$pack" in
            gaming)
                repo_pkgs+=(steam lutris mangohud wine-staging winetricks)
                ;;
            dev)
                repo_pkgs+=(docker nodejs python python-pip)
                aur_pkgs+=(visual-studio-code-bin)
                ;;
            ai)
                aur_pkgs+=(ollama)
                ;;
        esac
    done

    if [[ ${#repo_pkgs[@]} -gt 0 ]]; then
        run_pacman "${repo_pkgs[@]}" || true
    fi

    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        if command -v paru >/dev/null 2>&1; then
            if [[ "$EUID" -eq 0 ]]; then
                paru -S --needed --noconfirm "${aur_pkgs[@]}" || true
            elif sudo -n true >/dev/null 2>&1; then
                sudo paru -S --needed --noconfirm "${aur_pkgs[@]}" || true
            else
                _msg "Не удалось установить AUR-пакеты: paru недоступен или нет sudo."
            fi
        else
            _msg "AUR-пакеты пропущены: paru не установлен."
        fi
    fi
}

run_oobe() {
    whiptail --title "First boot setup" --msgbox \
"Добро пожаловать в первый запуск после установки.\n\nЭта подсказка поможет быстро завершить базовую настройку, подключить Wi-Fi и проверить дополнительные пакеты." 12 74

    if ! whiptail --yesno "Хотите задать дополнительные пароли прямо сейчас?" 8 60 3>&1 1>&2 2>&3; then
        return 0
    fi

    local pass1 pass2
    while true; do
        pass1=$(_password_input "Set password" "Введите дополнительный пароль:") || return 1
        pass2=$(_password_input "Confirm password" "Повторите пароль:") || return 1
        if [[ "$pass1" == "$pass2" ]]; then
            echo "$(whoami):$pass1" | chpasswd >/dev/null 2>&1 || true
            break
        fi
        _msg "Пароли не совпадают, попробуйте снова."
    done

    whiptail --title "Wi-Fi" --msgbox \
"Для подключения к Wi-Fi используйте iwctl.\n\nЕсли нужна помощь, запустите: iwctl и затем station wlan0 connect <SSID>." 10 74

    if whiptail --yesno "Хотите установить дополнительные пакеты сейчас?" 8 60 3>&1 1>&2 2>&3; then
        local oobe_packs
        oobe_packs=$(whiptail --title "Дополнительно" --checklist "Выберите наборы:" 16 72 6 \
            "gaming" "Steam, Lutris, MangoHUD, Wine" OFF \
            "dev" "Docker, Node, Python, VS Code" OFF \
            "ai" "Ollama, LM Studio" OFF 3>&1 1>&2 2>&3) || true
        if [[ -n "$oobe_packs" ]]; then
            install_oobe_packages "$oobe_packs"
        fi
    fi

    if find / -maxdepth 3 \( -name '*.tar.gz' -o -name '*.zip' \) 2>/dev/null | grep -q 'backup\|kde\|kitty'; then
        if whiptail --yesno "Найден архив для восстановления. Восстановить сейчас?" 8 60 3>&1 1>&2 2>&3; then
            _msg "Восстановление из архива нужно запускать через backup_tui.sh."
        fi
    fi
}
