#!/usr/bin/env bash

set -u -o pipefail

LOG_FILE="${LOG_FILE:-/var/log/install.log}"
PROGRESS_PIPE="${PROGRESS_PIPE:-/tmp/progress_pipe}"
PROGRESS_STATE_FILE="${PROGRESS_STATE_FILE:-/tmp/progress_state}"
PROGRESS_FD=""
PROGRESS_BAR_PID=""
NEWT_COLORS="${NEWT_COLORS:-root=,black roottext=,white title=,white checkbox=,cyan button=,cyan}"
INSTALL_BRAND="Teddy Installer"
export NEWT_COLORS

_cleanup() {
    if [ -n "${SUDO_KEEP_PID:-}" ]; then
        kill "$SUDO_KEEP_PID" 2>/dev/null || :
    fi
    if ! finish_progress_bar >/dev/null 2>&1; then
        :
    fi
    if ! stty sane 2>/dev/null; then
        :
    fi
    if ! tput sgr0 2>/dev/null; then
        :
    fi
    echo -e "\n[!] Выход из установщика. Лог сохранен в: $LOG_FILE"
}

_log() {
    echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE"
}

_run_optional() {
    local desc="$1"
    shift
    if "$@"; then
        return 0
    fi
    _log "WARN: $desc"
    return 0
}

_die() {
    _log "FATAL: $*"
    whiptail --title "КРИТИЧЕСКАЯ ОШИБКА" --msgbox "$*\n\nЛог: $LOG_FILE" 12 72
    exit 1
}

_msg() {
    whiptail --title "$INSTALL_BRAND" --msgbox "$*" 12 72
}

_info() {
    whiptail --title "$INSTALL_BRAND" --infobox "$*" 7 72
    sleep 1
}

show_header() {
    local title="$1"
    local body="$2"
    whiptail --title "$title" --msgbox "$body" 12 74
}

ask_yes_no() {
    whiptail --yesno "$1" 10 74
}

ask_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    whiptail --title "$title" --menu "$prompt" 14 74 8 "$@" 3>&1 1>&2 2>&3
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

    if [[ -e /dev/fd/3 ]]; then
        printf 'XXX\n%s\n%s\nXXX\n' "$pct" "$msg" >&3
    else
        printf 'XXX\n%s\n%s\nXXX\n' "$pct" "$msg"
    fi

    _log "$pct% — $msg"
}

init_progress_pipe() {
    rm -f "$PROGRESS_PIPE"
    : > "$PROGRESS_STATE_FILE"
    PROGRESS_FD=""
}

start_progress_bar() {
    local title="$1"
    local body="${2:-Инициализация...}"

    if ! finish_progress_bar >/dev/null 2>&1; then
        :
    fi
    coproc PROGRESS_COPROC {
        while IFS= read -r value || [[ -n "$value" ]]; do
            [[ -n "$value" ]] || continue
            printf 'XXX\n%s\nXXX\n' "$value"
        done
    }
    whiptail --title "$title" --gauge "$body" 8 74 0 <&"${PROGRESS_COPROC[0]}" &
    PROGRESS_BAR_PID=$!
    exec {PROGRESS_FD}>&"${PROGRESS_COPROC[1]}"
    progress_reset
}

finish_progress_bar() {
    if [[ -n "${PROGRESS_FD:-}" ]]; then
        exec {PROGRESS_FD}>&-
        PROGRESS_FD=""
    fi
    if [[ -n "$PROGRESS_BAR_PID" ]]; then
        if ! wait "$PROGRESS_BAR_PID" 2>/dev/null; then
            :
        fi
        PROGRESS_BAR_PID=""
    fi
}

progress_reset() {
    if [[ -n "${PROGRESS_FD:-}" ]]; then
        printf '0\n' >&"$PROGRESS_FD"
    else
        printf '0\n' > "$PROGRESS_STATE_FILE"
    fi
}

progress_update() {
    local pct="$1"
    if [[ -n "${PROGRESS_FD:-}" ]]; then
        printf '%s\n' "$pct" >&"$PROGRESS_FD"
    else
        printf '%s\n' "$pct" > "$PROGRESS_STATE_FILE"
    fi
}

show_log() {
    whiptail --title "Install log" --textbox "$LOG_FILE" 24 100
}
