#!/bin/sh
EXT_DIR="/mnt/us/extensions/pw3clock"
LOG="/mnt/us/pw3clock.log"
export EXT_DIR LOG
echo "$(date '+%Y-%m-%d %H:%M:%S') debug.sh invoked" >> "$LOG" 2>/dev/null
if [ ! -f "${EXT_DIR}/bin/clock.sh" ]; then
    echo "ERROR: ${EXT_DIR}/bin/clock.sh missing. Copy folder to extensions/pw3clock" >> "$LOG" 2>/dev/null
    eips 1 1 "pw3clock: wrong folder" >/dev/null 2>&1
    exit 1
fi
# shellcheck disable=SC1091
. "${EXT_DIR}/bin/clock.sh"
run_debug
exit 0
