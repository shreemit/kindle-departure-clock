#!/bin/sh
# Watch the PW3 touchscreen and ask the clock to exit.
#
# Two ways to trigger, because touch-to-framebuffer coordinate mapping varies:
#   1. Tap the EXIT box.
#   2. Tap anywhere 3 times within a few seconds (needs no coordinates).
#
# The device is opened once and held open. Reopening per read drops the events
# that arrive in between, which is why taps used to go unnoticed.

LOG="${LOG:-/mnt/us/pw3clock.log}"
PW3_TMP="${PW3_TMP:-/var/tmp}"
EXIT_FLAG="${EXIT_FLAG:-${PW3_TMP}/pw3clock.STOP}"
RECT_FILE="${EXIT_RECT:-${PW3_TMP}/pw3clock.exitrect}"
FBINFO="${FBINFO:-${PW3_TMP}/pw3clock.fbinfo}"
PIDFILE="${PIDFILE:-${PW3_TMP}/pw3clock.pid}"

TAPS_TO_EXIT=3
TAP_WINDOW=4

tlog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') touch: $*" >> "$LOG" 2>/dev/null
}

find_touch_dev() {
    if [ -e /dev/input/touch ]; then
        echo /dev/input/touch
        return 0
    fi
    _named=$(awk '
        BEGIN { RS = ""; FS = "\n" }
        {
            n = ""; h = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^N: Name=/) n = $i
                if ($i ~ /^H: Handlers=/) h = $i
            }
            if (n ~ /pt_mt|zforce|[Tt]ouch|cyttsp/) {
                if (match(h, /event[0-9]+/)) { print substr(h, RSTART, RLENGTH); exit }
            }
        }
    ' /proc/bus/input/devices 2>/dev/null)
    if [ -n "$_named" ] && [ -e "/dev/input/$_named" ]; then
        echo "/dev/input/$_named"
        return 0
    fi
    for _d in /dev/input/event1 /dev/input/event2 /dev/input/event3 /dev/input/event0; do
        [ -e "$_d" ] && { echo "$_d"; return 0; }
    done
    return 1
}

# input_event on 32-bit ARM: 8B timeval, u16 type, u16 code, s32 value.
read_event() {
    set -- $(dd bs=16 count=1 <&3 2>/dev/null | od -An -tu1 -v)
    [ $# -ge 14 ] || return 1
    TYPE=$(($9 + ${10} * 256))
    CODE=$((${11} + ${12} * 256))
    VAL=$((${13} + ${14} * 256))
    return 0
}

map_to_fb() {
    # Panel is natively portrait; the board runs rotated. Touch X follows the
    # short axis, touch Y the long axis.
    case "$TOUCH_MAP" in
        2) FBX=$((MAX_Y - LAST_Y)); FBY=$LAST_X ;;
        3) FBX=$LAST_X;             FBY=$LAST_Y ;;
        4) FBX=$((MAX_X - LAST_X)); FBY=$LAST_Y ;;
        *) FBX=$LAST_Y;             FBY=$((MAX_X - LAST_X)) ;;
    esac
    [ "$FBX" -lt 0 ] && FBX=0
    [ "$FBY" -lt 0 ] && FBY=0
}

hit_exit() {
    [ -n "$EXIT_L" ] || return 1
    _pad=30
    _l=$((EXIT_L - _pad)); [ "$_l" -lt 0 ] && _l=0
    _t=$((EXIT_T - _pad)); [ "$_t" -lt 0 ] && _t=0
    _r=$((EXIT_L + EXIT_W + _pad))
    _b=$((EXIT_T + EXIT_H + _pad))
    [ "$FBX" -ge "$_l" ] && [ "$FBX" -lt "$_r" ] &&
        [ "$FBY" -ge "$_t" ] && [ "$FBY" -lt "$_b" ]
}

request_exit() {
    tlog "exit requested ($1)"
    touch "$EXIT_FLAG"
    if [ -f "$PIDFILE" ]; then
        kill -USR1 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
    fi
    exit 0
}

[ -f "$RECT_FILE" ] && read EXIT_L EXIT_T EXIT_W EXIT_H < "$RECT_FILE"
[ -f "$FBINFO" ] && read VIEW_W VIEW_H NEW_ROTATE ORIG_ROTATE < "$FBINFO"
: "${VIEW_W:=1448}"
: "${VIEW_H:=1072}"
: "${TOUCH_MAP:=1}"

# Touch axes are reported in native portrait pixels on this panel.
MAX_X=$VIEW_H
MAX_Y=$VIEW_W

TOUCH_DEV=$(find_touch_dev) || { tlog "no touch device found"; exit 1; }
exec 3< "$TOUCH_DEV" || { tlog "cannot open $TOUCH_DEV"; exit 1; }
tlog "watching $TOUCH_DEV view=${VIEW_W}x${VIEW_H} exit=${EXIT_L},${EXIT_T} ${EXIT_W}x${EXIT_H} map=$TOUCH_MAP"

LAST_X=0
LAST_Y=0
HAVE_XY=0
TAPS=0
FIRST_TAP=0

while [ ! -f "$EXIT_FLAG" ]; do
    read_event || continue

    if [ "$TYPE" -eq 3 ]; then
        case "$CODE" in
            0|53) LAST_X=$VAL; HAVE_XY=1 ;;
            1|54) LAST_Y=$VAL; HAVE_XY=1 ;;
        esac
        continue
    fi

    # Contact lift: BTN_TOUCH released.
    if [ "$TYPE" -eq 1 ] && [ "$CODE" -eq 330 ] && [ "$VAL" -eq 0 ] && [ "$HAVE_XY" -eq 1 ]; then
        HAVE_XY=0
        map_to_fb
        _now=$(date +%s)
        if [ $((_now - FIRST_TAP)) -gt "$TAP_WINDOW" ]; then
            TAPS=1
            FIRST_TAP=$_now
        else
            TAPS=$((TAPS + 1))
        fi
        tlog "tap raw=${LAST_X},${LAST_Y} fb=${FBX},${FBY} count=$TAPS"

        hit_exit && request_exit "EXIT box"
        [ "$TAPS" -ge "$TAPS_TO_EXIT" ] && request_exit "${TAPS_TO_EXIT} taps"
    fi
done
exit 0
