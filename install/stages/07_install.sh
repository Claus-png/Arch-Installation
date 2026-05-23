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
    [[ "$CPU_DRIVER" == "amd-ucode" ]] && ucode_img="amd-ucode.img"

    bootctl install --path=/mnt/boot >> "$LOG_FILE" 2>&1 || _die "Не удалось установить systemd-boot"
    mkdir -p /mnt/boot/loader/entries
    cat > /mnt/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF

    if [[ "$USE_LUKS" == "yes" ]]; then
        cat > /mnt/boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /${ucode_img}
initrd /initramfs-linux.img
options cryptdevice=UUID=$(blkid -s UUID -o value "$PART_ROOT"):cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ quiet
EOF
    else
        cat > /mnt/boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /${ucode_img}
initrd /initramfs-linux.img
options root=UUID=$(blkid -s UUID -o value "$PART_ROOT") rw rootflags=subvol=@ quiet
EOF
    fi
}

configure_locale_and_user() {
    arch-chroot /mnt bash -lc 'ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime'
    arch-chroot /mnt bash -lc 'hwclock --systohc'
    arch-chroot /mnt bash -lc 'sed -i "s/^#\\(en_US.UTF-8 UTF-8\\)/\\1/; s/^#\\(ru_RU.UTF-8 UTF-8\\)/\\1/" /etc/locale.gen'
    arch-chroot /mnt bash -lc 'locale-gen'
    arch-chroot /mnt bash -lc 'echo LANG=ru_RU.UTF-8 > /etc/locale.conf'
    arch-chroot /mnt bash -lc "useradd -m -G wheel,audio,video,storage,optical,input -s /bin/zsh '$USERNAME'"
    arch-chroot /mnt bash -lc "echo '$USERNAME:${USER_PASSWORD:-arch}' | chpasswd"
    arch-chroot /mnt bash -lc "echo 'root:${ROOT_PASSWORD:-arch}' | chpasswd"
    arch-chroot /mnt bash -lc 'sed -i "s/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/" /etc/sudoers'
    arch-chroot /mnt bash -lc "echo '$HOSTNAME' > /etc/hostname"
    arch-chroot /mnt bash -lc "mkdir -p \"/home/$USERNAME/install\" \"/home/$USERNAME/config\" && cp /root/install/install_tui.sh \"/home/$USERNAME/install_tui.sh\" && cp -a /root/install/. \"/home/$USERNAME/install/\" && cp -a /root/config/. \"/home/$USERNAME/config/\" && cp /root/install_vars.env \"/home/$USERNAME/install_vars.env\" && chmod 600 \"/home/$USERNAME/install_vars.env\" && chown -R \"$USERNAME:$USERNAME\" \"/home/$USERNAME\""
}

stage_07_install() {
    run_step pacstrap pacstrap -K /mnt base linux linux-firmware linux-lts base-devel networkmanager sudo git curl wget zsh whiptail btrfs-progs efibootmgr intel-ucode amd-ucode

    if [[ -n "${SELECTED_PACKAGES:-}" ]]; then
        local -a selected_packages=()
        read -r -a selected_packages <<< "$SELECTED_PACKAGES"
        run_step packages arch-chroot /mnt pacman -S --needed --noconfirm "${selected_packages[@]}"
    else
        _log "No packages selected; skipping package install"
    fi

    run_step hardware install_hardware_packages
    run_step zram configure_zram /mnt
    run_step mkinitcpio configure_mkinitcpio /mnt "$USE_LUKS" "$GPU_DRIVER"
    run_step bootloader write_bootloader
    write_install_vars
    run_step config configure_locale_and_user
    unset LUKS_PASSWORD
}
