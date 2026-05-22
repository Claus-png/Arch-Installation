#!/usr/bin/env bash

set -u -o pipefail

_partition_disk() {
    local disk="$1"
    local part_efi="$2"
    local part_root="$3"
    local use_luks="${4:-no}"

    validate_disk_path "$disk" || _die "Некорректный диск: $disk"

    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] partition_disk skipped"
        return 0
    fi

    umount -q -R /mnt 2>/dev/null || true
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        umount -q -f "/dev/$p" 2>/dev/null || true
    done < <(lsblk -rno NAME "$disk" 2>/dev/null | tail -n +2)

    run_cmd "disable swap" swapoff -a
    run_cmd "wipe filesystem metadata" wipefs -af "$disk"
    run_cmd "zap GPT" sgdisk --zap-all "$disk"
    run_cmd "create EFI partition" sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI System" "$disk"
    run_cmd "create root partition" sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux btrfs" "$disk"
    run_cmd "settle udev" udevadm settle
    run_cmd "probe partitions" partprobe "$disk"
    sleep 2

    [[ -b "$part_efi" ]] || _die "EFI partition not created: $part_efi"
    [[ -b "$part_root" ]] || _die "Root partition not created: $part_root"

    run_cmd "format EFI" mkfs.fat -F32 -n EFI "$part_efi"

    if [[ "$use_luks" == "yes" ]]; then
        run_cmd "format LUKS" bash -lc 'printf "%s" "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 "$PART_ROOT" -'
        run_cmd "open LUKS" bash -lc 'printf "%s" "$LUKS_PASSWORD" | cryptsetup open "$PART_ROOT" cryptroot'
        TARGET_BTRFS="/dev/mapper/cryptroot"
    else
        TARGET_BTRFS="$part_root"
        run_cmd "format root" mkfs.btrfs -L ARCH -f "$TARGET_BTRFS"
    fi

    local BOPTS="noatime,compress=zstd:3,space_cache=v2,discard=async"

    run_cmd "mount root for subvolumes" mount "$TARGET_BTRFS" /mnt
    run_cmd "create @ subvolume" btrfs subvolume create "/mnt/@"
    run_cmd "create @home subvolume" btrfs subvolume create "/mnt/@home"
    run_cmd "create @log subvolume" btrfs subvolume create "/mnt/@log"
    run_cmd "create @cache subvolume" btrfs subvolume create "/mnt/@cache"
    run_cmd "create @snapshots subvolume" btrfs subvolume create "/mnt/@snapshots"
    run_cmd "unmount root" umount -R /mnt

    run_cmd "mount root subvolume" mount -o "${BOPTS},subvol=@" "$TARGET_BTRFS" /mnt
    run_cmd "prepare mount points" mkdir -p /mnt/{boot,home,var/log,var/cache,snapshots}
    run_cmd "mount home subvolume" mount -o "${BOPTS},subvol=@home" "$TARGET_BTRFS" /mnt/home
    run_cmd "mount log subvolume" mount -o "${BOPTS},subvol=@log" "$TARGET_BTRFS" /mnt/var/log
    run_cmd "mount cache subvolume" mount -o "${BOPTS},subvol=@cache" "$TARGET_BTRFS" /mnt/var/cache
    run_cmd "mount snapshots subvolume" mount -o "${BOPTS},subvol=@snapshots" "$TARGET_BTRFS" /mnt/snapshots
    run_cmd "mount EFI" mount "$part_efi" /mnt/boot

    export TARGET_BTRFS PART_EFI="$part_efi" PART_ROOT="$part_root"
    ROOT_UUID=$(blkid -s UUID -o value "$part_root")
    export ROOT_UUID
    stage_done "disk_done"
}

_derive_partition_names() {
    local disk="$1"
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]] || [[ "$disk" =~ mmcblk[0-9]+$ ]]; then
        echo "${disk}p1|${disk}p2"
    else
        echo "${disk}1|${disk}2"
    fi
}

_select_target_disk() {
    local BOOTMNT_DEV
    BOOTMNT_DEV=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)

    local LIVE_DISK=""
    [[ -n "$BOOTMNT_DEV" ]] && LIVE_DISK=$(lsblk -no PKNAME "$BOOTMNT_DEV" 2>/dev/null || echo "")

    local DISK_LIST=()
    while IFS= read -r line; do
        local NAME SIZE MODEL
        NAME=$(echo "$line" | awk '{print $1}')
        SIZE=$(echo "$line" | awk '{print $2}')
        MODEL=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)

        [[ "/dev/$NAME" == "$LIVE_DISK" ]] && continue
        DISK_LIST+=("/dev/$NAME" "${SIZE} — ${MODEL:-без модели}")
    done < <(lsblk -dno NAME,SIZE,MODEL | grep -v loop)

    local CHOSEN
    CHOSEN=$(whiptail --title "⚠  Выбор диска для УСТАНОВКИ  ⚠" \
        --menu \
        "Выбери диск для Arch Linux.\n\n!! ВСЕ ДАННЫЕ НА НЁМ БУДУТ УНИЧТОЖЕНЫ !!\n\nТвой SSD ~465ГБ. НЕ выбирай HDD 3.7ТБ и КИРИЛЛ 931ГБ!" \
        18 74 8 "${DISK_LIST[@]}" \
        3>&1 1>&2 2>&3) || _die "Установка отменена."

    validate_disk_path "$CHOSEN" || _die "Некорректный диск: $CHOSEN"

    local DGB MODEL_C SERIAL PARTS
    DGB=$(( $(lsblk -bno SIZE "$CHOSEN" | head -1) / 1024 / 1024 / 1024 ))
    MODEL_C=$(lsblk -no MODEL "$CHOSEN" 2>/dev/null | head -1 | xargs || echo "—")
    SERIAL=$(udevadm info "$CHOSEN" 2>/dev/null | grep "ID_SERIAL=" | head -1 | cut -d= -f2 || echo "—")
    PARTS=$(lsblk "$CHOSEN" 2>/dev/null | tail -n +2 | head -6 || echo "  —")

    whiptail --title "!! НЕОБРАТИМОЕ ДЕЙСТВИЕ !!" --yesno \
"БУДЕТ УНИЧТОЖЕНО:\n
  Диск:    $CHOSEN
  Размер:  ${DGB}ГБ
  Модель:  $MODEL_C
  S/N:     $SERIAL\n
Разделы:\n$PARTS\n\nWindows и все данные исчезнут НАВСЕГДА.\nТы точно выбрал правильный диск?" \
    22 72 || _die "Отменено."

    local CONFIRM
    CONFIRM=$(whiptail --title "Финальное подтверждение" \
        --inputbox \
        "Введи имя диска вручную:\n(например: /dev/nvme0n1 или /dev/sda)\n\n  Выбранный диск: $CHOSEN" \
        12 72 "" \
        3>&1 1>&2 2>&3) || _die "Отменено."

    [[ "$CONFIRM" == "$CHOSEN" ]] || _die "Диски не совпадают ($CONFIRM ≠ $CHOSEN).\nОтменено."

    echo "$CHOSEN"
}

ask_luks_enabled() {
    if whiptail --yesno "Enable LUKS encryption for this install?" 8 60 3>&1 1>&2 2>&3; then
        echo "yes"
    else
        echo "no"
    fi
}

ask_luks_password() {
    local pass1 pass2
    while true; do
        pass1=$(_password_input "LUKS password" "Введите пароль для LUKS:") || return 1
        pass2=$(_password_input "Confirm LUKS password" "Повторите пароль:") || return 1
        if [[ "$pass1" == "$pass2" ]]; then
            echo "$pass1"
            return 0
        fi
        _msg "Пароли не совпадают, попробуйте снова."
    done
}

configure_disk() {
    local disk="${DISK:-}"
    local use_luks="${USE_LUKS:-no}"

    if [[ -z "$disk" ]]; then
        disk=$(_select_target_disk)
        export DISK="$disk"
    fi

    if [[ "$use_luks" != "yes" ]]; then
        use_luks=$(ask_luks_enabled)
        export USE_LUKS="$use_luks"
    fi

    local part_efi part_root
    IFS='|' read -r part_efi part_root <<< "$(_derive_partition_names "$disk")"
    export PART_EFI="$part_efi" PART_ROOT="$part_root"

    if [[ "$use_luks" == "yes" ]]; then
        LUKS_PASSWORD=$(ask_luks_password)
        export LUKS_PASSWORD
    fi

    _partition_disk "$disk" "$part_efi" "$part_root" "$use_luks"
}
