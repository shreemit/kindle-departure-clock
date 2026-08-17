#!/bin/sh
EXT_DIR="/mnt/us/extensions/pw3clock"
LOG="/mnt/us/pw3clock.log"
PIDFILE="/var/tmp/pw3clock.pid"
TOUCH_PIDFILE="/var/tmp/pw3clock.touchpid"
echo "$(date '+%Y-%m-%d %H:%M:%S') stop.sh invoked" >> "$LOG" 2>/dev/null
if [ ! -f "${EXT_DIR}/bin/clock.sh" ]; then
    echo "ERROR: ${EXT_DIR}/bin/clock.sh missing" >> "$LOG" 2>/dev/null
    exit 1
fi
# shellcheck disable=SC1091
. "${EXT_DIR}/bin/clock.sh"

if [ -f "$TOUCH_PIDFILE" ]; then
    kill "$(cat "$TOUCH_PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$TOUCH_PIDFILE"
fi
if [ ! -f "${EXT_DIR}/bin/clock.sh" ]; then
    echo "ERROR: ${EXT_DIR}/bin/clock.sh missing" >> "$LOG" 2>/dev/null
    exit 1
fi
# shellcheck disable=SC1091
. "${EXT_DIR}/bin/clock.sh"

if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null
        sleep 1
        kill -9 "$PID" 2>/dev/null
    fi
    rm -f "$PIDFILE"
fi

start_gui
eips 2 2 "PW3 clock stopped" >/dev/null 2>&1
exit 0
