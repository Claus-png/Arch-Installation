#!/usr/bin/env bash

stage_04_user_config() {
    if [[ -n "${USERNAME:-}" && -n "${HOSTNAME:-}" ]]; then
        return 0
    fi

    USERNAME=$(_input "User configuration" "Enter username:" "$USERNAME") || return 1
    HOSTNAME=$(_input "Host configuration" "Enter hostname:" "$HOSTNAME") || return 1

    [[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || _die "Некорректное имя пользователя: $USERNAME"

    export USERNAME HOSTNAME
}
