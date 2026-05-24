#!/usr/bin/env bash

stage_04_user_config() {
    local default_user="${USERNAME:-${DEFAULT_USERNAME:-teddy}}"
    local default_host="${HOSTNAME:-${DEFAULT_HOSTNAME:-archbox}}"
    local default_tz="${TIMEZONE:-${DEFAULT_TIMEZONE:-Europe/Moscow}}"
    local pass1 pass2

    USERNAME=$(_input "Настройка пользователя" "Имя пользователя:" "$default_user") || return 1
    HOSTNAME=$(_input "Настройка хоста" "Имя хоста:" "$default_host") || return 1
    TIMEZONE=$(_input "Настройка часового пояса" "Часовой пояс (например Europe/Moscow):" "$default_tz") || return 1

    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || _die "Некорректный часовой пояс: $TIMEZONE"
    [[ "$USERNAME" =~ ^[a-z][a-z0-9_-]*$ ]] || _die "Некорректное имя пользователя: $USERNAME"
    validate_hostname "$HOSTNAME"

    while true; do
        pass1=$(_password_input "Пароль пользователя" "Придумайте пароль для пользователя:") || return 1
        [[ -n "$pass1" ]] || { _msg "Пароль пользователя не может быть пустым."; continue; }
        pass2=$(_password_input "Подтверждение пароля" "Повторите пароль пользователя:") || return 1
        [[ "$pass1" == "$pass2" ]] || { _msg "Пароли пользователя не совпадают."; continue; }
        USER_PASSWORD="$pass1"
        break
    done

    while true; do
        pass1=$(_password_input "Пароль root" "Придумайте пароль для root:") || return 1
        [[ -n "$pass1" ]] || { _msg "Пароль root не может быть пустым."; continue; }
        pass2=$(_password_input "Подтверждение пароля" "Повторите пароль root:") || return 1
        [[ "$pass1" == "$pass2" ]] || { _msg "Пароли root не совпадают."; continue; }
        ROOT_PASSWORD="$pass1"
        break
    done

    export USERNAME HOSTNAME TIMEZONE USER_PASSWORD ROOT_PASSWORD
}
