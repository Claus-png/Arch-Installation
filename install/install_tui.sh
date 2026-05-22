#!/usr/bin/env bash
# TOOL_NAME: install_tui
# TOOL_DESC: TUI-установщик Arch Linux — Teddy (i5-12400F · RTX 3050 · btrfs)
# TOOL_MODE: gui

set -u -o pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

MODE="${1:-wizard}"
[[ "$MODE" == "--post" ]]          && MODE="post"
[[ "$MODE" == "--chroot" ]]        && MODE="chroot"
[[ "$MODE" == "--chroot-fresh" ]]  && MODE="chroot_fresh"
[[ "$MODE" == "--oobe" ]]          && MODE="oobe"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/var/log/install.log}"
PROFILE_FILE="${PROFILE_FILE:-$SCRIPT_DIR/../config/profile.conf}"
DEFAULTS_FILE="${DEFAULTS_FILE:-$SCRIPT_DIR/../config/defaults.conf}"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/system.sh"
source "$SCRIPT_DIR/lib/disk.sh"
source "$SCRIPT_DIR/lib/packages.sh"
for stage in "$SCRIPT_DIR/../stages"/*.sh; do
    source "$stage"
 done
source "$SCRIPT_DIR/../post/oobe.sh"

mkdir -p "$(dirname "$LOG_FILE")"
ensure_state_dir
init_progress_pipe
trap '_cleanup' EXIT
trap 'exit 1' INT TERM
_load_defaults
load_profile
apply_defaults

wizard_run() {
    local current=1
    local action="next"
    local autopilot=0

    if [[ -n "${DISK:-}" && -n "${USERNAME:-}" ]]; then
        autopilot=1
    fi

    start_progress_bar "Wizard" "Preparing installer"
    progress_update 5

    if [[ "$autopilot" -eq 1 ]]; then
        stage_01_welcome >/dev/null 2>&1 || true
        stage_02_preflight >/dev/null 2>&1 || true
        stage_03_disk_setup >/dev/null 2>&1 || true
        stage_04_user_config >/dev/null 2>&1 || true
        stage_05_packages >/dev/null 2>&1 || true
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

# ──────────────────────────────────────────────────────────────
# ОБЩИЙ БЛОК: CHROOT BASE CONFIG (locale, hostname, user, boot)
# ──────────────────────────────────────────────────────────────
_chroot_base_config() {
    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] chroot base config skipped"
        return 0
    fi

    # Вызывается уже внутри chroot, переменные из install_vars.env
    source /root/install_vars.env

    # Локаль и время
    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
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

    # Хост
    echo "$HOSTNAME" > /etc/hostname
    cat > /etc/hosts << HEOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
HEOF

    # Пользователь (пароль временный — сменим в финале --post)
    useradd -m -G wheel,audio,video,storage,optical,input -s /bin/zsh "$USERNAME"
    sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)/\1/' /etc/sudoers
    echo "$USERNAME:arch" | chpasswd
    echo "root:arch" | chpasswd

    # multilib
    sed -i '/^#\[multilib\]/{n;s/^#//};/^#\[multilib\]/s/^#//;' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads/ParallelDownloads/; s/^#Color/Color/' /etc/pacman.conf
    pacman -Sy >>"$LOG_FILE" 2>&1

    # systemd-boot
    bootctl install --path=/boot >>"$LOG_FILE" 2>&1
    cat > /boot/loader/loader.conf << 'EOF'
default  arch.conf
timeout  3
console-mode max
editor   no
EOF
    cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw \\
        rootflags=subvol=@ \\
        quiet loglevel=3 \\
        nvidia_drm.modeset=1 \\
        nvidia_drm.fbdev=1
EOF
    cat > /boot/loader/entries/arch-lts.conf << EOF
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet loglevel=3
EOF
    cat > /boot/loader/entries/arch-fallback.conf << EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options root=UUID=${ROOT_UUID} rw rootflags=subvol=@
EOF

    systemctl enable NetworkManager >>"$LOG_FILE" 2>&1

    # Перекладываем скрипт для --post
    cp /root/install_tui.sh "/home/$USERNAME/install_tui.sh"
    cp /root/install_vars.env "/home/$USERNAME/install_vars.env"
    chown "$USERNAME:$USERNAME" \
        "/home/$USERNAME/install_tui.sh" \
        "/home/$USERNAME/install_vars.env"
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
        umount "$KIRILL_CHROOT" 2>/dev/null || true
        return 0
    fi

    # Выбираем последний бэкап
    LATEST=$(find "$BACKUP_ROOT_PATH" -maxdepth 1 -mindepth 1 -type d | sort -r | head -1)
    if [ -z "$LATEST" ]; then
        _log "WARN: нет бэкапов в $BACKUP_ROOT_PATH"
        umount "$KIRILL_CHROOT" 2>/dev/null || true
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
                rsync -aAX "$LATEST/kde/config/$dir/" \
                    "$HOME_TARGET/.config/$dir/" 2>>"$LOG_FILE" || true
            }
        done
    }

    # ── KDE local (kscreen — критично!) ──────────────────────
    [ -d "$LATEST/kde/local" ] && {
        mkdir -p "$HOME_TARGET/.local/share"
        rsync -aAX "$LATEST/kde/local/" \
            "$HOME_TARGET/.local/share/" 2>>"$LOG_FILE" || true
    }

    # ── kitty ────────────────────────────────────────────────
    [ -d "$LATEST/kitty" ] && {
        mkdir -p "$HOME_TARGET/.config/kitty"
        rsync -aAX "$LATEST/kitty/" \
            "$HOME_TARGET/.config/kitty/" 2>>"$LOG_FILE" || true
    }

    # ── fastfetch ────────────────────────────────────────────
    [ -d "$LATEST/fastfetch" ] && {
        mkdir -p "$HOME_TARGET/.config/fastfetch"
        find "$LATEST/fastfetch" -maxdepth 1 \
            \( -type f -o \( -type d ! -name "system" \) \) \
            ! -path "$LATEST/fastfetch" | while read -r item; do
            if [ -f "$item" ]; then
                cp "$item" "$HOME_TARGET/.config/fastfetch/" 2>>"$LOG_FILE" || true
            elif [ -d "$item" ]; then
                rsync -aAX "$item/" \
                    "$HOME_TARGET/.config/fastfetch/$(basename "$item")/" 2>>"$LOG_FILE" || true
            fi
        done
    }

    # ── Shell ─────────────────────────────────────────────────
    for f in .zshrc .zprofile .zshenv; do
        [ -f "$LATEST/shell/$f" ] && cp "$LATEST/shell/$f" "$HOME_TARGET/" 2>>"$LOG_FILE" || true
    done
    [ -d "$LATEST/shell/omz_custom" ] && {
        mkdir -p "$HOME_TARGET/.oh-my-zsh/custom"
        rsync -aAX "$LATEST/shell/omz_custom/" \
            "$HOME_TARGET/.oh-my-zsh/custom/" 2>>"$LOG_FILE" || true
    }

    # ── GTK ──────────────────────────────────────────────────
    for gtkv in gtk-3.0 gtk-4.0; do
        [ -d "$LATEST/gtk/$gtkv" ] && {
            mkdir -p "$HOME_TARGET/.config/$gtkv"
            rsync -aAX "$LATEST/gtk/$gtkv/" "$HOME_TARGET/.config/$gtkv/" 2>>"$LOG_FILE" || true
        }
    done
    [ -f "$LATEST/gtk/.gtkrc-2.0" ] && cp "$LATEST/gtk/.gtkrc-2.0" "$HOME_TARGET/" 2>>"$LOG_FILE" || true

    # ── Шрифты ───────────────────────────────────────────────
    [ -d "$LATEST/fonts/user" ] && {
        mkdir -p "$HOME_TARGET/.local/share/fonts"
        rsync -aAX "$LATEST/fonts/user/" \
            "$HOME_TARGET/.local/share/fonts/" 2>>"$LOG_FILE" || true
    }
    [ -d "$LATEST/fonts/fontconfig" ] && {
        mkdir -p "$HOME_TARGET/.config/fontconfig"
        rsync -aAX "$LATEST/fonts/fontconfig/" \
            "$HOME_TARGET/.config/fontconfig/" 2>>"$LOG_FILE" || true
    }

    # ── Приложения ───────────────────────────────────────────
    [ -d "$LATEST/apps/TelegramDesktop" ] && {
        mkdir -p "$HOME_TARGET/.local/share/TelegramDesktop"
        rsync -aAX "$LATEST/apps/TelegramDesktop/" \
            "$HOME_TARGET/.local/share/TelegramDesktop/" 2>>"$LOG_FILE" || true
    }
    for app_dir in vesktop discord "google-chrome" BraveSoftware \
                   "obsidian-config" "Code" "Code - OSS"; do
        [ -d "$LATEST/apps/$app_dir" ] && {
            mkdir -p "$HOME_TARGET/.config/$app_dir"
            rsync -aAX "$LATEST/apps/$app_dir/" \
                "$HOME_TARGET/.config/$app_dir/" 2>>"$LOG_FILE" || true
        }
    done

    # ── SSH (расшифровываем если нужно) ──────────────────────
    if [ -f "$LATEST/apps/ssh_backup.tar.gz.enc" ]; then
        _log "SSH ключи зашифрованы — расшифровка при первом входе пользователя"
        # Кладём зашифрованный архив и скрипт расшифровки
        cp "$LATEST/apps/ssh_backup.tar.gz.enc" "$HOME_TARGET/" 2>>"$LOG_FILE" || true
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
        cp "$LATEST/apps/gnupg_backup.tar.gz.enc" "$HOME_TARGET/" 2>>"$LOG_FILE" || true
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
    [ -f "$LATEST/sddm/sddm.conf" ] && \
        cp "$LATEST/sddm/sddm.conf" /etc/ 2>>"$LOG_FILE" || true
    [ -d "$LATEST/sddm/sddm.conf.d" ] && {
        mkdir -p /etc/sddm.conf.d
        cp -r "$LATEST/sddm/sddm.conf.d/." /etc/sddm.conf.d/ 2>>"$LOG_FILE" || true
    }
    [ -d "$LATEST/sddm/themes" ] && {
        mkdir -p /usr/share/sddm/themes
        cp -r "$LATEST/sddm/themes/." /usr/share/sddm/themes/ 2>>"$LOG_FILE" || true
        chmod -R 755 /usr/share/sddm/themes/ 2>>"$LOG_FILE" || true   # права для sddm-пользователя
    }

    # ── Возвращаем права пользователю (КРИТИЧНО) ─────────────
    chown -R "$USERNAME:$USERNAME" "$HOME_TARGET"

    umount "$KIRILL_CHROOT" 2>>"$LOG_FILE" || true
    rm -rf "$KIRILL_CHROOT"
    _log "Восстановление из бэкапа завершено"
}

# ══════════════════════════════════════════════════════════════
# ██████████  WIZARD / OOBE  ██████████
# ══════════════════════════════════════════════════════
if [[ "$MODE" == "wizard" ]]; then
    wizard_run || exit 1
    stage_07_install
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

command -v whiptail &>/dev/null || pacman -Sy --noconfirm libnewt 2>/dev/null

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

command -v pv &>/dev/null || pacman -Sy --noconfirm pv 2>/dev/null || \
    _die "pv не найден и не установился.\nsudo pacman -S pv"

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
        umount "/dev/$part" 2>/dev/null || true
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
partprobe "$DST_DISK" 2>/dev/null || true; sleep 2

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

command -v whiptail &>/dev/null || pacman -Sy --noconfirm libnewt 2>/dev/null
preflight_checks
_set_ru_mirrors

whiptail --title "Установка Arch с бэкапом" --msgbox \
"Пакеты будут взяты из бэкапа (pkglist_repo.txt + pkglist_aur.txt),\nа не из хардкодного списка!\n\nKDE, kitty, fastfetch, сессии — всё восстановится\nавтоматически в chroot до первого входа." \
12 72

USERNAME=$(_input "Пользователь" "Имя пользователя:" "kirill") || _die "Отменено."
[[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || _die "Некорректное имя: '$USERNAME'"
HOSTNAME=$(_input "Hostname" "Имя компьютера:" "archbox") || _die "Отменено."

TARGET_DISK=$(_select_target_disk)
validate_disk_path "$TARGET_DISK" || _die "Некорректный диск: $TARGET_DISK"
if [[ "$TARGET_DISK" =~ nvme[0-9]+n[0-9]+$ ]] || [[ "$TARGET_DISK" =~ mmcblk ]]; then
    PART_EFI="${TARGET_DISK}p1"; PART_ROOT="${TARGET_DISK}p2"
else
    PART_EFI="${TARGET_DISK}1"; PART_ROOT="${TARGET_DISK}2"
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
    timedatectl set-ntp true || true

    run_stage "partitioning" _partition_disk "$TARGET_DISK" "$PART_EFI" "$PART_ROOT"

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
    ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
    cat > /mnt/root/install_vars.env << ENVEOF
USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
ROOT_UUID="$ROOT_UUID"
PART_EFI="$PART_EFI"
PART_ROOT="$PART_ROOT"
BACKUP_UUID="$BACKUP_UUID"
BACKUP_SUBPATH="$BACKUP_SUBPATH"
ENVEOF
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    cp "$0" /mnt/root/install_tui.sh
    chmod +x /mnt/root/install_tui.sh

    _step 55 "chroot: настройка системы + восстановление бэкапа..."
    arch-chroot /mnt /bin/bash /root/install_tui.sh --chroot

    _step 100 "Готово!"
    sleep 1

} | whiptail --title "Установка Arch Linux с бэкапом..." \
    --gauge "Инициализация..." 8 74 0

umount -R /mnt 2>>"$LOG_FILE" || true
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

command -v whiptail &>/dev/null || pacman -Sy --noconfirm libnewt 2>/dev/null
preflight_checks
_set_ru_mirrors

whiptail --title "Чистая установка Arch" --msgbox \
"Arch + KDE Plasma + базовые пакеты.\nБез восстановления конфигов.\n\nКонфиги KDE, kitty, fastfetch — дефолтные.\nВосстановить бэкап можно потом через backup_tui.sh." \
12 72

USERNAME=$(_input "Пользователь" "Имя пользователя:" "kirill") || _die "Отменено."
[[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || _die "Некорректное имя: '$USERNAME'"
HOSTNAME=$(_input "Hostname" "Имя компьютера:" "archbox") || _die "Отменено."

TARGET_DISK=$(_select_target_disk)
validate_disk_path "$TARGET_DISK" || _die "Некорректный диск: $TARGET_DISK"
if [[ "$TARGET_DISK" =~ nvme[0-9]+n[0-9]+$ ]] || [[ "$TARGET_DISK" =~ mmcblk ]]; then
    PART_EFI="${TARGET_DISK}p1"; PART_ROOT="${TARGET_DISK}p2"
else
    PART_EFI="${TARGET_DISK}1"; PART_ROOT="${TARGET_DISK}2"
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
    timedatectl set-ntp true || true

    run_stage "partitioning" _partition_disk "$TARGET_DISK" "$PART_EFI" "$PART_ROOT"

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
    ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
    cat > /mnt/root/install_vars.env << ENVEOF
USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
ROOT_UUID="$ROOT_UUID"
PART_EFI="$PART_EFI"
PART_ROOT="$PART_ROOT"
BACKUP_UUID="Пропустить"
BACKUP_SUBPATH=""
ENVEOF
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    cp "$0" /mnt/root/install_tui.sh
    chmod +x /mnt/root/install_tui.sh

    _step 55 "chroot: настройка (без бэкапа)..."
    arch-chroot /mnt /bin/bash /root/install_tui.sh --chroot-fresh

    _step 100 "Готово!"
    sleep 1

} | whiptail --title "Чистая установка..." --gauge "Инициализация..." 8 74 0

umount -R /mnt 2>>"$LOG_FILE" || true
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
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEP_PID=$!
[ -f ~/install_vars.env ] && source ~/install_vars.env || true
USERNAME=$(whoami)
IS_BACKUP_INSTALL=false
[ -f "$HOME/.config/kdeglobals" ] && IS_BACKUP_INSTALL=true  # конфиги уже есть — это установка с бэкапом

whiptail --title "Этап 2 — Настройка" --msgbox \
"Сейчас установятся:\n
  • NVIDIA RTX 3050 драйверы\n  • KDE Plasma 6 + Wayland + SDDM
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

_step 12 "NVIDIA RTX 3050..."
sudo pacman -S --needed --noconfirm \
    nvidia nvidia-utils nvidia-settings \
    lib32-nvidia-utils lib32-opencl-nvidia \
    opencl-nvidia libva-nvidia-driver >>"$LOG_FILE" 2>&1

sudo sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
    /etc/mkinitcpio.conf
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
systemctl --user enable --now pipewire pipewire-pulse wireplumber >>"$LOG_FILE" 2>&1 || true
sudo systemctl enable --now bluetooth >>"$LOG_FILE" 2>&1

_step 34 "kitty + fastfetch + шрифты..."
sudo pacman -S --needed --noconfirm \
    kitty fastfetch \
    noto-fonts noto-fonts-cjk noto-fonts-emoji \
    ttf-liberation ttf-dejavu ttf-jetbrains-mono-nerd \
    >>"$LOG_FILE" 2>&1
sudo systemctl enable sddm >>"$LOG_FILE" 2>&1

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

sudo mount -a 2>>"$LOG_FILE" || true

{
# ── AUR пакеты: из бэкапа ИЛИ хардкод ────────────────────────
_step 40 "AUR пакеты..."
KBR="/mnt/kirill/установочные файлы/linux/kde_backup"
AUR_FROM_BACKUP=false

if [ -d "$KBR" ]; then
    LATEST_BK=$(find "$KBR" -maxdepth 1 -mindepth 1 -type d | sort -r | head -1)
    if [ -f "$LATEST_BK/packages/pkglist_aur.txt" ]; then
        _log "AUR: устанавливаем из бэкапа..."
        paru -S --needed --noconfirm - < "$LATEST_BK/packages/pkglist_aur.txt" \
            >>"$LOG_FILE" 2>&1 || _log "WARN: часть AUR пакетов не установилась"
        AUR_FROM_BACKUP=true
    fi
fi

if ! $AUR_FROM_BACKUP; then
    _log "AUR: бэкап не найден — базовый хардкод"
    paru -S --needed --noconfirm \
        telegram-desktop vesktop \
        visual-studio-code-bin \
        google-chrome ttf-ms-fonts \
        heroic-games-launcher-bin \
        lmstudio-bin claude-desktop-bin \
        2>>"$LOG_FILE" || true
fi

# ── Разработка (только при чистой установке) ──────────────────
if ! $IS_BACKUP_INSTALL; then
    _step 52 "Разработка: Python, Docker, Node..."
    sudo pacman -S --needed --noconfirm \
        python python-pip python-virtualenv pyenv \
        docker docker-compose \
        android-tools android-udev >>"$LOG_FILE" 2>&1
    paru -S --needed --noconfirm nvm 2>>"$LOG_FILE" || true
    curl -fsSL https://bun.sh/install | bash >>"$LOG_FILE" 2>&1 || true
    sudo systemctl enable --now docker >>"$LOG_FILE" 2>&1
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
    sudo systemctl enable --now ollama >>"$LOG_FILE" 2>&1
fi

# ── Оптимизации (всегда) ──────────────────────────────────────
_step 78 "zram: 8ГБ..."
sudo pacman -S --needed --noconfirm zram-generator >>"$LOG_FILE" 2>&1
sudo tee /etc/systemd/zram-generator.conf > /dev/null << 'ZRAM'
[zram0]
zram-size = 8192
compression-algorithm = zstd
ZRAM
sudo systemctl daemon-reload
sudo systemctl start systemd-zram-setup@zram0.service 2>>"$LOG_FILE" || true

_step 82 "IO scheduler + power-profiles..."
sudo tee /etc/udev/rules.d/60-io-scheduler.rules > /dev/null << 'UDEV'
ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
UDEV
sudo pacman -S --needed --noconfirm power-profiles-daemon >>"$LOG_FILE" 2>&1
sudo systemctl enable --now power-profiles-daemon >>"$LOG_FILE" 2>&1
powerprofilesctl set performance 2>>"$LOG_FILE" || true

_step 86 "Snapper..."
sudo pacman -S --needed --noconfirm snapper snap-pac >>"$LOG_FILE" 2>&1
sudo snapper -c root create-config / 2>>"$LOG_FILE" || true
sudo sed -i \
    -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
    -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
    -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
    -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
    -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
    /etc/snapper/configs/root 2>>"$LOG_FILE" || true
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >>"$LOG_FILE" 2>&1

_step 90 "ufw + paccache..."
sudo pacman -S --needed --noconfirm ufw pacman-contrib >>"$LOG_FILE" 2>&1
sudo ufw default deny incoming >>"$LOG_FILE" 2>&1
sudo ufw default allow outgoing >>"$LOG_FILE" 2>&1
sudo systemctl enable --now ufw >>"$LOG_FILE" 2>&1
sudo systemctl enable --now paccache.timer >>"$LOG_FILE" 2>&1

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
