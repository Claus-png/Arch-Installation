#!/usr/bin/env bash

set -u -o pipefail

if ! declare -F _msg >/dev/null 2>&1; then
    _msg() {
        printf '%s\n' "$*"
    }
fi

parse_checklist_items() {
    local raw="$1"
    local -n out_ref="$2"

    out_ref=()
    [[ -z "$raw" ]] && return 0

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        item=${item//\"/}
        out_ref+=("$item")
    done < <(printf '%s\n' "$raw" | tr ' ' '\n')
}

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
    local raw="$1"
    local -a selected=()
    local -a repo_pkgs=()
    local -a aur_pkgs=()

    parse_checklist_items "$raw" selected

    for pack in "${selected[@]}"; do
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
        _run_optional "install OOBE repo packages" run_pacman "${repo_pkgs[@]}"
    fi

    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        if [[ "$EUID" -eq 0 ]]; then
            _msg "AUR-пакеты нельзя устанавливать от root. Запустите OOBE от обычного пользователя."
            return 1
        fi
        if ! command -v paru >/dev/null 2>&1; then
            _msg "AUR-пакеты пропущены: paru не установлен."
            return 1
        fi
        if ! sudo -n true >/dev/null 2>&1; then
            _msg "Не удалось установить AUR-пакеты: нет sudo."
            return 1
        fi
        sudo paru -S --needed --noconfirm "${aur_pkgs[@]}" || return 1
    fi
}

run_oobe() {
    whiptail --title "First boot setup" --msgbox \
"Добро пожаловать в первый запуск после установки.\n\nЭта подсказка поможет быстро завершить базовую настройку, подключить Wi-Fi и проверить дополнительные пакеты." 12 74

    if ! whiptail --yesno "Хотите задать дополнительные пароли прямо сейчас?" 8 60 3>&1 1>&2 2>&3; then
        return 0
    fi

    local pass1 pass2
    local current_user
    current_user=$(id -un)
    while true; do
        pass1=$(_password_input "Set password" "Введите дополнительный пароль:") || return 1
        pass2=$(_password_input "Confirm password" "Повторите пароль:") || return 1
        if [[ "$pass1" == "$pass2" ]]; then
            if [[ "$EUID" -eq 0 ]]; then
                if ! printf '%s:%s\n' "$current_user" "$pass1" | chpasswd >/dev/null 2>&1; then
                    _msg "Не удалось обновить пароль пользователя $current_user."
                    return 1
                fi
            else
                if ! printf '%s:%s\n' "$current_user" "$pass1" | sudo chpasswd >/dev/null 2>&1; then
                    _msg "Не удалось обновить пароль пользователя $current_user."
                    return 1
                fi
            fi
            break
        fi
        _msg "Пароли не совпадают, попробуйте снова."
    done

    whiptail --title "Wi-Fi" --msgbox \
"Для подключения к Wi-Fi используйте iwctl.\n\nЕсли нужна помощь, запустите: iwctl и затем station wlan0 connect <SSID>." 10 74

    if whiptail --yesno "Хотите установить дополнительные пакеты сейчас?" 8 60 3>&1 1>&2 2>&3; then
        local oobe_packs
        if ! oobe_packs=$(whiptail --title "Дополнительно" --checklist "Выберите наборы:" 16 72 6 \
            "gaming" "Steam, Lutris, MangoHUD, Wine" OFF \
            "dev" "Docker, Node, Python, VS Code" OFF \
            "ai" "Ollama, LM Studio" OFF 3>&1 1>&2 2>&3); then
            _log "WARN: отменён выбор OOBE пакетов"
            oobe_packs=""
        fi
        install_oobe_packages "$oobe_packs"
    fi

    if [[ -f "$HOME/.config/kdeglobals" || -d "$HOME/.config/kitty" ]]; then
        if whiptail --yesno "Найдено пользовательское окружение. Запустить backup_tui.sh для восстановления?" 8 60 3>&1 1>&2 2>&3; then
            _msg "Запуск восстановления нужно делать через backup_tui.sh."
        fi
    fi
}
