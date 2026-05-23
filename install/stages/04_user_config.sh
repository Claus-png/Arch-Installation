#!/usr/bin/env bash

stage_04_user_config() {
    local default_user="${USERNAME:-${DEFAULT_USERNAME:-teddy}}"
    local default_host="${HOSTNAME:-${DEFAULT_HOSTNAME:-archbox}}"

    USERNAME=$(_input "Настройка пользователя" "Имя пользователя:" "$default_user") || return 1
    HOSTNAME=$(_input "Настройка хоста" "Имя хоста:" "$default_host") || return 1

    USER_PASSWORD=$(_password_input "Пароль пользователя" "Придумайте пароль для пользователя:") || return 1
    ROOT_PASSWORD=$(_password_input "Пароль root" "Придумайте пароль для root:") || return 1

    [[ -n "$USER_PASSWORD" ]] || USER_PASSWORD="${DEFAULT_USER_PASSWORD:-arch}"
    [[ -n "$ROOT_PASSWORD" ]] || ROOT_PASSWORD="${DEFAULT_ROOT_PASSWORD:-arch}"
    [[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || _die "Некорректное имя пользователя: $USERNAME"

    export USERNAME HOSTNAME USER_PASSWORD ROOT_PASSWORD
}
