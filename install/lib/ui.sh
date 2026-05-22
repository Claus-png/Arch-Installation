#!/usr/bin/env bash

set -u -o pipefail

LOG_FILE="${LOG_FILE:-/var/log/install.log}"
PROGRESS_PIPE="${PROGRESS_PIPE:-/tmp/progress_pipe}"
PROGRESS_FD="${PROGRESS_FD:-3}"
PROGRESS_BAR_PID=""
NEWT_COLORS="${NEWT_COLORS:-root=,black roottext=,black title=,black checkbox=,blue button=,cyan}"
export NEWT_COLORS

_cleanup() {
    [ -n "${SUDO_KEEP_PID:-}" ] && kill "$SUDO_KEEP_PID" 2>/dev/null || true
    finish_progress_bar >/dev/null 2>&1 || true
    stty sane 2>/dev/null || true
    tput sgr0 2>/dev/null || true
    echo -e "\n[!] Выход из установщика. Лог сохранен в: $LOG_FILE"
}

_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"
}

_die() {
    whiptail --title "КРИТИЧЕСКАЯ ОШИБКА" --msgbox "$*\n\nЛог: $LOG_FILE" 12 72
    exit 1
}

_msg() {
    whiptail --title "Teddy Installer" --msgbox "$*" 12 72
}

_info() {
    whiptail --title "Teddy Installer" --infobox "$*" 7 72
    sleep 1
}

_input() {
    local title="$1"
    local prompt="$2"
    local default="${3:-}"
    whiptail --title "$title" --inputbox "$prompt" 10 72 "$default" 3>&1 1>&2 2>&3
}

_password_input() {
    local title="$1"
    local prompt="$2"
    whiptail --title "$title" --passwordbox "$prompt" 10 72 3>&1 1>&2 2>&3
}

_step() {
    local pct="$1"
    local msg="$2"
    progress_update "$pct"
    printf 'XXX\n%s\nXXX\n' "$msg"
    _log "$pct% — $msg"
}

init_progress_pipe() {
    rm -f "$PROGRESS_PIPE"
    mkfifo "$PROGRESS_PIPE"
    exec {PROGRESS_FD}> "$PROGRESS_PIPE"
    progress_reset
}

start_progress_bar() {
    local title="$1"
    local body="${2:-Инициализация...}"
    (
        while IFS= read -r value; do
            [[ -n "$value" ]] || continue
            printf 'XXX\n%s\nXXX\n' "$value"
        done < "$PROGRESS_PIPE"
    ) | whiptail --title "$title" --gauge "$body" 8 74 0 &
    PROGRESS_BAR_PID=$!
}

finish_progress_bar() {
    if [[ -n "$PROGRESS_BAR_PID" ]]; then
        exec {PROGRESS_FD}>&-
        wait "$PROGRESS_BAR_PID" 2>/dev/null || true
        PROGRESS_BAR_PID=""
    fi
}

progress_reset() {
    echo "0" >&"$PROGRESS_FD" 2>/dev/null || true
}

progress_update() {
    local pct="$1"
    echo "$pct" >&"$PROGRESS_FD" 2>/dev/null || true
}

show_log() {
    whiptail --title "Install log" --textbox "$LOG_FILE" 24 100
}
