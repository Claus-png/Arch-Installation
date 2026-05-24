#!/usr/bin/env bash

set -u -o pipefail

DRY_RUN="${DRY_RUN:-0}"
INSTALL_STATE_DIR="${INSTALL_STATE_DIR:-/tmp/install_state}"
LOG_FILE="${LOG_FILE:-/var/log/install.log}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEFAULTS_FILE="${DEFAULTS_FILE:-$SCRIPT_DIR/../config/defaults.conf}"
PROFILE_FILE="${PROFILE_FILE:-$SCRIPT_DIR/../config/profile.conf}"

ensure_state_dir() {
    mkdir -p "$INSTALL_STATE_DIR"
}

reset_install_state() {
    ensure_state_dir
    rm -f "$INSTALL_STATE_DIR"/*.done
    _log "Install state reset"
}

mark_step() {
    local step="$1"
    touch "$INSTALL_STATE_DIR/${step}.done"
}

step_done() {
    local step="$1"
    [[ -f "$INSTALL_STATE_DIR/${step}.done" ]]
}

stage_done() {
    mark_step "$1"
}

stage_exists() {
    step_done "$1"
}

run_stage() {
    local stage="$1"
    shift
    if stage_exists "$stage"; then
        _log "Stage ${stage}: already complete, skipping"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] stage ${stage}: $*"
        stage_done "$stage"
        return 0
    fi
    "$@"
    local code=$?
    if [[ "$code" -eq 0 ]]; then
        stage_done "$stage"
        _log "Stage ${stage}: complete"
        return 0
    fi
    _log "Stage ${stage}: failed with exit ${code}"
    return "$code"
}

run_step() {
    local step="$1"
    shift
    if step_done "$step"; then
        _log "Step ${step}: already complete, skipping"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] step ${step}: $*"
        mark_step "$step"
        return 0
    fi
    "$@"
    local code=$?
    if [[ "$code" -eq 0 ]]; then
        mark_step "$step"
    else
        _log "Step ${step}: failed with exit ${code}"
    fi
    return "$code"
}

_load_defaults() {
    if [[ -f "$DEFAULTS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$DEFAULTS_FILE"
        _log "Loaded defaults from $DEFAULTS_FILE"
    fi
}

load_profile() {
    if [[ -f "$PROFILE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$PROFILE_FILE"
        _log "Loaded profile from $PROFILE_FILE"
    fi
}

apply_defaults() {
    export USERNAME="${USERNAME:-${DEFAULT_USERNAME:-teddy}}"
    export HOSTNAME="${HOSTNAME:-${DEFAULT_HOSTNAME:-archbox}}"
    export TIMEZONE="${TIMEZONE:-${DEFAULT_TIMEZONE:-Europe/Moscow}}"
    export USE_LUKS="${USE_LUKS:-${DEFAULT_USE_LUKS:-no}}"
    export DISK="${DISK:-}"
    export CPU_DRIVER="${CPU_DRIVER:-${DEFAULT_CPU_DRIVER:-auto}}"
    export GPU_DRIVER="${GPU_DRIVER:-${DEFAULT_GPU_DRIVER:-auto}}"
    export ZRAM_SIZE_MB="${ZRAM_SIZE_MB:-${DEFAULT_ZRAM_SIZE_MB:-0}}"
    export PACKAGE_LIST="${PACKAGE_LIST:-${DEFAULT_PACKAGE_LIST:-}}"
    export LUKS_PASSWORD="${LUKS_PASSWORD:-}"
    export USER_PASSWORD="${USER_PASSWORD:-${DEFAULT_USER_PASSWORD:-}}"
    export ROOT_PASSWORD="${ROOT_PASSWORD:-${DEFAULT_ROOT_PASSWORD:-}}"
}

_detect_cpu() {
    if grep -q "AuthenticAMD" /proc/cpuinfo; then
        CPU_DRIVER="amd-ucode"
    elif grep -q "GenuineIntel" /proc/cpuinfo; then
        CPU_DRIVER="intel-ucode"
    else
        CPU_DRIVER="auto"
    fi
}

_detect_gpu() {
    local vendor
    if ! vendor=$(lspci 2>/dev/null | awk '/VGA|3D/ {print $0}' | head -1); then
        vendor=""
    fi
    if echo "$vendor" | grep -qi "NVIDIA"; then
        GPU_DRIVER="nvidia-dkms"
    elif echo "$vendor" | grep -qi "AMD"; then
        GPU_DRIVER="amdgpu"
    elif echo "$vendor" | grep -qi "Intel"; then
        GPU_DRIVER="intel-media-driver"
    else
        GPU_DRIVER="auto"
    fi
}

detect_hardware() {
    _detect_cpu
    _detect_gpu
    local mem_kb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    ZRAM_SIZE_MB=$((mem_kb / 1024 / 2))
    export CPU_DRIVER GPU_DRIVER ZRAM_SIZE_MB
    _log "Hardware detected: CPU=$CPU_DRIVER GPU=$GPU_DRIVER ZRAM=${ZRAM_SIZE_MB}MiB"
}

validate_hostname() {
    local hostname="$1"
    [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || _die "Некорректный hostname: $hostname"
}

_retry_or_die() {
    local desc="$1"
    shift

    while true; do
        "$@"
        local code=$?
        if [[ "$code" -eq 0 ]]; then
            return 0
        fi

        if whiptail --yesno "Error: ${desc}\n\nExit code: ${code}\n\nRetry?" 10 60 3>&1 1>&2 2>&3; then
            continue
        fi

        _log "WARN: step skipped: ${desc}"
        return "$code"
    done
}

_try() {
    local desc="$1"
    shift
    _retry_or_die "$desc" "$@"
}

run_cmd() {
    local description="$1"
    shift
    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] ${description}: $*"
        return 0
    fi
    _log "RUN: ${description}"
    _try "$description" "$@"
}

configure_mkinitcpio() {
    local target_root="$1"
    local use_luks="$2"
    local gpu_driver="$3"
    local mkinitcpio_conf="$target_root/etc/mkinitcpio.conf"

    if [[ "$use_luks" == "yes" ]]; then
        if grep -q 'encrypt' "$mkinitcpio_conf"; then
            :
        elif grep -q '^HOOKS=' "$mkinitcpio_conf"; then
            if grep -q '\<block\>' "$mkinitcpio_conf"; then
                sed -i 's/\<block\>/block encrypt/' "$mkinitcpio_conf"
            else
                sed -i -E 's/^HOOKS=\((.*)\)$/HOOKS=(\1 block encrypt)/' "$mkinitcpio_conf"
            fi
            grep -q 'encrypt' "$mkinitcpio_conf" || _die "Не удалось добавить encrypt в mkinitcpio.conf"
        fi
    fi

    if [[ "$gpu_driver" == "nvidia-dkms" ]]; then
        if grep -q '^MODULES=' "$mkinitcpio_conf"; then
            sed -i -E 's/^MODULES=\(.*\)$/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' "$mkinitcpio_conf"
        else
            echo 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)' >> "$mkinitcpio_conf"
        fi
    fi

    arch-chroot "$target_root" mkinitcpio -P >> "$LOG_FILE" 2>&1 || _die "Не удалось обновить initramfs"
}

configure_zram() {
    local target_root="$1"
    mkdir -p "$target_root/etc/systemd"
    cat > "$target_root/etc/systemd/zram-generator.conf" <<EOF
[zram0]
zram-size = ${ZRAM_SIZE_MB}
compression-algorithm = zstd
EOF
}

validate_backup_device() {
    local disk="$1"
    [[ "$disk" == "Пропустить" || "$disk" == "Восстановить вручную после перезагрузки" || "$disk" =~ ^/dev/(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+|mmcblk[0-9]+)$ ]]
}

stage_text() {
    local current="$1"
    local total="$2"
    local msg="$3"
    printf 'Stage %s of %s: %s' "$current" "$total" "$msg"
}

_check_deps() {
    local missing=()
    local cmd

    for cmd in whiptail sgdisk wipefs partprobe mkfs.btrfs mkfs.fat arch-chroot genfstab bootctl blkid lspci udevadm curl mountpoint pacman cryptsetup mkinitcpio sudo git findmnt pv tune2fs btrfstune; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        _die "Отсутствуют зависимости: ${missing[*]}"
    fi
}

preflight_checks() {
    if [[ "$DRY_RUN" == "1" ]]; then
        _log "[dry-run] preflight checks skipped"
        return 0
    fi

    _check_deps
    [ -d /sys/firmware/efi/efivars ] || _die "BIOS-режим! Нужен UEFI."
    timedatectl set-ntp true >> "$LOG_FILE" 2>&1 || _die "Не удалось синхронизировать время"
    curl -fsSL --max-time 5 https://archlinux.org >/dev/null 2>&1 || _die "Нет интернет-соединения"

    local mem_gb
    mem_gb=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
    [[ "$mem_gb" -ge 2 ]] || _die "Недостаточно RAM: требуется >= 2 GB, найдено ${mem_gb} GB"

    detect_hardware
    init_progress_pipe
    progress_reset
    _log "Preflight checks passed"
}
