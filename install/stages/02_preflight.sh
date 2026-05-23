#!/usr/bin/env bash

stage_02_preflight() {
    preflight_checks
    whiptail --title "Системные проверки" --msgbox \
"UEFI, сеть, время и ресурсы готовы.\n\nДалее вы перейдёте к выбору диска и настройке пользователя." 10 74
}
