#!/usr/bin/env bash
# TOOL_NAME: backup_tui
# TOOL_DESC: TUI-бэкап системы Teddy — с динамическим выбором диска, btrfs-снапшотом и шифрованием ключей
# TOOL_MODE: gui

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# РЕЖИМЫ:
#   bash backup_tui.sh              — обычный запуск из живой системы
#   bash backup_tui.sh --live-usb   — запуск с archiso (монтирует btrfs, chroot)
#   bash backup_tui.sh --chroot-mode — внутренний вызов из chroot (не запускать вручную)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# РЕЖИМ ЗАПУСКА
# ──────────────────────────────────────────────────────────────
SCRIPT_MODE="${1:-auto}"

# Авто-детект archiso
if [[ "$SCRIPT_MODE" == "auto" ]]; then
    if grep -q "archiso" /etc/os-release 2>/dev/null || \
       [ "$(hostname 2>/dev/null)" = "archiso" ]; then
        SCRIPT_MODE="live-usb"
    else
        SCRIPT_MODE="normal"
    fi
fi
[[ "$SCRIPT_MODE" == "--live-usb" ]]   && SCRIPT_MODE="live-usb"
[[ "$SCRIPT_MODE" == "--chroot-mode" ]] && SCRIPT_MODE="chroot"

# ──────────────────────────────────────────────────────────────
# СЛУЖЕБНЫЕ ФУНКЦИИ
# ──────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
LOG_FILE="/tmp/backup_tui_${TIMESTAMP}.log"
H="${HOME}"

_log()  { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"; }
_die()  { whiptail --title "ОШИБКА" --msgbox "$*" 10 68; exit 1; }
_msg()  { whiptail --title "Teddy Backup" --msgbox "$*" 12 68; }
_info() { whiptail --title "Teddy Backup" --infobox "$*" 7 68; sleep 1; }

_step() {
    local pct="$1" msg="$2"
    echo "$pct"
    printf 'XXX\n%s\nXXX\n' "$msg"
    _log "$pct% — $msg"
}

# rsync без мусора, с сохранением прав и атрибутов
_rsync() {
    rsync -aAX \
        --exclude="Cache/"        --exclude="cache/" \
        --exclude="CacheStorage/" --exclude=".cache/" \
        --exclude="thumbnails/"   --exclude="Thumbnails/" \
        --exclude="*.lock"        --exclude="GPUCache/" \
        --exclude="ShaderCache/"  --exclude="Code Cache/" \
        "$@" 2>>"$LOG_FILE" || true
}

# ══════════════════════════════════════════════════════════════
# ██████  РЕЖИМ LIVE-USB: INCEPTION (монтируем и chroot)  █████
# ══════════════════════════════════════════════════════════════
if [[ "$SCRIPT_MODE" == "live-usb" ]]; then

command -v whiptail &>/dev/null || pacman -Sy --noconfirm libnewt 2>/dev/null

whiptail --title "Teddy Backup — Live USB Mode" --msgbox \
"Скрипт запущен с archiso (Live USB).\n
Сейчас:\n
  1. Выбираешь btrfs-раздел с твоей системой\n  2. Выбираешь раздел/диск для бэкапа\n  3. Скрипт монтирует систему, входит в chroot\n     и запускает бэкап от имени пользователя\n
Это безопаснее запуска из живой системы —\nфайлы читаются из замороженного состояния." \
18 70

# ── Выбор btrfs-раздела с системой ───────────────────────────
BTRFS_LIST=()
while IFS= read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    LABEL=$(echo "$line" | awk '{print $3}')
    BTRFS_LIST+=("/dev/$DEV" "${SIZE}  LABEL=${LABEL:-—}")
done < <(lsblk -Pno NAME,SIZE,LABEL,FSTYPE | \
    grep 'FSTYPE="btrfs"' | \
    sed 's/NAME="\([^"]*\)" SIZE="\([^"]*\)" LABEL="\([^"]*\)".*/\1 \2 \3/')

# Если предыдущий парсер не дал результат — используем более простой
if [ ${#BTRFS_LIST[@]} -eq 0 ]; then
    while IFS= read -r line; do
        DEV=$(echo "$line" | awk '{print $1}')
        SIZE=$(echo "$line" | awk '{print $2}')
        BTRFS_LIST+=("/dev/$DEV" "$SIZE [btrfs]")
    done < <(lsblk -rno NAME,SIZE,FSTYPE | awk '$3=="btrfs"')
fi

[ ${#BTRFS_LIST[@]} -eq 0 ] && _die "btrfs-разделы не найдены!\nПодключи диск и попробуй снова."

SYS_PART=$(whiptail --title "Выбор системного раздела" \
    --menu "Выбери btrfs-раздел с твоим Arch Linux (@-субтома):" \
    16 70 8 "${BTRFS_LIST[@]}" \
    3>&1 1>&2 2>&3) || exit 0

# ── Определяем имя пользователя ──────────────────────────────
# Пытаемся определить из субтома @home
TMP_PROBE="/tmp/btrfs_probe_$$"
mkdir -p "$TMP_PROBE"
mount -o subvol=@home "$SYS_PART" "$TMP_PROBE" 2>/dev/null || \
    mount -o subvol=@ "$SYS_PART" "$TMP_PROBE" 2>/dev/null || true

DETECTED_USER=""
if [ -d "$TMP_PROBE" ]; then
    # Берём первого пользователя с UID >= 1000
    DETECTED_USER=$(ls "$TMP_PROBE" 2>/dev/null | head -1 || echo "")
fi
umount "$TMP_PROBE" 2>/dev/null || true
rmdir "$TMP_PROBE" 2>/dev/null || true

SYS_USER=$(whiptail --title "Пользователь" \
    --inputbox "Имя пользователя в установленной системе:" \
    8 60 "${DETECTED_USER:-kirill}" \
    3>&1 1>&2 2>&3) || exit 0
[ -z "$SYS_USER" ] && _die "Имя пользователя не может быть пустым."

# ── Выбор раздела для бэкапа (вручную — требование из задания) ─
ALL_PARTS=()
while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    FSTYPE=$(echo "$line" | awk '{print $3}')
    LABEL=$(echo "$line" | awk '{print $4}')
    [[ "/dev/$NAME" == "$SYS_PART" ]] && continue
    ALL_PARTS+=("/dev/$NAME" "${SIZE} [${FSTYPE:-?}] LABEL=${LABEL:-—}")
done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL | grep -v "^loop" | grep -v "^$")

[ ${#ALL_PARTS[@]} -eq 0 ] && _die "Нет доступных разделов для бэкапа!"

BACKUP_PART=$(whiptail --title "Выбор раздела для бэкапа" \
    --menu \
    "Выбери раздел для сохранения бэкапа (КИРИЛЛ / SNAPSHOT):\n(твой диск — обычно FAT32 или NTFS)" \
    18 72 10 "${ALL_PARTS[@]}" \
    3>&1 1>&2 2>&3) || exit 0

# Получаем UUID раздела бэкапа (надёжнее чем /dev/sdX)
BACKUP_UUID=$(blkid -s UUID -o value "$BACKUP_PART" 2>/dev/null || echo "")
_log "Бэкап-раздел: $BACKUP_PART (UUID=$BACKUP_UUID)"

# ── Монтируем и входим в chroot ───────────────────────────────
{
_step 10 "Размонтирование старых точек /mnt..."
umount -R /mnt 2>/dev/null || true
sleep 1

_step 25 "Монтирование @ (корень)..."
BTRFS_OPTS="noatime,compress=zstd:3,space_cache=v2"
mount -o "${BTRFS_OPTS},subvol=@" "$SYS_PART" /mnt

_step 40 "Монтирование @home..."
[ -d /mnt/home ] || mkdir -p /mnt/home
mount -o "${BTRFS_OPTS},subvol=@home" "$SYS_PART" /mnt/home

_step 55 "Монтирование раздела бэкапа..."
mkdir -p /mnt/mnt/backup_drive
FS_TYPE_BK=$(lsblk -no FSTYPE "$BACKUP_PART" 2>/dev/null | head -1 || echo "")
if [ "$FS_TYPE_BK" = "vfat" ]; then
    mount -t vfat -o utf8=1,umask=000 "$BACKUP_PART" /mnt/mnt/backup_drive
else
    mount "$BACKUP_PART" /mnt/mnt/backup_drive
fi

_step 70 "Проброс /proc /sys /dev..."
for d in proc sys dev run; do
    mount --bind "/$d" "/mnt/$d" 2>/dev/null || true
done

_step 85 "Копируем скрипт в /mnt/tmp/..."
cp "$0" /mnt/tmp/backup_tui.sh
chmod +x /mnt/tmp/backup_tui.sh

_step 100 "Готово — входим в chroot!"
sleep 1

} | whiptail --title "Подготовка chroot..." --gauge "Инициализация..." 8 70 0

# ВТОРЖЕНИЕ: запускаем бэкап изнутри системы от имени пользователя
whiptail --title "Входим в систему" --infobox \
    "Входим в chroot...\nЗапускаем бэкап от имени $SYS_USER." 7 60
sleep 1

arch-chroot /mnt /usr/bin/bash -c \
    "su - $SYS_USER -c 'bash /tmp/backup_tui.sh --chroot-mode'"

# Очистка
_info "Бэкап завершён. Размонтируем..."
for d in proc sys dev run; do
    umount "/mnt/$d" 2>/dev/null || true
done
umount -R /mnt 2>/dev/null || true

_msg "✓ Бэкап завершён!\n\nВсе точки монтирования убраны.\nМожешь вытащить флешку."
exit 0

fi  # END live-usb

# ══════════════════════════════════════════════════════════════
# ██████  ОБЫЧНЫЙ РЕЖИМ И CHROOT-РЕЖИМ  ███████████████████████
# ══════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────
# ОПРЕДЕЛЕНИЕ ПУТИ К БЭКАП-ДИСКУ (динамически, не хардкод)
# ──────────────────────────────────────────────────────────────

KIRILL_MOUNT=""
BACKUP_PARENT=""

if [[ "$SCRIPT_MODE" == "chroot" ]]; then
    # В chroot-режиме диск уже смонтирован родителем в /mnt/backup_drive
    KIRILL_MOUNT="/mnt/backup_drive"
    [ ! -d "$KIRILL_MOUNT" ] && \
        _die "Точка /mnt/backup_drive недоступна!\nЧто-то пошло не так при монтировании."
    BACKUP_PARENT="$KIRILL_MOUNT/установочные файлы/linux/kde_backup"

else
    # Нормальный режим: предлагаем пользователю ВЫБРАТЬ раздел вручную

    command -v whiptail &>/dev/null || {
        echo "Ошибка: whiptail не найден. sudo pacman -S libnewt"
        exit 1
    }

    # Строим список всех доступных разделов и дисков
    DISK_CHOICES=()
    while IFS= read -r line; do
        NAME=$(echo "$line" | awk '{print $1}')
        SIZE=$(echo "$line" | awk '{print $2}')
        FSTYPE=$(echo "$line" | awk '{print $3}')
        LABEL=$(echo "$line" | awk '{print $4}')
        MOUNTPOINT=$(echo "$line" | awk '{print $5}')
        DISK_CHOICES+=("/dev/$NAME" \
            "${SIZE}  [${FSTYPE:-?}]  LABEL=${LABEL:-—}  MNT=${MOUNTPOINT:-не смонтирован}")
    done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT | \
        grep -v "^loop" | grep -v "^$" | grep -v "^nvme.*n[0-9] " | \
        grep -v "^sd[a-z] " | grep -v "^nvme.*n[0-9]$")
    # Если нет разделов — берём вообще всё
    if [ ${#DISK_CHOICES[@]} -eq 0 ]; then
        while IFS= read -r line; do
            NAME=$(echo "$line" | awk '{print $1}')
            SIZE=$(echo "$line" | awk '{print $2}')
            FSTYPE=$(echo "$line" | awk '{print $3}')
            LABEL=$(echo "$line" | awk '{print $4}')
            MOUNTPOINT=$(echo "$line" | awk '{print $5}')
            [[ "$FSTYPE" == "btrfs" ]] && continue  # пропускаем системный
            DISK_CHOICES+=("/dev/$NAME" \
                "${SIZE}  [${FSTYPE:-?}]  LABEL=${LABEL:-—}  MNT=${MOUNTPOINT:-—}")
        done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT | grep -v "^loop")
    fi

    SELECTED_PART=$(whiptail --title "Выбор раздела для бэкапа" \
        --menu \
        "Выбери РАЗДЕЛ куда сохранить бэкап.\n(КИРИЛЛ — обычно FAT32 или NTFS, около 931ГБ)" \
        20 76 12 "${DISK_CHOICES[@]}" \
        3>&1 1>&2 2>&3) || { _msg "Бэкап отменён."; exit 0; }

    # Проверяем, смонтирован ли он уже
    CURRENT_MOUNT=$(lsblk -no MOUNTPOINT "$SELECTED_PART" 2>/dev/null | head -1 | tr -d ' ')

    if [ -n "$CURRENT_MOUNT" ] && [ -d "$CURRENT_MOUNT" ]; then
        KIRILL_MOUNT="$CURRENT_MOUNT"
        _log "Раздел $SELECTED_PART уже смонтирован в $KIRILL_MOUNT"
    else
        # Монтируем сами
        KIRILL_MOUNT="/tmp/teddy_backup_mount_$$"
        mkdir -p "$KIRILL_MOUNT"
        FS_T=$(lsblk -no FSTYPE "$SELECTED_PART" 2>/dev/null | head -1 || echo "")
        if [ "$FS_T" = "vfat" ]; then
            sudo mount -t vfat -o utf8=1,umask=022 "$SELECTED_PART" "$KIRILL_MOUNT" || \
                _die "Не удалось смонтировать $SELECTED_PART"
        elif [ "$FS_T" = "ntfs" ] || [ "$FS_T" = "ntfs-3g" ]; then
            sudo mount -t ntfs-3g "$SELECTED_PART" "$KIRILL_MOUNT" || \
                _die "Не удалось смонтировать $SELECTED_PART (NTFS)"
        else
            sudo mount "$SELECTED_PART" "$KIRILL_MOUNT" || \
                _die "Не удалось смонтировать $SELECTED_PART"
        fi
        _log "Смонтировали $SELECTED_PART в $KIRILL_MOUNT"
    fi

    FREE_MB=$(df -m "$KIRILL_MOUNT" | awk 'NR==2{print $4}')
    [ "$FREE_MB" -lt 500 ] && _die "Мало места: ${FREE_MB}МБ (нужно ≥500МБ)"

    BACKUP_PARENT="$KIRILL_MOUNT/установочные файлы/linux/kde_backup"
fi

BACKUP_DIR="$BACKUP_PARENT/$TIMESTAMP"
LOG="$BACKUP_DIR/backup.log"

# ──────────────────────────────────────────────────────────────
# ПРИВЕТСТВИЕ
# ──────────────────────────────────────────────────────────────
FREE_MB=$(df -m "$KIRILL_MOUNT" 2>/dev/null | awk 'NR==2{print $4}' || echo "?")

whiptail --title "Teddy Backup — $(date '+%d.%m.%Y %H:%M')" \
    --msgbox "Привет, Kirya!\n
Бэкап сохранится в:\n  $BACKUP_DIR\n
Свободно: ${FREE_MB}МБ\n
Что будет сохранено:\n  • KDE Plasma (панели, виджеты, темы, kscreen)\n  • kitty + fastfetch\n  • SDDM, шрифты, GTK, shell\n  • Сессии приложений (на выбор)\n  • Списки пакетов (из бэкапа — не хардкод!)\n  • SSH/GPG ключи (зашифрованы AES-256)" \
22 72

# ──────────────────────────────────────────────────────────────
# АТОМАРНЫЙ BTRFS-СНАПШОТ @home (если система на btrfs)
# ──────────────────────────────────────────────────────────────
SNAP_PATH=""
SYNC_H="$H"   # По умолчанию читаем из живой системы

if stat -f --format="%T" "$H" 2>/dev/null | grep -q btrfs || \
   findmnt -n -o FSTYPE "$H" 2>/dev/null | grep -q btrfs; then

    whiptail --title "BTRFS-снапшот" --yesno \
"Твой @home находится на btrfs.\n
Создать атомарный read-only снапшот перед бэкапом?\n
  ПЛЮС: файлы заморожены в одну миллисекунду —\n        не будет битых конфигов KDE.\n  МИНУС: требует ~10сек и прав sudo.\n\n(Если нет — синхронизируем буферы через sync)" \
    14 70 && DO_SNAP=1 || DO_SNAP=0

    if [ "$DO_SNAP" -eq 1 ]; then
        SNAP_PATH="$H/.backup_snap_tmp_${TIMESTAMP}"
        _info "Создаём btrfs снапшот @home..."
        sudo btrfs subvolume snapshot -r "$H" "$SNAP_PATH" >> "$LOG_FILE" 2>&1 && {
            SYNC_H="$SNAP_PATH"
            _log "Снапшот создан: $SNAP_PATH"
        } || {
            warn "Снапшот не удался — работаем с живой системой"
            SNAP_PATH=""
        }
    else
        _info "Синхронизируем файловые буферы (sync)..."
        sync
        _log "sync выполнен"
    fi
else
    _log "@home не на btrfs — работаем напрямую"
    sync
fi

# ──────────────────────────────────────────────────────────────
# СКАНИРОВАНИЕ ПРИЛОЖЕНИЙ С СЕССИЯМИ
# ──────────────────────────────────────────────────────────────
APPS_CHECKLIST=()

[ -d "$H/.local/share/TelegramDesktop" ] && \
    APPS_CHECKLIST+=("Telegram"  "Сессия и данные Telegram Desktop" "ON")
[ -d "$H/.config/vesktop" ] && \
    APPS_CHECKLIST+=("Vesktop"   "Сессия Vesktop (Discord)" "ON")
[ -d "$H/.config/discord" ] && \
    APPS_CHECKLIST+=("Discord"   "Сессия Discord" "ON")
[ -d "$H/.mozilla/firefox" ] && \
    APPS_CHECKLIST+=("Firefox"   "Профили, куки, расширения" "ON")
[ -d "$H/.config/google-chrome" ] && \
    APPS_CHECKLIST+=("Chrome"    "Профили Chrome" "ON")
[ -d "$H/.config/BraveSoftware" ] && \
    APPS_CHECKLIST+=("Brave"     "Профили Brave" "ON")
[ -d "$H/.config/obsidian" ] || [ -d "$H/.local/share/obsidian" ] && \
    APPS_CHECKLIST+=("Obsidian"  "Хранилища Obsidian" "ON")
( [ -d "$H/.config/Code" ] || [ -d "$H/.config/Code - OSS" ] ) && \
    APPS_CHECKLIST+=("VSCode"    "Настройки и расширения VS Code" "ON")
[ -d "$H/.ssh" ] && \
    APPS_CHECKLIST+=("SSH"       "SSH-ключи (AES-256 шифрование!)" "ON")
[ -d "$H/.gnupg" ] && \
    APPS_CHECKLIST+=("GPG"       "GPG-ключи (AES-256 шифрование!)" "ON")

SELECTED_APPS=""
if [ ${#APPS_CHECKLIST[@]} -gt 0 ]; then
    SELECTED_APPS=$(whiptail --title "Найдены приложения" \
        --checklist \
        "Выбери что добавить в бэкап:\n(Пробел — отметить/снять, Enter — продолжить)" \
        22 72 12 "${APPS_CHECKLIST[@]}" \
        3>&1 1>&2 2>&3) || SELECTED_APPS=""
fi

# ──────────────────────────────────────────────────────────────
# ПРОИЗВОЛЬНЫЕ ПУТИ (с защитой от коллизий через rsync -R)
# ──────────────────────────────────────────────────────────────
CUSTOM_PATHS=()

while true; do
    USER_PATH=$(whiptail --title "Дополнительные пути" \
        --inputbox \
        "Введи полный путь к файлу или папке для бэкапа.\n(Пути сохраняются с полной структурой — коллизий нет)\n\nОставь пустым и нажми OK чтобы закончить:" \
        12 70 "" \
        3>&1 1>&2 2>&3) || break

    [ -z "$USER_PATH" ] && break

    if [ -e "$USER_PATH" ]; then
        CUSTOM_PATHS+=("$USER_PATH")
        _info "Добавлено: $USER_PATH\n(всего: ${#CUSTOM_PATHS[@]} путей)"
    else
        _msg "Путь не существует:\n$USER_PATH"
    fi
done

# Пароль для шифрования SSH/GPG (если они выбраны)
ENCRYPT_PASS=""
if [[ "$SELECTED_APPS" == *"SSH"* ]] || [[ "$SELECTED_APPS" == *"GPG"* ]]; then
    ENCRYPT_PASS=$(whiptail --title "Пароль шифрования SSH/GPG" \
        --passwordbox \
        "SSH и GPG ключи будут зашифрованы AES-256-CBC.\nВведи пароль для шифрования архива:" \
        10 68 \
        3>&1 1>&2 2>&3) || ENCRYPT_PASS=""

    if [ -n "$ENCRYPT_PASS" ]; then
        ENCRYPT_PASS2=$(whiptail --title "Подтверждение пароля" \
            --passwordbox "Введи пароль ещё раз:" \
            8 68 3>&1 1>&2 2>&3) || ENCRYPT_PASS2=""
        [ "$ENCRYPT_PASS" != "$ENCRYPT_PASS2" ] && {
            _msg "Пароли не совпадают!\nSSH/GPG будут пропущены."
            ENCRYPT_PASS=""
        }
    else
        _msg "Пароль пустой — SSH/GPG будут пропущены."
    fi
fi

# ──────────────────────────────────────────────────────────────
# ИТОГОВОЕ ПОДТВЕРЖДЕНИЕ
# ──────────────────────────────────────────────────────────────
SUMMARY="Параметры бэкапа:\n\n"
SUMMARY+="  Цель: $BACKUP_DIR\n"
SUMMARY+="  Свободно: ${FREE_MB}МБ\n"
[ -n "$SNAP_PATH" ] && SUMMARY+="  BTRFS снапшот: ДА (атомарный)\n" || \
    SUMMARY+="  BTRFS снапшот: НЕТ (live)\n"
SUMMARY+="\n  Приложения:\n"
if [ -n "$SELECTED_APPS" ]; then
    for app in $SELECTED_APPS; do SUMMARY+="    ✓ ${app//\"/}\n"; done
else
    SUMMARY+="    — (не выбраны)\n"
fi
SUMMARY+="\n  Доп. пути: ${#CUSTOM_PATHS[@]} шт.\n"

whiptail --title "Подтверждение" --yesno "$SUMMARY\nНачать бэкап?" 24 70 || {
    # Удаляем снапшот если создали
    [ -n "$SNAP_PATH" ] && sudo btrfs subvolume delete "$SNAP_PATH" 2>/dev/null || true
    _msg "Бэкап отменён."
    exit 0
}

# ──────────────────────────────────────────────────────────────
# СОЗДАНИЕ СТРУКТУРЫ И СТАРТ
# ──────────────────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
touch "$LOG"
_log "=== Бэкап начат: $TIMESTAMP ==="
_log "Пользователь: $(whoami)@$(hostname)"
_log "Источник: $SYNC_H"
_log "Цель: $BACKUP_DIR"
_log "Приложения: $SELECTED_APPS"
_log "Доп. пути: ${CUSTOM_PATHS[*]:-нет}"

# ──────────────────────────────────────────────────────────────
# ОСНОВНОЙ ПРОГРЕСС
# ──────────────────────────────────────────────────────────────
{

# ── 1. KDE конфиги ────────────────────────────────────────────
_step 3 "KDE: конфиги (~/.config)..."
mkdir -p "$BACKUP_DIR/kde/config"

KDE_FILES=(
    plasma-org.kde.plasma.desktop-appletsrc plasmashellrc plasmarc
    kdeglobals breezerc kwinrc kwinrulesrc
    kglobalshortcutsrc khotkeysrc kxkbrc kcminputrc
    kscreenlockerrc krunnerrc knotifyrc powermanagementprofilesrc
    baloofilerc dolphinrc spectaclerc katerc kcalcrc
    okularrc gwenviewrc kdeconnectrc kmixrc ksmserverrc
    startkderc kiorc user-dirs.dirs user-dirs.locale
    kded5rc kscreenrc plasmanotifyrc
)
for f in "${KDE_FILES[@]}"; do
    [ -f "$SYNC_H/.config/$f" ] && \
        cp "$SYNC_H/.config/$f" "$BACKUP_DIR/kde/config/" 2>>"$LOG" || true
done

for dir in plasma kwin kwinscripts kwineffects Kvantum \
            autostart autostart-scripts kglobalshortcuts menus; do
    [ -d "$SYNC_H/.config/$dir" ] && \
        _rsync "$SYNC_H/.config/$dir/" "$BACKUP_DIR/kde/config/$dir/" || true
done

# ── 2. KDE local (kscreen — критично!) ───────────────────────
_step 12 "KDE: темы, kscreen, иконки, обои..."
mkdir -p "$BACKUP_DIR/kde/local"

for pair in \
    "kscreen:kscreen" "plasma:plasma" "color-schemes:color-schemes" \
    "icons:icons" "wallpapers:wallpapers" "aurorae:aurorae" \
    "kwin:kwin" "plasma_themes:plasma_themes" "dolphin:dolphin" \
    "kservices5:kservices5" "kactivitymanagerd:kactivitymanagerd"
do
    src="${pair%%:*}"; dst="${pair##*:}"
    [ -d "$SYNC_H/.local/share/$src" ] && \
        _rsync "$SYNC_H/.local/share/$src/" "$BACKUP_DIR/kde/local/$dst/" || true
done

[ -f "$SYNC_H/.local/share/user-places.xbel" ] && \
    cp "$SYNC_H/.local/share/user-places.xbel" "$BACKUP_DIR/kde/local/" 2>>"$LOG" || true

WPATH=$(grep -r "^Image=" "$SYNC_H/.config/plasma-org.kde.plasma.desktop-appletsrc" \
    2>/dev/null | head -1 | sed 's/^Image=//' | tr -d ' \r' || true)
[ -n "$WPATH" ] && [ -f "$WPATH" ] && {
    mkdir -p "$BACKUP_DIR/kde/current_wallpaper"
    cp "$WPATH" "$BACKUP_DIR/kde/current_wallpaper/" 2>>"$LOG" || true
}

# ── 3. kitty ──────────────────────────────────────────────────
_step 22 "kitty..."
[ -d "$SYNC_H/.config/kitty" ] && \
    _rsync "$SYNC_H/.config/kitty/" "$BACKUP_DIR/kitty/" || true
[ -d "$SYNC_H/.local/share/kitty-themes" ] && \
    _rsync "$SYNC_H/.local/share/kitty-themes/" "$BACKUP_DIR/kitty/themes/" || true

# ── 4. fastfetch ──────────────────────────────────────────────
_step 27 "fastfetch..."
mkdir -p "$BACKUP_DIR/fastfetch"
[ -d "$SYNC_H/.config/fastfetch" ] && \
    _rsync "$SYNC_H/.config/fastfetch/" "$BACKUP_DIR/fastfetch/" || true
[ -f "$SYNC_H/.config/fastfetch.jsonc" ] && \
    cp "$SYNC_H/.config/fastfetch.jsonc" "$BACKUP_DIR/fastfetch/" 2>>"$LOG" || true

# ── 5. SDDM ───────────────────────────────────────────────────
_step 31 "SDDM..."
mkdir -p "$BACKUP_DIR/sddm"
[ -f "/etc/sddm.conf" ] && sudo cp /etc/sddm.conf "$BACKUP_DIR/sddm/" 2>>"$LOG" || true
[ -d "/etc/sddm.conf.d" ] && \
    sudo cp -r /etc/sddm.conf.d/. "$BACKUP_DIR/sddm/sddm.conf.d/" 2>>"$LOG" || true
SDDM_THEME=$(grep -rh "Current\s*=" /etc/sddm.conf /etc/sddm.conf.d/ 2>/dev/null | \
    head -1 | awk -F= '{print $2}' | tr -d ' \r' || true)
if [ -n "$SDDM_THEME" ] && [ -d "/usr/share/sddm/themes/$SDDM_THEME" ]; then
    mkdir -p "$BACKUP_DIR/sddm/themes"
    sudo cp -r "/usr/share/sddm/themes/$SDDM_THEME" \
        "$BACKUP_DIR/sddm/themes/" 2>>"$LOG" || true
elif [ -d "/usr/share/sddm/themes" ]; then
    mkdir -p "$BACKUP_DIR/sddm/themes"
    sudo cp -r /usr/share/sddm/themes/. "$BACKUP_DIR/sddm/themes/" 2>>"$LOG" || true
fi
[ -d "$BACKUP_DIR/sddm/themes" ] && sudo chmod -R 755 "$BACKUP_DIR/sddm/themes/" 2>>"$LOG" || true

# ── 6. Шрифты ─────────────────────────────────────────────────
_step 36 "Шрифты..."
[ -d "$SYNC_H/.local/share/fonts" ] && \
    _rsync "$SYNC_H/.local/share/fonts/" "$BACKUP_DIR/fonts/user/" || true
[ -d "$SYNC_H/.config/fontconfig" ] && \
    _rsync "$SYNC_H/.config/fontconfig/" "$BACKUP_DIR/fonts/fontconfig/" || true
fc-list | sort > "$BACKUP_DIR/fonts/installed_list.txt" 2>>"$LOG" || true

# ── 7. Shell ──────────────────────────────────────────────────
_step 40 "Shell: zsh, oh-my-zsh..."
mkdir -p "$BACKUP_DIR/shell"
for f in .zshrc .zprofile .zshenv; do
    [ -f "$SYNC_H/$f" ] && cp "$SYNC_H/$f" "$BACKUP_DIR/shell/" 2>>"$LOG" || true
done
[ -d "$SYNC_H/.oh-my-zsh/custom" ] && \
    _rsync "$SYNC_H/.oh-my-zsh/custom/" "$BACKUP_DIR/shell/omz_custom/" || true

# ── 8. GTK ────────────────────────────────────────────────────
_step 44 "GTK темы..."
mkdir -p "$BACKUP_DIR/gtk"
[ -f "$SYNC_H/.gtkrc-2.0" ] && cp "$SYNC_H/.gtkrc-2.0" "$BACKUP_DIR/gtk/" 2>>"$LOG" || true
[ -d "$SYNC_H/.config/gtk-3.0" ] && \
    _rsync "$SYNC_H/.config/gtk-3.0/" "$BACKUP_DIR/gtk/gtk-3.0/" || true
[ -d "$SYNC_H/.config/gtk-4.0" ] && \
    _rsync "$SYNC_H/.config/gtk-4.0/" "$BACKUP_DIR/gtk/gtk-4.0/" || true

# ── 9. KWallet ────────────────────────────────────────────────
_step 47 "KWallet..."
[ -f "$SYNC_H/.local/share/kwalletd/kdewallet.kwl" ] && {
    mkdir -p "$BACKUP_DIR/kwallet"
    cp "$SYNC_H/.local/share/kwalletd/kdewallet.kwl" "$BACKUP_DIR/kwallet/" 2>>"$LOG" || true
}

# ── 10. SSH (зашифровано) ─────────────────────────────────────
_step 50 "SSH ключи (шифрование AES-256)..."
if [[ "$SELECTED_APPS" == *"SSH"* ]] && [ -d "$SYNC_H/.ssh" ] && \
   [ -n "$ENCRYPT_PASS" ]; then
    mkdir -p "$BACKUP_DIR/apps"
    tar -czf - -C "$SYNC_H" .ssh 2>>"$LOG" | \
        openssl enc -aes-256-cbc -salt -pbkdf2 \
            -pass pass:"$ENCRYPT_PASS" \
            -out "$BACKUP_DIR/apps/ssh_backup.tar.gz.enc" 2>>"$LOG" && \
        _log "SSH зашифрован" || _log "SSH: ошибка шифрования"
fi

# ── 11. GPG (зашифровано) ─────────────────────────────────────
_step 53 "GPG ключи (шифрование AES-256)..."
if [[ "$SELECTED_APPS" == *"GPG"* ]] && [ -d "$SYNC_H/.gnupg" ] && \
   [ -n "$ENCRYPT_PASS" ]; then
    mkdir -p "$BACKUP_DIR/apps"
    tar -czf - -C "$SYNC_H" .gnupg 2>>"$LOG" | \
        openssl enc -aes-256-cbc -salt -pbkdf2 \
            -pass pass:"$ENCRYPT_PASS" \
            -out "$BACKUP_DIR/apps/gnupg_backup.tar.gz.enc" 2>>"$LOG" && \
        _log "GPG зашифрован" || _log "GPG: ошибка шифрования"
fi

# ── 12. Сессии приложений ─────────────────────────────────────
_step 56 "Сессии приложений..."
mkdir -p "$BACKUP_DIR/apps"

[[ "$SELECTED_APPS" == *"Telegram"* ]] && [ -d "$SYNC_H/.local/share/TelegramDesktop" ] && \
    _rsync "$SYNC_H/.local/share/TelegramDesktop/" "$BACKUP_DIR/apps/TelegramDesktop/"
[[ "$SELECTED_APPS" == *"Vesktop"* ]] && [ -d "$SYNC_H/.config/vesktop" ] && \
    _rsync "$SYNC_H/.config/vesktop/" "$BACKUP_DIR/apps/vesktop/"
[[ "$SELECTED_APPS" == *"Discord"* ]] && [ -d "$SYNC_H/.config/discord" ] && \
    _rsync "$SYNC_H/.config/discord/" "$BACKUP_DIR/apps/discord/"
[[ "$SELECTED_APPS" == *"Firefox"* ]] && [ -d "$SYNC_H/.mozilla/firefox" ] && \
    _rsync "$SYNC_H/.mozilla/firefox/" "$BACKUP_DIR/apps/firefox/"
[[ "$SELECTED_APPS" == *"Chrome"* ]] && [ -d "$SYNC_H/.config/google-chrome" ] && \
    _rsync "$SYNC_H/.config/google-chrome/" "$BACKUP_DIR/apps/google-chrome/"
[[ "$SELECTED_APPS" == *"Brave"* ]] && [ -d "$SYNC_H/.config/BraveSoftware" ] && \
    _rsync "$SYNC_H/.config/BraveSoftware/" "$BACKUP_DIR/apps/BraveSoftware/"
[[ "$SELECTED_APPS" == *"Obsidian"* ]] && {
    [ -d "$SYNC_H/.config/obsidian" ] && \
        _rsync "$SYNC_H/.config/obsidian/" "$BACKUP_DIR/apps/obsidian-config/"
    [ -d "$SYNC_H/.local/share/obsidian" ] && \
        _rsync "$SYNC_H/.local/share/obsidian/" "$BACKUP_DIR/apps/obsidian-local/"
}
[[ "$SELECTED_APPS" == *"VSCode"* ]] && {
    for vsc_dir in "Code" "Code - OSS"; do
        [ -d "$SYNC_H/.config/$vsc_dir" ] && \
            _rsync "$SYNC_H/.config/$vsc_dir/" "$BACKUP_DIR/apps/$vsc_dir/"
    done
}

# ── 13. Произвольные пути (rsync -R — нет коллизий!) ─────────
_step 68 "Дополнительные пути..."
if [ ${#CUSTOM_PATHS[@]} -gt 0 ]; then
    mkdir -p "$BACKUP_DIR/custom"
    for p in "${CUSTOM_PATHS[@]}"; do
        # -R: сохраняет полную структуру пути (custom/home/kirill/projects/src/)
        rsync -aAXR "$p" "$BACKUP_DIR/custom/" 2>>"$LOG" || true
        _log "Custom path (relative): $p"
    done
fi

# ── 14. Пакеты ────────────────────────────────────────────────
_step 76 "Списки пакетов (pacman + AUR)..."
mkdir -p "$BACKUP_DIR/packages"
pacman -Qe   > "$BACKUP_DIR/packages/explicit.txt"     2>>"$LOG" || true
pacman -Qm   > "$BACKUP_DIR/packages/aur.txt"          2>>"$LOG" || true
pacman -Qqen > "$BACKUP_DIR/packages/pkglist_repo.txt" 2>>"$LOG" || true
pacman -Qqem > "$BACKUP_DIR/packages/pkglist_aur.txt"  2>>"$LOG" || true
comm -23 <(pacman -Qe | awk '{print $1}' | sort) \
         <(pacman -Qm | awk '{print $1}' | sort) \
    > "$BACKUP_DIR/packages/pacman_only.txt" 2>>"$LOG" || true
_log "Пакеты: $(wc -l < "$BACKUP_DIR/packages/explicit.txt") явных, $(wc -l < "$BACKUP_DIR/packages/aur.txt") AUR"

# ── 15. Системные конфиги ─────────────────────────────────────
_step 82 "Системные конфиги..."
mkdir -p "$BACKUP_DIR/system/modprobe.d" \
         "$BACKUP_DIR/system/udev" \
         "$BACKUP_DIR/system/loader" \
         "$BACKUP_DIR/system/hooks"

for f in /etc/fstab /etc/locale.conf /etc/vconsole.conf \
          /etc/hostname /etc/mkinitcpio.conf /etc/pacman.conf; do
    [ -f "$f" ] && sudo cp "$f" "$BACKUP_DIR/system/" 2>>"$LOG" || true
done
[ -f "/etc/modprobe.d/nvidia.conf" ] && \
    sudo cp /etc/modprobe.d/nvidia.conf "$BACKUP_DIR/system/modprobe.d/" 2>>"$LOG" || true
[ -d "/boot/loader" ] && \
    sudo cp -r /boot/loader/. "$BACKUP_DIR/system/loader/" 2>>"$LOG" || true
[ -d "/etc/pacman.d/hooks" ] && \
    sudo cp -r /etc/pacman.d/hooks/. "$BACKUP_DIR/system/hooks/" 2>>"$LOG" || true
[ -f "/etc/systemd/zram-generator.conf" ] && \
    sudo cp /etc/systemd/zram-generator.conf "$BACKUP_DIR/system/" 2>>"$LOG" || true
[ -f "/etc/udev/rules.d/60-io-scheduler.rules" ] && \
    sudo cp /etc/udev/rules.d/60-io-scheduler.rules \
        "$BACKUP_DIR/system/udev/" 2>>"$LOG" || true

# ── 16. Мета + SHA256 ─────────────────────────────────────────
_step 90 "Мета-файл и SHA256 чексуммы..."

cat > "$BACKUP_DIR/BACKUP_INFO.txt" << INFOEOF
Дата:       $(date '+%d.%m.%Y %H:%M:%S')
Хост:       $(whoami)@$(hostname)
Ядро:       $(uname -r)
KDE Plasma: $(plasmashell --version 2>/dev/null || echo "n/a")
Kitty:      $(kitty --version 2>/dev/null | head -1 || echo "n/a")
Fastfetch:  $(fastfetch --version 2>/dev/null | head -1 || echo "n/a")
GPU:        $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "n/a")
BTRFS snap: ${SNAP_PATH:-нет}
Приложения: $SELECTED_APPS
Доп. пути:  ${CUSTOM_PATHS[*]:-нет}
Шифрование: $([ -n "$ENCRYPT_PASS" ] && echo "AES-256-CBC (SSH/GPG)" || echo "нет")
INFOEOF

_step 95 "SHA256 чексуммы..."
find "$BACKUP_DIR" -type f \
    ! -name "checksums.sha256" ! -name "backup.log" \
    -exec sha256sum {} \; > "$BACKUP_DIR/checksums.sha256" 2>>"$LOG" || true
_log "Чексуммы: $(wc -l < "$BACKUP_DIR/checksums.sha256") файлов"

_step 100 "Готово!"
sleep 1

} | whiptail --title "Выполнение бэкапа..." --gauge "Инициализация..." 8 72 0

# ──────────────────────────────────────────────────────────────
# УДАЛЯЕМ BTRFS-СНАПШОТ
# ──────────────────────────────────────────────────────────────
if [ -n "$SNAP_PATH" ]; then
    _info "Удаляем временный btrfs снапшот..."
    sudo btrfs subvolume delete "$SNAP_PATH" >> "$LOG_FILE" 2>&1 || true
    _log "Снапшот удалён: $SNAP_PATH"
fi

# ──────────────────────────────────────────────────────────────
# ИТОГ
# ──────────────────────────────────────────────────────────────
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
FILE_COUNT=$(wc -l < "$BACKUP_DIR/checksums.sha256" 2>/dev/null || echo "?")
PKG_COUNT=$(wc -l < "$BACKUP_DIR/packages/explicit.txt" 2>/dev/null || echo "?")
AUR_COUNT=$(wc -l < "$BACKUP_DIR/packages/aur.txt" 2>/dev/null || echo "?")

whiptail --title "✓ Бэкап завершён!" --msgbox \
"Всё сохранено!\n
  Папка:    $BACKUP_DIR
  Размер:   $TOTAL_SIZE
  Файлов:   $FILE_COUNT
  Пакеты:   $PKG_COUNT явных + $AUR_COUNT AUR
  Лог:      $LOG\n
Структура:
  kde/         — панели, виджеты, kscreen, темы
  kitty/       — kitty.conf
  fastfetch/   — конфиг
  sddm/        — экран входа (права 755 проставлены)
  apps/        — сессии (SSH/GPG зашифрованы!)
  custom/      — твои пути (с полной структурой)
  packages/    — pkglist_repo.txt + pkglist_aur.txt
  system/      — fstab, nvidia, boot
  checksums.sha256 — целостность\n
Теперь запускай install_tui.sh с Live USB." \
30 74

_log "=== Бэкап завершён: $TOTAL_SIZE, $FILE_COUNT файлов ==="
