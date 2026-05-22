#!/usr/bin/env bash

write_install_vars() {
    local root_uuid
    root_uuid=$(blkid -s UUID -o value "$PART_ROOT")
    cat > /mnt/root/install_vars.env <<EOF
USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
ROOT_UUID="$root_uuid"
PART_EFI="$PART_EFI"
PART_ROOT="$PART_ROOT"
USE_LUKS="$USE_LUKS"
LUKS_PASSWORD="${LUKS_PASSWORD:-}"
EOF
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    cp "$SCRIPT_DIR/install_tui.sh" /mnt/root/install_tui.sh
    chmod +x /mnt/root/install_tui.sh
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
    if [[ "$CPU_DRIVER" == "amd-ucode" ]]; then
        ucode_img="amd-ucode.img"
    fi

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
    arch-chroot /mnt bash -lc "echo '$USERNAME:arch' | chpasswd"
    arch-chroot /mnt bash -lc 'echo root:arch | chpasswd'
    arch-chroot /mnt bash -lc 'sed -i "s/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/" /etc/sudoers'
    arch-chroot /mnt bash -lc "echo '$HOSTNAME' > /etc/hostname"
}

stage_07_install() {
    run_step pacstrap pacstrap -K /mnt base linux linux-firmware linux-lts base-devel networkmanager sudo git curl wget zsh whiptail btrfs-progs efibootmgr intel-ucode amd-ucode
    if [[ -n "${SELECTED_PACKAGES:-}" ]]; then
        run_step packages arch-chroot /mnt pacman -S --needed --noconfirm ${SELECTED_PACKAGES}
    else
        _log "No packages selected; skipping package install"
    fi
    run_step hardware install_hardware_packages
    run_step zram configure_zram /mnt
    run_step mkinitcpio configure_mkinitcpio /mnt "$USE_LUKS" "$GPU_DRIVER"
    run_step bootloader write_bootloader
    run_step config configure_locale_and_user
    write_install_vars
    unset LUKS_PASSWORD
}
