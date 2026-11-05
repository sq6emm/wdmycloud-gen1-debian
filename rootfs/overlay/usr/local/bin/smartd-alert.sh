#!/bin/sh
# smartd -M exec hook: no mail on this box, so record the warning for the status page and the journal.
D=/srv/data/.nas-status
mkdir -p "$D"
printf '%s %s %s: %s\n' "$(date -Is)" "${SMARTD_DEVICE:-?}" "${SMARTD_FAILTYPE:-?}" "$(printf '%s' "${SMARTD_MESSAGE:-}" | tr '\n' ' ')" >> "$D/smartd-alerts.log"
logger -t smartd-alert -p daemon.warning "${SMARTD_DEVICE:-?} ${SMARTD_FAILTYPE:-?}: ${SMARTD_MESSAGE:-}"
