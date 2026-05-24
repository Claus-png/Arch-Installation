#!/usr/bin/env bash

write_install_vars() {
    local root_uuid
    if [[ "${USE_LUKS:-no}" == "yes" ]]; then
        root_uuid=$(blkid -s UUID -o value /dev/mapper/cryptroot)
    else
        root_uuid=$(blkid -s UUID -o value "$PART_ROOT")
    fi
    local old_umask
    old_umask=$(umask)
    umask 077
    cat > /mnt/root/install_vars.env <<EOF
USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
ROOT_UUID="$root_uuid"
PART_EFI="$PART_EFI"
PART_ROOT="$PART_ROOT"
USE_LUKS="$USE_LUKS"
CPU_DRIVER="$CPU_DRIVER"
GPU_DRIVER="$GPU_DRIVER"
TIMEZONE="$TIMEZONE"
ZRAM_SIZE_MB="$ZRAM_SIZE_MB"
EOF
    umask "$old_umask"
    chmod 600 /mnt/root/install_vars.env
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    mkdir -p /mnt/root/install /mnt/root/config
    cp -a "$SCRIPT_DIR/." /mnt/root/install/
    cp -a "$SCRIPT_DIR/../config/." /mnt/root/config/
    if [[ -f "$SCRIPT_DIR/../backup_tui.sh" ]]; then
        cp "$SCRIPT_DIR/../backup_tui.sh" /mnt/root/backup_tui.sh
    fi
    chmod +x /mnt/root/install/install_tui.sh
}

install_hardware_packages() {
    if [[ "$CPU_DRIVER" == "intel-ucode" ]]; then
        arch-chroot /mnt pacman -S --needed --noconfirm intel-ucode >> "$LOG_FILE" 2>&1
    fi
    if [[ "$CPU_DRIVER" == "amd-ucode" ]]; then
        arch-chroot /mnt pacman -S --needed --noconfirm amd-ucode >> "$LOG_FILE" 2>&1
    fi
    if [[ "$GPU_DRIVER" == "nvidia-dkms" ]]; then
        arch-chroot /mnt pacman -S --needed --noconfirm nvidia-dkms >> "$LOG_FILE" 2>&1
    fi
    if [[ "$GPU_DRIVER" == "amdgpu" ]]; then
        arch-chroot /mnt pacman -S --needed --noconfirm mesa >> "$LOG_FILE" 2>&1
    fi
    if [[ "$GPU_DRIVER" == "intel-media-driver" ]]; then
        arch-chroot /mnt pacman -S --needed --noconfirm intel-media-driver >> "$LOG_FILE" 2>&1
    fi
    arch-chroot /mnt pacman -S --needed --noconfirm zram-generator >> "$LOG_FILE" 2>&1
}

write_bootloader() {
    local ucode_img="intel-ucode.img"
    local root_opts="root=UUID=$(blkid -s UUID -o value "$PART_ROOT") rw rootflags=subvol=@"
    [[ "$CPU_DRIVER" == "amd-ucode" ]] && ucode_img="amd-ucode.img"

    if [[ "$USE_LUKS" == "yes" ]]; then
        root_opts="cryptdevice=UUID=$(blkid -s UUID -o value "$PART_ROOT"):cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@"
    fi

    bootctl --esp-path=/mnt/boot install >> "$LOG_FILE" 2>&1 || _die "Не удалось установить systemd-boot"
    mkdir -p /mnt/boot/loader/entries
    cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF

    cat > /mnt/boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /${ucode_img}
initrd /initramfs-linux.img
options ${root_opts} quiet loglevel=3
EOF

    cat > /mnt/boot/loader/entries/arch-lts.conf <<EOF
title Arch Linux (LTS)
linux /vmlinuz-linux-lts
initrd /${ucode_img}
initrd /initramfs-linux-lts.img
options ${root_opts} quiet loglevel=3
EOF

    cat > /mnt/boot/loader/entries/arch-fallback.conf <<EOF
title Arch Linux (fallback)
linux /vmlinuz-linux
initrd /${ucode_img}
initrd /initramfs-linux-fallback.img
options ${root_opts}
EOF
}

configure_locale_and_user() {
    local tz="${TIMEZONE:-Europe/Moscow}"

    arch-chroot /mnt bash -s "$tz" "$USERNAME" "$HOSTNAME" "$USER_PASSWORD" "$ROOT_PASSWORD" <<'CHROOT'
set -euo pipefail
TZ="$1"
USERNAME="$2"
HOSTNAME="$3"
USER_PASSWORD="$4"
ROOT_PASSWORD="$5"

ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
hwclock --systohc
sed -i "s/^#\(en_US.UTF-8 UTF-8\)/\1/; s/^#\(ru_RU.UTF-8 UTF-8\)/\1/" /etc/locale.gen
locale-gen
printf 'LANG=ru_RU.UTF-8\n' > /etc/locale.conf
cat > /etc/vconsole.conf <<'EOF'
KEYMAP=ru
FONT=cyr-sun16
EOF

useradd -m -G wheel,audio,video,storage,optical,input -s /bin/zsh "$USERNAME"
if ! printf '%s\n%s\n' "$USER_PASSWORD" "$USER_PASSWORD" | chpasswd; then
    echo "Failed to set user password" >&2
    exit 1
fi
if ! printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | chpasswd; then
    echo "Failed to set root password" >&2
    exit 1
fi
sed -i "s/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/" /etc/sudoers
printf '%s\n' "$HOSTNAME" > /etc/hostname

mkdir -p "/home/$USERNAME/install" "/home/$USERNAME/config"
cp /root/install/install_tui.sh "/home/$USERNAME/install_tui.sh"
cp -a /root/install/. "/home/$USERNAME/install/"
cp -a /root/config/. "/home/$USERNAME/config/"
cp /root/install_vars.env "/home/$USERNAME/install_vars.env"
chmod 600 "/home/$USERNAME/install_vars.env"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
CHROOT
}

install_selected_packages() {
    local -a pacman_packages=()
    local -a aur_packages=()
    local pkg

    if [[ -z "${SELECTED_PACKAGES:-}" ]]; then
        _log "No packages selected; skipping package install"
        return 0
    fi

    read -r -a pacman_packages <<< "$SELECTED_PACKAGES"
    for pkg in "${pacman_packages[@]}"; do
        case "$pkg" in
            aur:*)
                aur_packages+=("${pkg#aur:}")
                ;;
            paru:*)
                aur_packages+=("${pkg#paru:}")
                ;;
        esac
    done

    if [[ ${#pacman_packages[@]} -gt 0 ]]; then
        local -a pacman_filtered=()
        for pkg in "${pacman_packages[@]}"; do
            case "$pkg" in
                aur:*|paru:*)
                    ;;
                *)
                    pacman_filtered+=("$pkg")
                    ;;
            esac
        done
        if [[ ${#pacman_filtered[@]} -gt 0 ]]; then
            run_step packages arch-chroot /mnt pacman -S --needed --noconfirm "${pacman_filtered[@]}"
        fi
    fi

    if [[ ${#aur_packages[@]} -gt 0 ]]; then
        arch-chroot /mnt pacman -S --needed --noconfirm base-devel git >/dev/null 2>&1
        arch-chroot /mnt bash -lc 'if ! command -v paru >/dev/null 2>&1; then
            rm -rf /tmp/paru
            git clone https://aur.archlinux.org/paru.git /tmp/paru
            (cd /tmp/paru && makepkg -si --noconfirm >/dev/null 2>&1)
        fi'
        arch-chroot /mnt bash -lc "paru -S --needed --noconfirm $(printf '%q ' "${aur_packages[@]}")"
    fi
}

stage_07_install() {
    run_step pacstrap pacstrap -K /mnt base linux linux-firmware linux-lts base-devel networkmanager sudo git curl wget zsh whiptail btrfs-progs efibootmgr
    install_selected_packages
    run_step hardware install_hardware_packages
    run_step zram configure_zram /mnt
    run_step mkinitcpio configure_mkinitcpio /mnt "$USE_LUKS" "$GPU_DRIVER"
    run_step bootloader write_bootloader
    write_install_vars
    run_step config configure_locale_and_user
    unset LUKS_PASSWORD
}
