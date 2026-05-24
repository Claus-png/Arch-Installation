#!/usr/bin/env bash

stage_03_disk_setup() {
    if stage_exists "disk_done"; then
        if [[ -n "${DISK:-}" && -n "${PART_EFI:-}" && -n "${PART_ROOT:-}" ]]; then
            _msg "Диск уже настроен: ${DISK:-unknown}. Для смены диска перезапустите установщик."
            return 0
        fi

        _log "Старый маркер disk_done найден, сбрасываю состояние диска"
        rm -f "$INSTALL_STATE_DIR/disk_done.done"
    fi

    configure_disk
}
