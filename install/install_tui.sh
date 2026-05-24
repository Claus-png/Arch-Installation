#!/usr/bin/env bash
# TOOL_NAME: install_tui
# TOOL_DESC: TUI-установщик Arch Linux — Teddy (i5-12400F · RTX 3050 · btrfs)
# TOOL_MODE: gui

set -eEuo pipefail

DRY_RUN=0
RESET_STATE="${RESET_STATE:-0}"
MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --reset-state)
            RESET_STATE=1
            shift
            ;;
        --post|--chroot|--chroot-fresh|--oobe|wizard)
            MODE="$1"
            shift
            break
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&2
            exit 1
            ;;
    esac
done

case "${MODE:-wizard}" in
    --post)         MODE="post" ;;
    --chroot)       MODE="chroot" ;;
    --chroot-fresh) MODE="chroot_fresh" ;;
    --oobe)         MODE="oobe" ;;
    wizard)         MODE="wizard" ;;
    "")            MODE="wizard" ;;
    *)              echo "Неизвестный режим: $MODE" >&2
                    exit 1
                    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /root/install/lib ]]; then
    SCRIPT_DIR="/root/install"
fi
if [[ ! -f "$SCRIPT_DIR/lib/ui.sh" && -d "$HOME/install/lib" ]]; then
    SCRIPT_DIR="$HOME/install"
fi
STAGE_DIR="$SCRIPT_DIR/stages"
POST_DIR="$SCRIPT_DIR/post"
LOG_FILE="${LOG_FILE:-/var/log/install.log}"
PROFILE_FILE="${PROFILE_FILE:-$SCRIPT_DIR/../config/profile.conf}"
DEFAULTS_FILE="${DEFAULTS_FILE:-$SCRIPT_DIR/../config/defaults.conf}"
if [[ ! -f "$PROFILE_FILE" && -f "/root/config/profile.conf" ]]; then
    PROFILE_FILE="/root/config/profile.conf"
fi
if [[ ! -f "$DEFAULTS_FILE" && -f "/root/config/defaults.conf" ]]; then
    DEFAULTS_FILE="/root/config/defaults.conf"
fi
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/system.sh"
source "$SCRIPT_DIR/lib/disk.sh"
source "$SCRIPT_DIR/lib/packages.sh"
for stage in "$STAGE_DIR"/*.sh; do
    source "$stage"
done
source "$POST_DIR/oobe.sh"

mkdir -p "$(dirname "$LOG_FILE")"
ensure_state_dir
if [[ "$RESET_STATE" == "1" ]]; then
    reset_install_state
fi
init_progress_pipe
trap '_cleanup' EXIT
trap '_on_error $LINENO "$BASH_COMMAND"' ERR
trap 'exit 1' INT TERM
_load_defaults
load_profile
apply_defaults
_check_deps

ensure_runtime_package() {
    local pkg="$1"
    if command -v "$pkg" &>/dev/null; then
        return 0
    fi
    if pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1; then
        return 0
    fi
    _die "Не удалось установить $pkg"
}

_on_error() {
    local line="$1"
    local command="$2"
    _die "Ошибка в строке $line: $command"
}

wizard_run() {
    local current=1
    local action="next"
    local autopilot=0

    if [[ "${AUTO_INSTALL:-0}" == "1" ]]; then
        autopilot=1
    fi

    if [[ "$autopilot" -eq 1 ]]; then
        stage_01_welcome >/dev/null 2>&1
        stage_02_preflight >/dev/null 2>&1
        stage_03_disk_setup >/dev/null 2>&1
        stage_04_user_config >/dev/null 2>&1
        stage_05_packages >/dev/null 2>&1
        if stage_06_summary; then
            return 0
        fi
        return 1
    fi

    while true; do
        case "$current" in
            1) stage_01_welcome ;;
            2) stage_02_preflight ;;
            3) stage_03_disk_setup ;;
            4) stage_04_user_config ;;
            5) stage_05_packages ;;
            6) if stage_06_summary; then
                   return 0
               fi
               current=5
               continue
               ;;
        esac

        action=$(whiptail --title "Navigation" --menu "Back / Next" 10 72 2 \
            "back" "Back" \
            "next" "Next" 3>&1 1>&2 2>&3) || return 1

        case "$action" in
            back)
                ((current--))
                [[ "$current" -lt 1 ]] && current=1
                ;;
            next)
                ((current++))
                [[ "$current" -gt 6 ]] && current=6
                ;;
        esac
    done
}

finish_install_prompt() {
    whiptail --title "Готово" --msgbox \
"Установка завершена.\n\nРекомендуется перезагрузить систему, чтобы начать использовать новый Arch Linux.\n\nИспользуйте: reboot" 10 72
}

copy_runtime_to_chroot() {
    local target_root="$1"
    mountpoint -q "$target_root" || _die "Не смонтировано: $target_root"
    mkdir -p "$target_root/root"
    rm -rf "$target_root/root/install" "$target_root/root/config"
    mkdir -p "$target_root/root/install" "$target_root/root/config"
    cp -a "$SCRIPT_DIR/." "$target_root/root/install/"
    cp -a "$SCRIPT_DIR/../config/." "$target_root/root/config/"
    if [[ -f "$SCRIPT_DIR/../backup_tui.sh" ]]; then
        cp "$SCRIPT_DIR/../backup_tui.sh" "$target_root/root/backup_tui.sh"
    fi
}

# ──────────────────────────────────────────────────────────────
# ОБЩИЙ БЛОК: RU ЗЕРКАЛА
# ──────────────────────────────────────────────────────────────
_set_ru_mirrors() {
    cat > /etc/pacman.d/mirrorlist << 'MIRRORS'
# Надёжные RU-зеркала (жёстко прописаны — не зависим от reflector)
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = http://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = https://mirror.truenetwork.ru/archlinux/$repo/os/$arch
Server = http://mirror.truenetwork.ru/archlinux/$repo/os/$arch
Server = https://mirror.regiocoms.ru/archlinux/$repo/os/$arch
Server = https://archlinux.zepto.cloud/$repo/os/$arch
Server = https://mirror.informatik.tu-freiberg.de/arch/$repo/os/$arch
MIRRORS
    _log "RU зеркала установлены"
}

_set_mirrors() {
    if whiptail --yesno "Использовать зеркала для России?\n(Yandex, TrueNetwork, Regiocoms)" 8 60 3>&1 1>&2 2>&3; then
        _set_ru_mirrors
    else
        _log "Используются системные зеркала из настроек среды"
    fi
}

# ──────────────────────────────────────────────────────────────
# ОБЩИЙ БЛОК: CHROOT BASE CONFIG (locale, hostname, user, boot)
# ──────────────────────────────────────────────────────────────
_chroot_base_config() {
    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] chroot base config skipped"
        return 0
    fi

    source /root/install_vars.env

    USER_PASSWORD="${USER_PASSWORD:-arch}"
    ROOT_PASSWORD="${ROOT_PASSWORD:-arch}"

    local ucode_img="intel-ucode.img"
    [[ "${CPU_DRIVER:-intel-ucode}" == "amd-ucode" ]] && ucode_img="amd-ucode.img"
    local root_opts="root=UUID=${ROOT_UUID} rw rootflags=subvol=@"
    if [[ "${USE_LUKS:-no}" == "yes" ]]; then
        root_opts="cryptdevice=UUID=$(blkid -s UUID -o value "$PART_ROOT"):cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@"
    fi

    local tz="${TIMEZONE:-Europe/Moscow}"
    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
    hwclock --systohc
    sed -i 's/^#\(en_US.UTF-8\)/\1/; s/^#\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
    locale-gen >>"$LOG_FILE" 2>&1

    cat > /etc/locale.conf << 'EOF'
LANG=ru_RU.UTF-8
LC_MESSAGES=en_US.UTF-8
LC_TIME=ru_RU.UTF-8
LC_COLLATE=ru_RU.UTF-8
EOF
    cat > /etc/vconsole.conf << 'EOF'
KEYMAP=ru
FONT=cyr-sun16
EOF

    echo "$HOSTNAME" > /etc/hostname
    cat > /etc/hosts << HEOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
HEOF

    env USERNAME="$USERNAME" USER_PASSWORD="$USER_PASSWORD" ROOT_PASSWORD="$ROOT_PASSWORD" HOSTNAME="$HOSTNAME" bash -lc '
        useradd -m -G wheel,audio,video,storage,optical,input -s /bin/zsh "$USERNAME"
        sed -i "s/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/" /etc/sudoers
        if ! printf "%s\n%s\n" "$USER_PASSWORD" "$USER_PASSWORD" | chpasswd; then
            echo "Failed to set user password" >&2
            exit 1
        fi
        if ! printf "%s\n%s\n" "$ROOT_PASSWORD" "$ROOT_PASSWORD" | chpasswd; then
            echo "Failed to set root password" >&2
            exit 1
        fi
        printf "%s\n" "$HOSTNAME" > /etc/hostname
    '

    sed -i '/^#\[multilib\]/{n;s/^#//};/^#\[multilib\]/s/^#//;' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads/ParallelDownloads/; s/^#Color/Color/' /etc/pacman.conf

    if [[ "${USE_LUKS:-no}" == "yes" ]]; then
        if grep -q 'encrypt' /etc/mkinitcpio.conf; then
            :
        elif grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
            sed -i -E 's/^HOOKS=\(([^)]*)block([^)]*)\)/HOOKS=(\1block encrypt\2)/' /etc/mkinitcpio.conf
            if ! grep -q 'encrypt' /etc/mkinitcpio.conf; then
                sed -i -E 's/^HOOKS=\((.*)\)$/HOOKS=(\1 block encrypt)/' /etc/mkinitcpio.conf
            fi
        fi
    fi
    if [[ "${GPU_DRIVER:-auto}" == "nvidia-dkms" ]]; then
        if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
            sed -i -E 's/^MODULES=\(.*\)$/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
        else
            echo 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)' >> /etc/mkinitcpio.conf
        fi
    fi
    mkinitcpio -P >>"$LOG_FILE" 2>&1 || _die "mkinitcpio failed"

    bootctl --esp-path=/boot install >>"$LOG_FILE" 2>&1
    cat > /boot/loader/loader.conf << 'EOF'
default  arch.conf
timeout  3
console-mode max
editor   no
EOF
    cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /${ucode_img}
initrd  /initramfs-linux.img
options ${root_opts} quiet loglevel=3
EOF
    cat > /boot/loader/entries/arch-lts.conf << EOF
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /${ucode_img}
initrd  /initramfs-linux-lts.img
options ${root_opts} quiet loglevel=3
EOF
    cat > /boot/loader/entries/arch-fallback.conf << EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /${ucode_img}
initrd  /initramfs-linux-fallback.img
options ${root_opts}
EOF

    systemctl enable NetworkManager >>"$LOG_FILE" 2>&1

    mkdir -p "/home/$USERNAME/install" "/home/$USERNAME/config"
    cp /root/install/install_tui.sh "/home/$USERNAME/install_tui.sh"
    cp -a /root/install/. "/home/$USERNAME/install/"
    cp -a /root/config/. "/home/$USERNAME/config/"
    cp /root/install_vars.env "/home/$USERNAME/install_vars.env"
    chmod 600 "/home/$USERNAME/install_vars.env"
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
}

# ──────────────────────────────────────────────────────────────
# ОБЩИЙ БЛОК: ВОССТАНОВЛЕНИЕ БЭКАПА В CHROOT
# ──────────────────────────────────────────────────────────────
_restore_backup_in_chroot() {
    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] backup restore skipped"
        return 0
    fi

    source /root/install_vars.env

    # Монтируем по UUID (не /dev/sdX — надёжнее!)
    if [ "$BACKUP_UUID" = "Пропустить" ] || [ -z "$BACKUP_UUID" ]; then
        _log "Бэкап: пропуск (UUID не задан)"
        return 0
    fi

    KIRILL_CHROOT="/mnt_kirill_chroot"
    mkdir -p "$KIRILL_CHROOT"

    _log "Монтируем бэкап-раздел по UUID=$BACKUP_UUID..."
    mount "UUID=$BACKUP_UUID" "$KIRILL_CHROOT" 2>>"$LOG_FILE" || {
        _log "WARN: не удалось смонтировать UUID=$BACKUP_UUID"
        return 0
    }

    BACKUP_ROOT_PATH="$KIRILL_CHROOT/$BACKUP_SUBPATH"
    if [ ! -d "$BACKUP_ROOT_PATH" ]; then
        _log "WARN: путь к бэкапу не найден: $BACKUP_ROOT_PATH"
        if ! umount "$KIRILL_CHROOT" 2>/dev/null; then
            _log "WARN: не удалось размонтировать $KIRILL_CHROOT"
        fi
        return 0
    fi

    # Выбираем последний бэкап по времени модификации
    LATEST=$(find "$BACKUP_ROOT_PATH" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -z "$LATEST" ]; then
        _log "WARN: нет бэкапов в $BACKUP_ROOT_PATH"
        if ! umount "$KIRILL_CHROOT" 2>/dev/null; then
            _log "WARN: не удалось размонтировать $KIRILL_CHROOT"
        fi
        return 0
    fi

    _log "Восстанавливаем из: $LATEST"
    HOME_TARGET="/home/$USERNAME"

    # ── Пакеты из бэкапа (не хардкод!) ──────────────────────
    if [ -f "$LATEST/packages/pkglist_repo.txt" ]; then
        _log "Установка pacman-пакетов из бэкапа..."
        pacman -S --needed --noconfirm - < "$LATEST/packages/pkglist_repo.txt" \
            >>"$LOG_FILE" 2>&1 || _log "WARN: часть пакетов не установилась"
    else
        _log "pkglist_repo.txt не найден — пропуск"
    fi

    # ── KDE конфиги ──────────────────────────────────────────
    [ -d "$LATEST/kde/config" ] && {
        mkdir -p "$HOME_TARGET/.config"
        find "$LATEST/kde/config" -maxdepth 1 -type f \
            -exec cp {} "$HOME_TARGET/.config/" \;
        for dir in plasma kwin kwinscripts kwineffects Kvantum \
                    autostart autostart-scripts kglobalshortcuts menus; do
            [ -d "$LATEST/kde/config/$dir" ] && {
                mkdir -p "$HOME_TARGET/.config/$dir"
                if ! rsync -aAX "$LATEST/kde/config/$dir/" "$HOME_TARGET/.config/$dir/" 2>>"$LOG_FILE"; then
                    _log "WARN: не удалось восстановить KDE каталог $dir"
                fi
            }
        done
    }

    # ── KDE local (kscreen — критично!) ──────────────────────
    [ -d "$LATEST/kde/local" ] && {
        mkdir -p "$HOME_TARGET/.local/share"
        if ! rsync -aAX "$LATEST/kde/local/" "$HOME_TARGET/.local/share/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить KDE local данные"
        fi
    }

    # ── kitty ────────────────────────────────────────────────
    [ -d "$LATEST/kitty" ] && {
        mkdir -p "$HOME_TARGET/.config/kitty"
        if ! rsync -aAX "$LATEST/kitty/" "$HOME_TARGET/.config/kitty/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить kitty конфиги"
        fi
    }

    # ── fastfetch ────────────────────────────────────────────
    [ -d "$LATEST/fastfetch" ] && {
        mkdir -p "$HOME_TARGET/.config/fastfetch"
        find "$LATEST/fastfetch" -maxdepth 1 \
            \( -type f -o \( -type d ! -name "system" \) \) \
            ! -path "$LATEST/fastfetch" | while read -r item; do
            if [ -f "$item" ]; then
                if ! cp "$item" "$HOME_TARGET/.config/fastfetch/" 2>>"$LOG_FILE"; then
                    _log "WARN: не удалось скопировать fastfetch файл $item"
                fi
            elif [ -d "$item" ]; then
                if ! rsync -aAX "$item/" "$HOME_TARGET/.config/fastfetch/$(basename "$item")/" 2>>"$LOG_FILE"; then
                    _log "WARN: не удалось восстановить fastfetch каталог $item"
                fi
            fi
        done
    }

    # ── Shell ─────────────────────────────────────────────────
    for f in .zshrc .zprofile .zshenv; do
        [ -f "$LATEST/shell/$f" ] && {
            if ! cp "$LATEST/shell/$f" "$HOME_TARGET/" 2>>"$LOG_FILE"; then
                _log "WARN: не удалось восстановить shell файл $f"
            fi
        }
    done
    [ -d "$LATEST/shell/omz_custom" ] && {
        mkdir -p "$HOME_TARGET/.oh-my-zsh/custom"
        if ! rsync -aAX "$LATEST/shell/omz_custom/" "$HOME_TARGET/.oh-my-zsh/custom/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить omz custom"
        fi
    }

    # ── GTK ──────────────────────────────────────────────────
    for gtkv in gtk-3.0 gtk-4.0; do
        [ -d "$LATEST/gtk/$gtkv" ] && {
            mkdir -p "$HOME_TARGET/.config/$gtkv"
            if ! rsync -aAX "$LATEST/gtk/$gtkv/" "$HOME_TARGET/.config/$gtkv/" 2>>"$LOG_FILE"; then
                _log "WARN: не удалось восстановить GTK каталог $gtkv"
            fi
        }
    done
    [ -f "$LATEST/gtk/.gtkrc-2.0" ] && {
        if ! cp "$LATEST/gtk/.gtkrc-2.0" "$HOME_TARGET/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить .gtkrc-2.0"
        fi
    }

    # ── Шрифты ───────────────────────────────────────────────
    [ -d "$LATEST/fonts/user" ] && {
        mkdir -p "$HOME_TARGET/.local/share/fonts"
        if ! rsync -aAX "$LATEST/fonts/user/" "$HOME_TARGET/.local/share/fonts/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить пользовательские шрифты"
        fi
    }
    [ -d "$LATEST/fonts/fontconfig" ] && {
        mkdir -p "$HOME_TARGET/.config/fontconfig"
        if ! rsync -aAX "$LATEST/fonts/fontconfig/" "$HOME_TARGET/.config/fontconfig/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить fontconfig"
        fi
    }

    # ── Приложения ───────────────────────────────────────────
    [ -d "$LATEST/apps/TelegramDesktop" ] && {
        mkdir -p "$HOME_TARGET/.local/share/TelegramDesktop"
        if ! rsync -aAX "$LATEST/apps/TelegramDesktop/" "$HOME_TARGET/.local/share/TelegramDesktop/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить TelegramDesktop"
        fi
    }
    for app_dir in vesktop discord "google-chrome" BraveSoftware \
                   "obsidian-config" "Code" "Code - OSS"; do
        [ -d "$LATEST/apps/$app_dir" ] && {
            mkdir -p "$HOME_TARGET/.config/$app_dir"
            if ! rsync -aAX "$LATEST/apps/$app_dir/" "$HOME_TARGET/.config/$app_dir/" 2>>"$LOG_FILE"; then
                _log "WARN: не удалось восстановить приложение $app_dir"
            fi
        }
    done

    # ── SSH (расшифровываем если нужно) ──────────────────────
    if [ -f "$LATEST/apps/ssh_backup.tar.gz.enc" ]; then
        _log "SSH ключи зашифрованы — расшифровка при первом входе пользователя"
        # Кладём зашифрованный архив и скрипт расшифровки
        if ! cp "$LATEST/apps/ssh_backup.tar.gz.enc" "$HOME_TARGET/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось скопировать SSH архив"
        fi
        cat > "$HOME_TARGET/restore_ssh.sh" << 'SSHSCRIPT'
#!/usr/bin/env bash
# Запусти один раз для расшифровки SSH ключей
openssl enc -d -aes-256-cbc -salt -pbkdf2 \
    -in ~/ssh_backup.tar.gz.enc | tar -xzf - -C ~/
chmod 700 ~/.ssh
chmod 600 ~/.ssh/*
rm -f ~/ssh_backup.tar.gz.enc ~/restore_ssh.sh
echo "SSH ключи восстановлены!"
SSHSCRIPT
        chmod +x "$HOME_TARGET/restore_ssh.sh"
        _log "SSH: зашифрованный архив скопирован, скрипт расшифровки создан"
    fi

    if [ -f "$LATEST/apps/gnupg_backup.tar.gz.enc" ]; then
        if ! cp "$LATEST/apps/gnupg_backup.tar.gz.enc" "$HOME_TARGET/" 2>>"$LOG_FILE"; then
            _log "WARN: не удалось скопировать GPG архив"
        fi
        cat > "$HOME_TARGET/restore_gpg.sh" << 'GPGSCRIPT'
#!/usr/bin/env bash
openssl enc -d -aes-256-cbc -salt -pbkdf2 \
    -in ~/gnupg_backup.tar.gz.enc | tar -xzf - -C ~/
chmod 700 ~/.gnupg
rm -f ~/gnupg_backup.tar.gz.enc ~/restore_gpg.sh
echo "GPG ключи восстановлены!"
GPGSCRIPT
        chmod +x "$HOME_TARGET/restore_gpg.sh"
    fi

    # ── SDDM ─────────────────────────────────────────────────
    [ -f "$LATEST/sddm/sddm.conf" ] && {
        if ! cp "$LATEST/sddm/sddm.conf" /etc/ 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить sddm.conf"
        fi
    }
    [ -d "$LATEST/sddm/sddm.conf.d" ] && {
        mkdir -p /etc/sddm.conf.d
        if ! cp -r "$LATEST/sddm/sddm.conf.d/." /etc/sddm.conf.d/ 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить sddm.conf.d"
        fi
    }
    [ -d "$LATEST/sddm/themes" ] && {
        mkdir -p /usr/share/sddm/themes
        if ! cp -r "$LATEST/sddm/themes/." /usr/share/sddm/themes/ 2>>"$LOG_FILE"; then
            _log "WARN: не удалось восстановить SDDM темы"
        fi
        if ! chmod -R 755 /usr/share/sddm/themes/ 2>>"$LOG_FILE"; then
            _log "WARN: не удалось выставить права на SDDM темы"
        fi
    }

    # ── Возвращаем права пользователю (КРИТИЧНО) ─────────────
    chown -R "$USERNAME:$USERNAME" "$HOME_TARGET"

    if ! umount "$KIRILL_CHROOT" 2>>"$LOG_FILE"; then
        _log "WARN: не удалось размонтировать $KIRILL_CHROOT"
    fi
    rm -rf "$KIRILL_CHROOT"
    _log "Восстановление из бэкапа завершено"
}

# ══════════════════════════════════════════════════════════════
# ██████████  WIZARD / OOBE  ██████████
# ══════════════════════════════════════════════════════
if [[ "$MODE" == "wizard" ]]; then
    wizard_run || exit 1
    stage_07_install
    finish_install_prompt
    exit 0
fi

if [[ "$MODE" == "oobe" ]]; then
    run_oobe
    exit 0
fi

# ══════════════════════════════════════════════════════════════
# ██████████  ГЛАВНОЕ МЕНЮ  ██████████
# ══════════════════════════════════════════════════════
if [[ "$MODE" == "menu" ]]; then

command -v whiptail &>/dev/null || ensure_runtime_package libnewt

CHOICE=$(whiptail --title "Teddy's Arch Installer — $(date '+%d.%m.%Y')" \
    --menu \
"Привет, Kirya! Что делаем?\n
  [1] Установка с бэкапом
      Arch + конфиги/пакеты/сессии с КИРИЛЛ\n
  [2] Чистая установка
      Arch без бэкапа, дефолтная KDE\n
  [3] Клонировать диск
      sector-by-sector dd | pv на другой диск" \
    16 74 3 \
    "1" "Установка с бэкапом (рекомендуется)" \
    "2" "Чистая установка (без конфигов)" \
    "3" "Клонировать диск → установить Arch" \
    3>&1 1>&2 2>&3) || exit 0

case "$CHOICE" in
    1) MODE="live" ;;
    2) MODE="fresh" ;;
    3) MODE="clone" ;;
    *) exit 0 ;;
esac

fi  # END menu

# ══════════════════════════════════════════════════════════════
# ██████████  КЛОНИРОВАНИЕ ДИСКА  ██████████
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "clone" ]]; then

command -v pv &>/dev/null || ensure_runtime_package pv

whiptail --title "Клонирование диска" --msgbox \
"Полное клонирование диска (dd + pv).\n
  ИСТОЧНИК → ЦЕЛЬ  (sector-by-sector)\n
После клонирования опционально:\n  • сгенерировать новые UUID\n  • установить Arch на другой диск\n
⚠  ВСЕ ДАННЫЕ НА ЦЕЛЕВОМ ДИСКЕ БУДУТ УНИЧТОЖЕНЫ!" \
16 72

# ── Источник ──────────────────────────────────────────────────
SRC_LIST=()
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    MODEL=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
    SRC_LIST+=("/dev/$NAME" "${SIZE} — ${MODEL:-без модели}")
done < <(lsblk -dno NAME,SIZE,MODEL | grep -v loop)

SRC_DISK=$(whiptail --title "Клонирование — ИСТОЧНИК" \
    --menu "Откуда клонировать (все данные будут скопированы):" \
    16 72 8 "${SRC_LIST[@]}" \
    3>&1 1>&2 2>&3) || { _msg "Отменено."; exit 0; }

# ── Цель ──────────────────────────────────────────────────────
DST_LIST=()
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    MODEL=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
    [[ "/dev/$NAME" == "$SRC_DISK" ]] && continue
    DST_LIST+=("/dev/$NAME" "${SIZE} — ${MODEL:-без модели}")
done < <(lsblk -dno NAME,SIZE,MODEL | grep -v loop)

[ ${#DST_LIST[@]} -eq 0 ] && _die "Нет доступных дисков для клонирования!"

DST_DISK=$(whiptail --title "Клонирование — ЦЕЛЬ ⚠" \
    --menu "Куда клонировать (ВСЕ ДАННЫЕ БУДУТ УНИЧТОЖЕНЫ):" \
    16 72 8 "${DST_LIST[@]}" \
    3>&1 1>&2 2>&3) || { _msg "Отменено."; exit 0; }

SRC_SIZE=$(lsblk -bno SIZE "$SRC_DISK" | head -1)
DST_SIZE=$(lsblk -bno SIZE "$DST_DISK" | head -1)
SRC_GB=$(( SRC_SIZE / 1024 / 1024 / 1024 ))
DST_GB=$(( DST_SIZE / 1024 / 1024 / 1024 ))
SRC_MODEL=$(lsblk -no MODEL "$SRC_DISK" 2>/dev/null | head -1 | xargs || echo "—")
DST_MODEL=$(lsblk -no MODEL "$DST_DISK" 2>/dev/null | head -1 | xargs || echo "—")

[ "$DST_SIZE" -lt "$SRC_SIZE" ] && \
    _msg "⚠ ПРЕДУПРЕЖДЕНИЕ\n\nЦелевой диск (${DST_GB}ГБ) меньше источника (${SRC_GB}ГБ)!\nКлонирование завершится с ошибкой на последних секторах."

whiptail --title "!! ПОДТВЕРЖДЕНИЕ !!" --yesno \
"dd if=$SRC_DISK | pv | dd of=$DST_DISK\n
  ИСТОЧНИК: $SRC_DISK (${SRC_GB}ГБ, $SRC_MODEL)
  ЦЕЛЬ:     $DST_DISK (${DST_GB}ГБ, $DST_MODEL)\n
Время: ~$((SRC_GB / 60 + 1))–$((SRC_GB / 30 + 1)) мин\n
⚠  ВСЁ НА $DST_DISK БУДЕТ УНИЧТОЖЕНО!\nТы уверен?" \
18 72 || { _msg "Отменено."; exit 0; }

CONFIRM_DST=$(whiptail --title "Финальное подтверждение" \
    --inputbox "Введи имя ЦЕЛЕВОГО диска вручную:" \
    8 72 "" 3>&1 1>&2 2>&3) || { _msg "Отменено."; exit 0; }

[ "$CONFIRM_DST" != "$DST_DISK" ] && \
    _die "Не совпадает ($CONFIRM_DST ≠ $DST_DISK). Отменено."

# ── Размонтируем разделы ──────────────────────────────────────
for disk in "$SRC_DISK" "$DST_DISK"; do
    while IFS= read -r part; do
        if ! umount "/dev/$part" 2>/dev/null; then
            _log "WARN: не удалось размонтировать /dev/$part"
        fi
    done < <(lsblk -no NAME "$disk" | tail -n +2)
done

# ── Клонирование с pv ─────────────────────────────────────────
clear
echo ""
echo -e "\033[1;36m  Клонирование: $SRC_DISK → $DST_DISK\033[0m"
echo -e "\033[1;33m  Размер: ${SRC_GB}ГБ\033[0m"
echo -e "\033[0;37m  Ctrl+C для отмены (данные на цели будут испорчены!)\033[0m"
echo ""

dd if="$SRC_DISK" bs=4M 2>/dev/null | \
    pv -s "$SRC_SIZE" -p -t -e -r -b | \
    dd of="$DST_DISK" bs=4M conv=noerror,sync 2>/dev/null

sync; sleep 2
if ! partprobe "$DST_DISK" 2>/dev/null; then
    _log "WARN: не удалось выполнить partprobe для $DST_DISK"
fi
sleep 2

# ── Новые UUID для клона ──────────────────────────────────────
whiptail --title "UUID разделов" --yesno \
"Клонирование завершено!\n\nСгенерировать новые UUID для $DST_DISK?\n(Нужно если оба диска будут подключены одновременно)" \
10 72 && {
    _info "Генерируем новые UUID..."
    while IFS= read -r part; do
        PPATH="/dev/$part"
        FS=$(lsblk -no FSTYPE "$PPATH" 2>/dev/null | head -1 || echo "")
        case "$FS" in
            ext4)  tune2fs -U random "$PPATH" >> "$LOG_FILE" 2>&1 ;;
            btrfs) btrfstune -u "$PPATH" >> "$LOG_FILE" 2>&1 ;;
        esac
    done < <(lsblk -no NAME "$DST_DISK" | tail -n +2)
    _msg "Новые UUID сгенерированы.\nОбнови /etc/fstab если будешь загружаться с клона."
}

whiptail --title "Клонирование завершено!" --yesno \
"$DST_DISK успешно склонирован!\n\nУстановить Arch Linux на отдельный диск?" \
10 72 && MODE="fresh" || { _msg "Готово!"; exit 0; }

fi  # END clone

# ══════════════════════════════════════════════════════════════
# ██████████  ЭТАП 1: УСТАНОВКА С БЭКАПОМ  ██████████
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "live" ]]; then

command -v whiptail &>/dev/null || ensure_runtime_package libnewt
preflight_checks
_set_mirrors

whiptail --title "Установка Arch с бэкапом" --msgbox \
"Пакеты будут взяты из бэкапа (pkglist_repo.txt + pkglist_aur.txt),\nа не из хардкодного списка!\n\nKDE, kitty, fastfetch, сессии — всё восстановится\nавтоматически в chroot до первого входа." \
12 72

USERNAME=$(_input "Пользователь" "Имя пользователя:" "kirill") || _die "Отменено."
[[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || _die "Некорректное имя: '$USERNAME'"
HOSTNAME=$(_input "Hostname" "Имя компьютера:" "archbox") || _die "Отменено."
validate_hostname "$HOSTNAME"

TARGET_DISK=$(_select_target_disk)
validate_disk_path "$TARGET_DISK" || _die "Некорректный диск: $TARGET_DISK"
IFS='|' read -r PART_EFI PART_ROOT <<< "$(_derive_partition_names "$TARGET_DISK")"
USE_LUKS=$(ask_luks_enabled)
export USE_LUKS
if [[ "$USE_LUKS" == "yes" ]]; then
    LUKS_PASSWORD=$(ask_luks_password) || _die "Отменено."
    export LUKS_PASSWORD
fi

if [[ "$DRY_RUN" == "1" ]]; then
    _msg "Dry run: планирование завершено, изменения не применялись."
    exit 0
fi

# ── Выбор бэкап-раздела (вручную, с меню!) ────────────────────
BK_LIST=("Пропустить" "Восстановить вручную после перезагрузки")
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    FSTYPE=$(echo "$line" | awk '{print $3}')
    LABEL=$(echo "$line" | awk '{print $4}')
    [[ "/dev/$NAME" == "$TARGET_DISK" ]] && continue
    BK_LIST+=("/dev/$NAME" "${SIZE} [${FSTYPE:-?}] LABEL=${LABEL:-—}")
done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL | grep -v "^loop" | grep -v "^$")

BACKUP_DISK=$(whiptail --title "Раздел с бэкапом (КИРИЛЛ)" \
    --menu \
    "Выбери раздел с бэкапом.\n(КИРИЛЛ — обычно FAT32/NTFS ~931ГБ)" \
    18 74 10 "${BK_LIST[@]}" \
    3>&1 1>&2 2>&3) || BACKUP_DISK="Пропустить"
validate_backup_device "$BACKUP_DISK" || _die "Некорректный раздел бэкапа: $BACKUP_DISK"

# Сохраняем UUID, не /dev/sdX!
BACKUP_UUID="Пропустить"
BACKUP_SUBPATH="установочные файлы/linux/kde_backup"
if [ "$BACKUP_DISK" != "Пропустить" ]; then
    BACKUP_UUID=$(blkid -s UUID -o value "$BACKUP_DISK" 2>/dev/null || echo "")
    [ -z "$BACKUP_UUID" ] && {
        _msg "Не удалось получить UUID для $BACKUP_DISK.\nВосстановление будет пропущено."
        BACKUP_UUID="Пропустить"
    }
    BACKUP_SUBPATH=$(_input "Путь к бэкапам" \
        "Путь к kde_backup на диске (без ведущего /):" \
        "установочные файлы/linux/kde_backup") || \
        BACKUP_SUBPATH="установочные файлы/linux/kde_backup"
fi

_log "=== Установка с бэкапом ==="
_log "Диск: $TARGET_DISK, Пользователь: $USERNAME, Хост: $HOSTNAME"
_log "Бэкап UUID: $BACKUP_UUID, Path: $BACKUP_SUBPATH"

{
    exec 3>&1
    exec 1>>"$LOG_FILE" 2>&1

    _step 2 "Синхронизация времени..."
    if ! timedatectl set-ntp true; then
        _log "WARN: не удалось синхронизировать время через timedatectl"
    fi

    run_stage "partitioning" _partition_disk "$TARGET_DISK" "$PART_EFI" "$PART_ROOT" "$USE_LUKS"

    _step 22 "pacstrap (~600МБ, 5–15 мин)..."
    pacstrap -K /mnt \
        base base-devel linux linux-headers linux-lts linux-firmware \
        btrfs-progs intel-ucode efibootmgr \
        networkmanager nano vim sudo \
        zsh git curl wget htop rsync \
        man-db man-pages openssh bash-completion whiptail

    _step 48 "Генерация fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    _step 52 "Подготовка chroot..."
    if [[ "${USE_LUKS:-no}" == "yes" ]]; then
        ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
    else
        ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
    fi
    cat > /mnt/root/install_vars.env << ENVEOF
USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
ROOT_UUID="$ROOT_UUID"
PART_EFI="$PART_EFI"
PART_ROOT="$PART_ROOT"
USE_LUKS="${USE_LUKS:-no}"
CPU_DRIVER="${CPU_DRIVER:-auto}"
GPU_DRIVER="${GPU_DRIVER:-auto}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
ZRAM_SIZE_MB="${ZRAM_SIZE_MB:-8192}"
BACKUP_UUID="$BACKUP_UUID"
BACKUP_SUBPATH="$BACKUP_SUBPATH"
ENVEOF
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    copy_runtime_to_chroot /mnt

    _step 55 "chroot: настройка системы + восстановление бэкапа..."
    arch-chroot /mnt env USER_PASSWORD="$USER_PASSWORD" ROOT_PASSWORD="$ROOT_PASSWORD" /bin/bash /root/install/install_tui.sh --chroot

    _step 100 "Готово!"
    sleep 1

} | whiptail --title "Установка Arch Linux с бэкапом..." \
    --gauge "Инициализация..." 8 74 0

if ! umount -R /mnt 2>>"$LOG_FILE"; then
    _log "WARN: не удалось размонтировать /mnt"
fi
whiptail --title "✓ ЭТАП 1 ЗАВЕРШЁН!" --msgbox \
"Arch установлен + бэкап восстановлен в chroot!\n
  ✓ Пользователь $USERNAME (пароль: arch — СМЕНИ!)\n  ✓ Конфиги KDE, kitty, fastfetch\n  ✓ Пакеты из pkglist_repo.txt\n  ✓ SDDM, шрифты, GTK\n
Следующие шаги:\n  1. Вытащи флешку\n  2. Нажми OK — перезагрузка\n  3. Войди как $USERNAME\n  4. bash ~/install_tui.sh --post" \
22 72

_info "Перезагрузка через 3 секунды..."
sleep 3
reboot

fi  # END live

# ══════════════════════════════════════════════════════════════
# ██████████  CHROOT (с бэкапом)  ██████████
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "chroot" ]]; then
    _chroot_base_config
    _restore_backup_in_chroot
fi

# ══════════════════════════════════════════════════════════════
# ██████████  ЭТАП 1: ЧИСТАЯ УСТАНОВКА  ██████████
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "fresh" ]]; then

command -v whiptail &>/dev/null || ensure_runtime_package libnewt
preflight_checks
_set_mirrors

whiptail --title "Чистая установка Arch" --msgbox \
"Arch + KDE Plasma + базовые пакеты.\nБез восстановления конфигов.\n\nКонфиги KDE, kitty, fastfetch — дефолтные.\nВосстановить бэкап можно потом через backup_tui.sh." \
12 72

USERNAME=$(_input "Пользователь" "Имя пользователя:" "${USERNAME:-teddy}") || _die "Отменено."
[[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || _die "Некорректное имя: '$USERNAME'"
HOSTNAME=$(_input "Hostname" "Имя компьютера:" "${HOSTNAME:-archbox}") || _die "Отменено."
validate_hostname "$HOSTNAME"

TARGET_DISK=$(_select_target_disk)
validate_disk_path "$TARGET_DISK" || _die "Некорректный диск: $TARGET_DISK"
IFS='|' read -r PART_EFI PART_ROOT <<< "$(_derive_partition_names "$TARGET_DISK")"
if [[ "${USE_LUKS:-no}" == "yes" ]]; then
    USE_LUKS=yes
else
    USE_LUKS=$(ask_luks_enabled)
fi
export USE_LUKS
if [[ "$USE_LUKS" == "yes" ]]; then
    LUKS_PASSWORD=$(ask_luks_password) || _die "Отменено."
    export LUKS_PASSWORD
fi

if [[ "$DRY_RUN" == "1" ]]; then
    _msg "Dry run: планирование завершено, изменения не применялись."
    exit 0
fi

_log "=== Чистая установка ==="
_log "Диск: $TARGET_DISK, Пользователь: $USERNAME, Хост: $HOSTNAME"

{
    exec 3>&1
    exec 1>>"$LOG_FILE" 2>&1

    _step 2 "Синхронизация времени..."
    if ! timedatectl set-ntp true; then
        _log "WARN: не удалось синхронизировать время через timedatectl"
    fi

    run_stage "partitioning" _partition_disk "$TARGET_DISK" "$PART_EFI" "$PART_ROOT" "$USE_LUKS"

    _step 22 "pacstrap..."
    pacstrap -K /mnt \
        base base-devel linux linux-headers linux-lts linux-firmware \
        btrfs-progs intel-ucode efibootmgr \
        networkmanager nano vim sudo \
        zsh git curl wget htop rsync \
        man-db man-pages openssh bash-completion whiptail

    _step 48 "Генерация fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    _step 52 "Подготовка chroot..."
    if [[ "${USE_LUKS:-no}" == "yes" ]]; then
        ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
    else
        ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
    fi
    cat > /mnt/root/install_vars.env << ENVEOF
USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
ROOT_UUID="$ROOT_UUID"
PART_EFI="$PART_EFI"
PART_ROOT="$PART_ROOT"
USE_LUKS="${USE_LUKS:-no}"
CPU_DRIVER="${CPU_DRIVER:-auto}"
GPU_DRIVER="${GPU_DRIVER:-auto}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
ZRAM_SIZE_MB="${ZRAM_SIZE_MB:-8192}"
BACKUP_UUID="Пропустить"
BACKUP_SUBPATH=""
ENVEOF
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    copy_runtime_to_chroot /mnt

    _step 55 "chroot: настройка (без бэкапа)..."
    arch-chroot /mnt env USER_PASSWORD="$USER_PASSWORD" ROOT_PASSWORD="$ROOT_PASSWORD" /bin/bash /root/install/install_tui.sh --chroot-fresh

    _step 100 "Готово!"
    sleep 1

} | whiptail --title "Чистая установка..." --gauge "Инициализация..." 8 74 0

if ! umount -R /mnt 2>>"$LOG_FILE"; then
    _log "WARN: не удалось размонтировать /mnt"
fi
whiptail --title "✓ ЧИСТАЯ УСТАНОВКА ЗАВЕРШЕНА!" --msgbox \
"Arch установлен!\n  ✓ Пользователь $USERNAME (пароль: arch — СМЕНИ!)\n  ✓ btrfs + linux + linux-lts\n  ✓ NetworkManager\n\nСледующие шаги:\n  1. Вытащи флешку\n  2. Нажми OK — перезагрузка\n  3. bash ~/install_tui.sh --post" \
18 72

_info "Перезагрузка через 3 секунды..."
sleep 3
reboot

fi  # END fresh

# ══════════════════════════════════════════════════════════════
# ██████████  CHROOT-FRESH (без бэкапа)  ██████████
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "chroot_fresh" ]]; then
    _chroot_base_config
    # Восстановление бэкапа пропускается намеренно
    _log "Чистая установка: бэкап пропущен"
fi

# ══════════════════════════════════════════════════════════════
# ██████████  ЭТАП 2: POST (после перезагрузки)  ██████████
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "post" ]]; then

if [[ "$DRY_RUN" == "1" ]]; then
    _msg "Dry run: post-этап не выполнялся."
    exit 0
fi

[ "$(id -u)" -eq 0 ] && _die "Запускай от обычного пользователя!"
sudo -v || _die "Нужны права sudo для продолжения!"
while kill -0 "$$" 2>/dev/null; do
    if ! sudo -n true >/dev/null 2>&1; then
        _log "WARN: sudo keepalive stopped"
        break
    fi
    sleep 55
done 2>/dev/null &
SUDO_KEEP_PID=$!
if [[ -f ~/install_vars.env ]]; then
    if ! source ~/install_vars.env; then
        _log "WARN: не удалось загрузить ~/install_vars.env"
    fi
fi
USERNAME=$(whoami)
IS_BACKUP_INSTALL=false
[ -f "$HOME/.config/kdeglobals" ] && IS_BACKUP_INSTALL=true  # конфиги уже есть — это установка с бэкапом

whiptail --title "Этап 2 — Настройка" --msgbox \
"Сейчас установятся:\n
  • драйверы GPU ($GPU_DRIVER)\n  • KDE Plasma 6 + Wayland + SDDM
  • kitty, fastfetch\n  • paru (AUR-хелпер)\n
$(if $IS_BACKUP_INSTALL; then
    echo "  • AUR пакеты из бэкапа (pkglist_aur.txt)\n  • Разработка, игры, AI"
else
    echo "  • Базовые программы (хардкод)\n  • Steam, Python, Docker"
fi)\n
  • zram, snapper, ufw" \
20 72

{
    exec 3>&1
    exec 1>>"$LOG_FILE" 2>&1

    _step 2 "Обновление системы..."
    sudo pacman -Syu --noconfirm

    _step 5 "multilib..."
    sudo sed -i '/^#\[multilib\]/{n;s/^#//};/^#\[multilib\]/s/^#//;' /etc/pacman.conf
    sudo sed -i 's/^#ParallelDownloads/ParallelDownloads/; s/^#Color/Color/' /etc/pacman.conf
    sudo pacman -Syu --noconfirm

    _step 8 "paru..."
    if ! command -v paru &>/dev/null; then
        sudo pacman -S --needed --noconfirm git base-devel
        git clone https://aur.archlinux.org/paru.git /tmp/paru_b
        cd /tmp/paru_b && makepkg -si --noconfirm
        cd ~ && rm -rf /tmp/paru_b
    fi

_step 12 "GPU драйверы..."
case "${GPU_DRIVER:-auto}" in
    nvidia-dkms)
        sudo pacman -S --needed --noconfirm \
            nvidia nvidia-utils nvidia-settings \
            lib32-nvidia-utils lib32-opencl-nvidia \
            opencl-nvidia libva-nvidia-driver >>"$LOG_FILE" 2>&1
        sudo sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
        sudo sed -i 's/ kms//' /etc/mkinitcpio.conf
        sudo mkinitcpio -P >>"$LOG_FILE" 2>&1
        sudo mkdir -p /etc/pacman.d/hooks
        sudo tee /etc/pacman.d/hooks/nvidia.hook > /dev/null << 'HOOK'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia
Target=linux
[Action]
Description=Updating NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
NeedsTargets
Exec=/bin/sh -c 'while read -r trg; do case $trg in linux) exit 0; esac; done; /usr/bin/mkinitcpio -P'
HOOK
        sudo tee /etc/modprobe.d/nvidia.conf > /dev/null << 'NVCFG'
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
NVCFG
        ;;
    amdgpu)
        sudo pacman -S --needed --noconfirm mesa libva-mesa-driver vulkan-radeon >>"$LOG_FILE" 2>&1
        ;;
    intel-media-driver)
        sudo pacman -S --needed --noconfirm intel-media-driver >>"$LOG_FILE" 2>&1
        ;;
    *)
        _log "GPU driver ${GPU_DRIVER:-auto}: skipping GPU-specific packages"
        ;;
esac

_step 22 "KDE Plasma 6 + Wayland..."
sudo pacman -S --needed --noconfirm \
    plasma-meta kde-utilities-meta kde-system-meta \
    sddm sddm-kcm xdg-desktop-portal-kde xdg-user-dirs packagekit-qt6 \
    dolphin kate ark spectacle gwenview okular kcalc partitionmanager \
    >>"$LOG_FILE" 2>&1

_step 30 "PipeWire + Bluetooth..."
sudo pacman -S --needed --noconfirm \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber qpwgraph \
    bluez bluez-utils bluedevil >>"$LOG_FILE" 2>&1
_run_optional "pipewire user services" systemctl --user enable --now pipewire pipewire-pulse wireplumber >>"$LOG_FILE" 2>&1
_run_optional "bluetooth service" sudo systemctl enable --now bluetooth >>"$LOG_FILE" 2>&1

_step 34 "kitty + fastfetch + шрифты..."
sudo pacman -S --needed --noconfirm \
    kitty fastfetch \
    noto-fonts noto-fonts-cjk noto-fonts-emoji \
    ttf-liberation ttf-dejavu ttf-jetbrains-mono-nerd \
    >>"$LOG_FILE" 2>&1
_run_optional "sddm service" sudo systemctl enable sddm >>"$LOG_FILE" 2>&1

} | whiptail --title "Базовые пакеты..." --gauge "Инициализация..." 8 74 0

# ── Монтирование дисков через МЕНЮ (не ввод UUID вручную!) ────
sudo pacman -S --needed --noconfirm ntfs-3g >>"$LOG_FILE" 2>&1
sudo mkdir -p /mnt/games_e /mnt/games_d /mnt/kirill

# Строим список NTFS/FAT32 разделов для выбора
DATA_PARTS=()
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    FSTYPE=$(echo "$line" | awk '{print $3}')
    LABEL=$(echo "$line" | awk '{print $4}')
    DATA_PARTS+=("/dev/$NAME" "${SIZE} [${FSTYPE}] LABEL=${LABEL:-—}")
done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL | \
    awk '$3=="ntfs" || $3=="ntfs-3g" || $3=="vfat"')

CHOICE_E=""
CHOICE_D=""
CHOICE_K=""

if [ ${#DATA_PARTS[@]} -gt 0 ]; then
    CHOICE_E=$(whiptail --title "Диски — games_e" \
        --menu "Выбери раздел для /mnt/games_e (2ТБ NTFS)\nили нажми Отмена:" \
        16 74 8 "${DATA_PARTS[@]}" "Пропустить" "Не монтировать" \
        3>&1 1>&2 2>&3) || CHOICE_E="Пропустить"

    CHOICE_D=$(whiptail --title "Диски — games_d" \
        --menu "Выбери раздел для /mnt/games_d (1.6ТБ NTFS):" \
        16 74 8 "${DATA_PARTS[@]}" "Пропустить" "Не монтировать" \
        3>&1 1>&2 2>&3) || CHOICE_D="Пропустить"

    CHOICE_K=$(whiptail --title "Диски — КИРИЛЛ" \
        --menu "Выбери раздел для /mnt/kirill (КИРИЛЛ, FAT32):" \
        16 74 8 "${DATA_PARTS[@]}" "Пропустить" "Не монтировать" \
        3>&1 1>&2 2>&3) || CHOICE_K="Пропустить"
fi

# Записываем в fstab по UUID (извлекаем сами — не вводим вручную)
{
echo ""
echo "# Диски Teddy — добавлено install_tui.sh"
[ "$CHOICE_E" != "Пропустить" ] && [ -n "$CHOICE_E" ] && \
    printf "UUID=%s  /mnt/games_e  ntfs-3g  defaults,uid=1000,gid=1000,umask=022,nofail  0 0\n" \
        "$(sudo blkid -s UUID -o value "$CHOICE_E" 2>/dev/null || echo "")"
[ "$CHOICE_D" != "Пропустить" ] && [ -n "$CHOICE_D" ] && \
    printf "UUID=%s  /mnt/games_d  ntfs-3g  defaults,uid=1000,gid=1000,umask=022,nofail  0 0\n" \
        "$(sudo blkid -s UUID -o value "$CHOICE_D" 2>/dev/null || echo "")"
[ "$CHOICE_K" != "Пропустить" ] && [ -n "$CHOICE_K" ] && \
    printf "UUID=%s  /mnt/kirill  vfat  defaults,uid=1000,gid=1000,umask=022,utf8=1,nofail  0 0\n" \
        "$(sudo blkid -s UUID -o value "$CHOICE_K" 2>/dev/null || echo "")"
} | sudo tee -a /etc/fstab > /dev/null

_run_optional "mount data partitions" sudo mount -a 2>>"$LOG_FILE"

{
# ── AUR пакеты: из бэкапа ИЛИ хардкод ────────────────────────
_step 40 "AUR пакеты..."
KBR="/mnt/kirill/установочные файлы/linux/kde_backup"
AUR_FROM_BACKUP=false

if [ -d "$KBR" ]; then
    LATEST_BK=$(find "$KBR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -n "$LATEST_BK" ] && [ -f "$LATEST_BK/packages/pkglist_aur.txt" ]; then
        _log "AUR: устанавливаем из бэкапа..."
        paru -S --needed --noconfirm - < "$LATEST_BK/packages/pkglist_aur.txt" \
            >>"$LOG_FILE" 2>&1 || _log "WARN: часть AUR пакетов не установилась"
        AUR_FROM_BACKUP=true
    fi
fi

if ! $AUR_FROM_BACKUP; then
    _log "AUR: бэкап не найден — базовый хардкод"
    _run_optional "AUR base packages" paru -S --needed --noconfirm \
        telegram-desktop vesktop \
        visual-studio-code-bin \
        google-chrome ttf-ms-fonts \
        heroic-games-launcher-bin \
        lmstudio-bin claude-desktop-bin \
        2>>"$LOG_FILE"
fi

# ── Разработка (только при чистой установке) ──────────────────
if ! $IS_BACKUP_INSTALL; then
    _step 52 "Разработка: Python, Docker, Node..."
    sudo pacman -S --needed --noconfirm \
        python python-pip python-virtualenv pyenv \
        docker docker-compose \
        android-tools android-udev >>"$LOG_FILE" 2>&1
    _run_optional "nvm install" paru -S --needed --noconfirm nvm 2>>"$LOG_FILE"
    if ! command -v bun >/dev/null 2>&1; then
        tmp_bun="$(mktemp /tmp/bun-install.XXXXXX.sh)"
        _run_optional "bun install" curl -fsSL https://bun.sh/install -o "$tmp_bun" >>"$LOG_FILE" 2>&1
        _run_optional "bun setup" bash "$tmp_bun" >>"$LOG_FILE" 2>&1
        rm -f "$tmp_bun"
    fi
    _run_optional "docker service" sudo systemctl enable --now docker >>"$LOG_FILE" 2>&1
    sudo usermod -aG docker "$USERNAME"

    # ── Игры ──────────────────────────────────────────────────
    _step 60 "Steam, Lutris, MangoHUD..."
    sudo pacman -S --needed --noconfirm \
        steam gamemode lib32-gamemode \
        mangohud lib32-mangohud \
        lutris wine wine-mono wine-gecko winetricks >>"$LOG_FILE" 2>&1
    sudo usermod -aG gamemode "$USERNAME"

    # ── AI ────────────────────────────────────────────────────
    _step 68 "Ollama..."
    sudo pacman -S --needed --noconfirm ollama-cuda 2>>"$LOG_FILE" || \
        sudo pacman -S --needed --noconfirm ollama >>"$LOG_FILE" 2>&1
    _run_optional "ollama service" sudo systemctl enable --now ollama >>"$LOG_FILE" 2>&1
fi

# ── Оптимизации (всегда) ──────────────────────────────────────
_step 78 "zram..."
zram_size="${ZRAM_SIZE_MB:-8192}"
[[ "$zram_size" =~ ^[0-9]+$ ]] || zram_size=8192
sudo pacman -S --needed --noconfirm zram-generator >>"$LOG_FILE" 2>&1
sudo tee /etc/systemd/zram-generator.conf > /dev/null << ZRAM
[zram0]
zram-size = ${zram_size}
compression-algorithm = zstd
ZRAM
sudo systemctl daemon-reload
_run_optional "zram setup service" sudo systemctl start systemd-zram-setup@zram0.service 2>>"$LOG_FILE"

_step 82 "IO scheduler + power-profiles..."
sudo tee /etc/udev/rules.d/60-io-scheduler.rules > /dev/null << 'UDEV'
ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
UDEV
sudo pacman -S --needed --noconfirm power-profiles-daemon >>"$LOG_FILE" 2>&1
_run_optional "power-profiles-daemon" sudo systemctl enable --now power-profiles-daemon >>"$LOG_FILE" 2>&1
_run_optional "powerprofilesctl performance" powerprofilesctl set performance 2>>"$LOG_FILE"

_step 86 "Snapper..."
sudo pacman -S --needed --noconfirm snapper snap-pac >>"$LOG_FILE" 2>&1
_run_optional "snapper config" sudo snapper -c root create-config / 2>>"$LOG_FILE"
_run_optional "snapper tuning" sudo sed -i \
    -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
    -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
    -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
    -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
    -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
    /etc/snapper/configs/root 2>>"$LOG_FILE"
_run_optional "snapper timers" sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >>"$LOG_FILE" 2>&1

_step 90 "ufw + paccache..."
sudo pacman -S --needed --noconfirm ufw pacman-contrib >>"$LOG_FILE" 2>&1
_run_optional "ufw default deny" sudo ufw default deny incoming >>"$LOG_FILE" 2>&1
_run_optional "ufw default allow" sudo ufw default allow outgoing >>"$LOG_FILE" 2>&1
_run_optional "ufw service" sudo systemctl enable --now ufw >>"$LOG_FILE" 2>&1
_run_optional "paccache timer" sudo systemctl enable --now paccache.timer >>"$LOG_FILE" 2>&1

_step 100 "Готово!"
sleep 1

} | whiptail --title "Установка пакетов и оптимизации..." \
    --gauge "Подготовка..." 8 74 0

# ── Смена пароля ──────────────────────────────────────────────
whiptail --title "Смена пароля" --msgbox \
"Всё установлено!\n\nСейчас задай постоянный пароль.\n(Текущий временный пароль: arch)" \
10 72

clear
echo ""
echo "══════════════════════════════════"
echo "  Новый пароль для $USERNAME:"
echo "══════════════════════════════════"
passwd

# ── Финал ─────────────────────────────────────────────────────
whiptail --title "✓ УСТАНОВКА ЗАВЕРШЕНА!" --msgbox \
"Arch Linux полностью настроен!\n
  ✓ NVIDIA RTX 3050 + hook\n  ✓ KDE Plasma 6 + Wayland
  ✓ kitty + fastfetch\n  ✓ Пакеты $(if $IS_BACKUP_INSTALL; then echo "из бэкапа"; else echo "базовый набор"; fi)
  ✓ zram, snapper, ufw\n
После перезагрузки:\n  → В SDDM выбери: Plasma (Wayland)\n  → Проверь: nvidia-smi\n  → SSH ключи: bash ~/restore_ssh.sh (если есть)\n
Лог: $LOG_FILE" \
24 72

read -rp "Перезагрузиться сейчас? [y/N] " do_r
if [[ "$do_r" =~ ^[Yy]$ ]]; then
    _info "Перезагрузка..."
    sleep 2
    sudo reboot
else
    _cleanup
fi

fi  # END post
