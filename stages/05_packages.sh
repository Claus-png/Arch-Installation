#!/usr/bin/env bash

stage_05_packages() {
    if [[ -n "${PACKAGE_LIST:-}" ]]; then
        SELECTED_PACKAGES="$PACKAGE_LIST"
        export SELECTED_PACKAGES
        return 0
    fi

    SELECTED_PACKAGES=$(select_packages) || return 1
    export SELECTED_PACKAGES
}
