#!/usr/bin/env bash

stage_01_welcome() {
    whiptail --title "Arch Installer — Welcome" --msgbox \
"Welcome to the staged Arch installer.\n\nThis wizard will guide you through preflight checks, hardware detection, disk setup, package selection, and the install itself." 12 72
}
