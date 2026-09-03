#!/bin/sh
# Shared helpers. Sourced by start.sh and debug.sh. Kindle busybox ash.

EXT_DIR="${EXT_DIR:-/mnt/us/extensions/pw3clock}"
LOG="${LOG:-/mnt/us/pw3clock.log}"
STATUS="${STATUS:-/mnt/us/pw3clock-last.txt}"
# Scratch space for runtime state. Overridable so the desktop preview harness
# can run the same code without writing to the device paths.
PW3_TMP="${PW3_TMP:-/var/tmp}"
LOG2="${LOG2:-${PW3_TMP}/pw3clock.log}"
PIDFILE="${PIDFILE:-${PW3_TMP}/pw3clock.pid}"
WEATHER_CACHE="${WEATHER_CACHE:-${PW3_TMP}/pw3clock.weather}"
ROTATE_SAVE="${ROTATE_SAVE:-${PW3_TMP}/pw3clock.rotate}"
FBINK=""
HAVE_FBINK=0
GUI_STOPPED=0
FONT_BOLD=""
FONT_REG=""
FONT_MID=64
FONT_BASE=36
FONT_FLAP_MID=50
FONT_GRID=1
FONT_DATE_MUL=86
FONT_ADVANCE=50
VIEW_W=1072
VIEW_H=1448
ORIG_ROTATE=""
ROTATE_PATH=""
WEATHER_COND="NO DATA"
WEATHER_TEMP="--"
WEATHER_WIND="--"
WEATHER_FEELS="--"
WEATHER_HUM="--"
WEATHER_PRECIP="0"
WEATHER_HOURLY=""
WEATHER_RAIN_LABEL="RAIN"
WEATHER_RAIN="--"
WEATHER_RISE="--"
WEATHER_SET="--"
SHOW_AMPM=1
CLOCK_AMPM=""
NEW_ROTATE=""
USE_BITMAP=0
OT_FAILED=0
INK=BLACK
PAPER=WHITE
TOUCH_PID=""
EXIT_FLAG="${EXIT_FLAG:-${PW3_TMP}/pw3clock.STOP}"
EXIT_RECT="${EXIT_RECT:-${PW3_TMP}/pw3clock.exitrect}"
FBINFO="${FBINFO:-${PW3_TMP}/pw3clock.fbinfo}"
TOUCH_PIDFILE="${TOUCH_PIDFILE:-${PW3_TMP}/pw3clock.touchpid}"

log() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    { echo "$_msg" >> "$LOG"; } 2>/dev/null
    { echo "$_msg" >> "$LOG2"; } 2>/dev/null
}

# #region agent log
agent_dbg() {
    _hid=$1
    _loc=$2
    _msg=$3
    _data=$4
    _epoch=$(date +%s 2>/dev/null)
    [ -n "$_epoch" ] || _epoch=0
    _line=$(printf '{"sessionId":"322cbd","hypothesisId":"%s","location":"%s","message":"%s","data":%s,"timestamp":%s}\n' \
        "$_hid" "$_loc" "$_msg" "${_data:-{}}" "${_epoch}000")
    { echo "$_line" >> "$LOG"; } 2>/dev/null
    { echo "$_line" >> "$LOG2"; } 2>/dev/null
    if [ -n "${PW3_AGENT_LOG:-}" ]; then
        { echo "$_line" >> "$PW3_AGENT_LOG"; } 2>/dev/null
    fi
    { echo "$_line" >> "/Users/shreemit/Developer/Kindle/.cursor/debug-322cbd.log"; } 2>/dev/null
}

rtc_stamp() {
    if [ -r /sys/class/rtc/rtc1/since_epoch ]; then
        cat /sys/class/rtc/rtc1/since_epoch 2>/dev/null
    elif [ -r /sys/class/rtc/rtc0/since_epoch ]; then
        cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null
    else
        echo ""
    fi
}

# After STR the Linux clock drifts ahead of rtc1 (2–4 min overnight).
# Pull system time back from the RTC that actually ran during suspend.
sync_system_from_rtc() {
    _rtc=$(rtc_stamp)
    _sys=$(date +%s 2>/dev/null)
    [ -n "$_rtc" ] && [ -n "$_sys" ] || return 1
    _skew=$((_sys - _rtc))
    _abs=$_skew
    [ "$_abs" -lt 0 ] && _abs=$((-_abs))
    # #region agent log
    agent_dbg B "clock.sh:sync_system_from_rtc:before" "rtc vs sys before sync" \
        "{\"sys\":$_sys,\"rtc\":$_rtc,\"skew\":$_skew}"
    # #endregion
    # Ignore tiny jitter; refuse hour-scale jumps (would be TZ misuse).
    if [ "$_abs" -lt 2 ] || [ "$_abs" -gt 3600 ]; then
        return 0
    fi
    if date -s "@$_rtc" >/dev/null 2>&1; then
        :
    else
        hwclock -s -u -f /dev/rtc1 >/dev/null 2>&1 ||
            hwclock -s -u >/dev/null 2>&1
    fi
    _sys2=$(date +%s 2>/dev/null)
    _rtc2=$(rtc_stamp)
    _skew2=0
    if [ -n "$_sys2" ] && [ -n "$_rtc2" ]; then
        _skew2=$((_sys2 - _rtc2))
    fi
    log "synced system from rtc skew=${_skew}s now=${_skew2}s"
    # #region agent log
    agent_dbg B "clock.sh:sync_system_from_rtc:after" "rtc vs sys after sync" \
        "{\"sys\":${_sys2:-0},\"rtc\":\"$_rtc2\",\"skewBefore\":$_skew,\"skewAfter\":$_skew2}"
    # #endregion
}

try_ntp_sync() {
    command -v ntpdate >/dev/null 2>&1 || return 1
    _pre=$(date +%s 2>/dev/null)
    ntpdate -s pool.ntp.org >> "$LOG" 2>&1 || ntpdate -s time.nist.gov >> "$LOG" 2>&1 || return 1
    _post=$(date +%s 2>/dev/null)
    hwclock -w -u -f /dev/rtc1 >/dev/null 2>&1 || hwclock -w -u >/dev/null 2>&1
    log "ntpdate pre=$_pre post=$_post"
    # #region agent log
    agent_dbg E "clock.sh:try_ntp_sync" "ntpdate" \
        "{\"pre\":${_pre:-0},\"post\":${_post:-0}}"
    # #endregion
}
# #endregion

trim_log() {
    # The clock runs for days; keep the log from growing without bound.
    for _lf in "$LOG" "$LOG2"; do
        [ -f "$_lf" ] || continue
        _sz=$(wc -c < "$_lf" 2>/dev/null)
        [ -n "$_sz" ] || continue
        if [ "$_sz" -gt 262144 ]; then
            tail -200 "$_lf" > "${_lf}.trim" 2>/dev/null &&
                mv "${_lf}.trim" "$_lf" 2>/dev/null
        fi
    done
}

status() {
    echo "$*" > "$STATUS" 2>/dev/null
    log "STATUS: $*"
}

load_config() {
    if [ -f "${EXT_DIR}/config.sh" ]; then
        # shellcheck disable=SC1091
        . "${EXT_DIR}/config.sh"
    fi
    TIME_FORMAT="${TIME_FORMAT:-%I:%M}"
    # A 12-hour face needs an AM/PM marker; a 24-hour one does not.
    case "$TIME_FORMAT" in
        *%I*|*%l*) SHOW_AMPM=1 ;;
        *) SHOW_AMPM=0 ;;
    esac
    DATE_FORMAT="${DATE_FORMAT:-%a %d %b %Y}"
    DEBUG_SECONDS="${DEBUG_SECONDS:-20}"
    USE_SUSPEND="${USE_SUSPEND:-0}"
    WEATHER_CITY="${WEATHER_CITY:-}"
    WEATHER_LAT="${WEATHER_LAT:-47.62409}"
    WEATHER_LON="${WEATHER_LON:--122.33567}"
    WEATHER_WIFI="${WEATHER_WIFI:-1}"
    WEATHER_EVERY="${WEATHER_EVERY:-60}"
    FULL_REFRESH_EVERY="${FULL_REFRESH_EVERY:-60}"
    QUIET_START="${QUIET_START:-}"
    QUIET_END="${QUIET_END:-07:00}"
    QUIET_CLOCK_EVERY="${QUIET_CLOCK_EVERY:-5}"
    ROTATE="${ROTATE:-auto}"
    THEME="${THEME:-light}"
    TOUCH_MAP="${TOUCH_MAP:-1}"
    apply_theme
}

apply_theme() {
    if [ "$THEME" = "dark" ]; then
        INK=WHITE
        PAPER=BLACK
    else
        INK=BLACK
        PAPER=WHITE
    fi
    log "theme=$THEME ink=$INK paper=$PAPER"
}

try_fbink() {
    _bin="$1"
    [ -f "$_bin" ] || return 1
    chmod 755 "$_bin" 2>/dev/null
    _out=$("$_bin" -e 2>&1)
    _rc=$?
    log "fbink probe $_bin rc=$_rc"
    log "fbink -e: $_out"
    case "$_out" in
        *viewWidth*|*viewHeight*|*device_id*|*PaperWhite*|*fontname*)
            FBINK="$_bin"
            HAVE_FBINK=1
            return 0
            ;;
    esac
    if [ "$_rc" -eq 0 ]; then
        FBINK="$_bin"
        HAVE_FBINK=1
        return 0
    fi
    return 1
}

prepare_fbink() {
    HAVE_FBINK=0
    FBINK=""
    export FBINK_NO_SW_ROTA=1
    try_fbink "${EXT_DIR}/bin/fbink" && return 0

    if [ -f "${EXT_DIR}/bin/fbink" ]; then
        cp "${EXT_DIR}/bin/fbink" /var/tmp/pw3clock-fbink 2>/dev/null
        chmod 755 /var/tmp/pw3clock-fbink 2>/dev/null
        try_fbink /var/tmp/pw3clock-fbink && return 0
    fi

    for _cand in \
        /mnt/us/extensions/MRInstaller/bin/K5/fbink \
        /mnt/us/extensions/MRInstaller/bin/PW2/fbink \
        /mnt/us/koreader/fbink \
        /mnt/us/usbnet/bin/fbink \
        /var/tmp/fbink
    do
        try_fbink "$_cand" && return 0
    done

    log "No working fbink binary. Will use eips."
    return 1
}

pick_font() {
    FONT_MID=64
    FONT_BASE=36
    FONT_FLAP_MID=50
    FONT_GRID=1
    FONT_DATE_MUL=86
    FONT_ADVANCE=50

    FONT_BOLD="${EXT_DIR}/fonts/Jersey25-Regular.ttf"
    FONT_REG="${EXT_DIR}/fonts/Jersey25-Regular.ttf"
    if [ -f "$FONT_REG" ]; then
        # Jersey 25: tall pixel digits with clear 2/5/6 shapes.
        FONT_DATE_MUL=80
        FONT_ADVANCE=48
        FONT_GRID=4
        FONT_FLAP_MID=50
        log "Using bundled Jersey 25"
        return 0
    fi
    FONT_BOLD=""
    FONT_REG=""
    for _font in \
        /usr/java/lib/fonts/Amazon-Ember-Regular.ttf \
        /usr/java/lib/fonts/Palatino-Regular.ttf \
        /usr/java/lib/fonts/Caecilia_LT_65_Medium.ttf
    do
        if [ -f "$_font" ]; then
            FONT_BOLD="$_font"
            FONT_REG="$_font"
            log "Using fallback font $_font"
            return 0
        fi
    done
    log "No TTF found."
    return 1
}

read_fb_size() {
    _state=$("$FBINK" -e 2>/dev/null)
    VIEW_W=$(echo "$_state" | sed -n 's/.*viewWidth=\([0-9][0-9]*\).*/\1/p')
    VIEW_H=$(echo "$_state" | sed -n 's/.*viewHeight=\([0-9][0-9]*\).*/\1/p')
    if [ -z "$VIEW_W" ] || [ -z "$VIEW_H" ]; then
        VIEW_W=1072
        VIEW_H=1448
    fi
    log "fb view ${VIEW_W}x${VIEW_H}"
}

save_rotate() {
    for _p in \
        /sys/class/graphics/fb0/rotate \
        /sys/devices/platform/imx_epdc_fb/graphics/fb0/rotate \
        /sys/devices/platform/mxc_epdc_fb/graphics/fb0/rotate
    do
        if [ -r "$_p" ]; then
            ORIG_ROTATE=$(cat "$_p" 2>/dev/null)
            ROTATE_PATH="$_p"
            printf '%s\n%s\n' "$ROTATE_PATH" "$ORIG_ROTATE" > "$ROTATE_SAVE" 2>/dev/null
            log "saved rotate $ORIG_ROTATE from $_p"
            return 0
        fi
    done
    return 1
}

restore_rotate() {
    if [ -f "$ROTATE_SAVE" ]; then
        ROTATE_PATH=$(sed -n '1p' "$ROTATE_SAVE")
        ORIG_ROTATE=$(sed -n '2p' "$ROTATE_SAVE")
    fi
    if [ -n "$ROTATE_PATH" ] && [ -n "$ORIG_ROTATE" ] && [ -w "$ROTATE_PATH" ]; then
        echo "$ORIG_ROTATE" > "$ROTATE_PATH" 2>/dev/null
        log "restored rotate $ORIG_ROTATE"
        rm -f "$ROTATE_SAVE"
    fi
}

set_rotate() {
    _val="$1"
    [ -n "$ROTATE_PATH" ] && [ -w "$ROTATE_PATH" ] || return 1
    echo "$_val" > "$ROTATE_PATH" 2>/dev/null
    NEW_ROTATE="$_val"
    log "set rotate $_val"
}

current_rotate() {
    if [ -n "$ROTATE_PATH" ] && [ -r "$ROTATE_PATH" ]; then
        cat "$ROTATE_PATH" 2>/dev/null
        return 0
    fi
    echo "0"
}

write_fbinfo() {
    [ -n "$NEW_ROTATE" ] || NEW_ROTATE=$(current_rotate)
    [ -n "$ORIG_ROTATE" ] || ORIG_ROTATE=$NEW_ROTATE
    printf '%s %s %s %s\n' "$VIEW_W" "$VIEW_H" "$NEW_ROTATE" "$ORIG_ROTATE" > "$FBINFO" 2>/dev/null
    log "fbinfo ${VIEW_W}x${VIEW_H} rot $ORIG_ROTATE->$NEW_ROTATE"
}

setup_landscape() {
    _hw="$1"
    export FBINK_NO_SW_ROTA=1
    read_fb_size
    if [ "$VIEW_W" -gt "$VIEW_H" ]; then
        log "already landscape"
        save_rotate
        NEW_ROTATE=$(current_rotate)
        write_fbinfo
        return 0
    fi
    if [ "$_hw" != "1" ]; then
        log "skip hw rotate (GUI still running)"
        write_fbinfo
        return 0
    fi
    save_rotate
    if [ "$ROTATE" != "auto" ]; then
        set_rotate "$ROTATE"
        read_fb_size
        write_fbinfo
        return 0
    fi
    _r=0
    while [ "$_r" -le 3 ]; do
        set_rotate "$_r"
        read_fb_size
        if [ "$VIEW_W" -gt "$VIEW_H" ]; then
            log "landscape at rotate $_r"
            write_fbinfo
            return 0
        fi
        _r=$((_r + 1))
    done
    log "could not reach landscape"
    write_fbinfo
    return 1
}

get_battery() {
    _b=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    if [ -n "$_b" ]; then
        echo "$_b"
        return 0
    fi
    for _p in \
        /sys/devices/system/wario_battery/wario_battery0/battery_capacity \
        /sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity
    do
        if [ -f "$_p" ]; then
            cat "$_p"
            return 0
        fi
    done
    echo "?"
}

frontlight_off() {
    lipc-set-prop com.lab126.powerd flIntensity 0 >/dev/null 2>&1
    for _p in \
        /sys/devices/platform/imx-i2c.0/i2c-0/0-003c/max77696-bl.0/backlight/max77696-bl/brightness \
        /sys/class/backlight/max77696-bl/brightness \
        /sys/devices/system/fl_tps6116x/fl_tps6116x0/fl_intensity
    do
        if [ -w "$_p" ]; then
            echo 0 > "$_p" 2>/dev/null
        fi
    done
}

prevent_screensaver() {
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1
}

allow_screensaver() {
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
}

stop_gui() {
    log "Stopping Kindle GUI"
    if [ -d /etc/upstart ]; then
        stop lab126_gui >> "$LOG" 2>&1
        stop otaupd >> "$LOG" 2>&1
        stop phd >> "$LOG" 2>&1
        stop tmd >> "$LOG" 2>&1
        stop x >> "$LOG" 2>&1
    elif [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework stop >> "$LOG" 2>&1
    fi
    GUI_STOPPED=1
    sleep 1
}

start_gui() {
    log "Starting Kindle GUI"
    restore_rotate
    allow_screensaver
    if [ -d /etc/upstart ]; then
        start lab126_gui >> "$LOG" 2>&1
    elif [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework start >> "$LOG" 2>&1
    fi
    GUI_STOPPED=0
}

load_weather_cache() {
    if [ -f "$WEATHER_CACHE" ]; then
        WEATHER_COND=$(sed -n '1p' "$WEATHER_CACHE")
        WEATHER_TEMP=$(sed -n '2p' "$WEATHER_CACHE")
        WEATHER_WIND=$(sed -n '3p' "$WEATHER_CACHE")
        WEATHER_FEELS=$(sed -n '4p' "$WEATHER_CACHE")
        WEATHER_HUM=$(sed -n '5p' "$WEATHER_CACHE")
        WEATHER_PRECIP=$(sed -n '6p' "$WEATHER_CACHE")
        WEATHER_HOURLY=$(sed -n '7p' "$WEATHER_CACHE")
        WEATHER_RISE=$(sed -n '8p' "$WEATHER_CACHE")
        WEATHER_SET=$(sed -n '9p' "$WEATHER_CACHE")
        [ -n "$WEATHER_COND" ] || WEATHER_COND="NO DATA"
        [ -n "$WEATHER_TEMP" ] || WEATHER_TEMP="--"
        [ -n "$WEATHER_WIND" ] || WEATHER_WIND="--"
        [ -n "$WEATHER_FEELS" ] || WEATHER_FEELS="--"
        [ -n "$WEATHER_HUM" ] || WEATHER_HUM="--"
        [ -n "$WEATHER_PRECIP" ] || WEATHER_PRECIP="0"
        [ -n "$WEATHER_RISE" ] || WEATHER_RISE="--"
        [ -n "$WEATHER_SET" ] || WEATHER_SET="--"
    fi
    compute_seattle_rain
}

save_weather_cache() {
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$WEATHER_COND" "$WEATHER_TEMP" \
        "$WEATHER_WIND" "$WEATHER_FEELS" "$WEATHER_HUM" "$WEATHER_PRECIP" \
        "$WEATHER_HOURLY" "$WEATHER_RISE" "$WEATHER_SET" > "$WEATHER_CACHE" 2>/dev/null
}

wifi_state() {
    lipc-get-prop com.lab126.wifid cmState 2>/dev/null
}

enable_wifi() {
    lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1
}

disable_wifi() {
    lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
}

wait_wifi() {
    _n=0
    while [ "$_n" -lt 12 ]; do
        if [ "$(wifi_state)" = "CONNECTED" ]; then
            return 0
        fi
        sleep 1
        _n=$((_n + 1))
    done
    return 1
}

weather_city_path() {
    echo "$WEATHER_CITY" | sed 's/ /+/g'
}

weather_url_om() {
    _proto=${1:-https}
    echo "${_proto}://api.open-meteo.com/v1/forecast?latitude=${WEATHER_LAT}&longitude=${WEATHER_LON}&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,cloud_cover,wind_speed_10m,wind_direction_10m&minutely_15=precipitation,weather_code&forecast_minutely_15=48&daily=sunrise,sunset&forecast_days=1&timezone=auto&timeformat=unixtime&wind_speed_unit=kmh"
}

weather_url_j1() {
    _city=$(weather_city_path)
    if [ -n "$_city" ]; then
        echo "http://wttr.in/${_city}?m&format=j1"
    else
        echo "http://wttr.in/?m&format=j1"
    fi
}

weather_url() {
    _city=$(weather_city_path)
    # cond | temp | wind | feels-like | humidity | precip mm
    if [ -n "$_city" ]; then
        echo "http://wttr.in/${_city}?m&format=%C|%t|%w|%f|%h|%p|%S|%s"
    else
        echo "http://wttr.in/?m&format=%C|%t|%w|%f|%h|%p|%S|%s"
    fi
}

round_weather_num() {
    awk -v n="$1" 'BEGIN {
        if (n == "" || n+0 != n) { print n; exit }
        if (n >= 0) printf "%d", n + 0.5
        else printf "%d", n - 0.5
    }'
}

deg_to_compass() {
    _deg=$(round_weather_num "$1")
    case "$_deg" in
        ''|*[!0-9-]*) echo ""; return 0 ;;
    esac
    _i=$(( ((_deg + 11) * 2 / 45) % 16 ))
    [ "$_i" -lt 0 ] && _i=$((_i + 16))
    set -- N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW
    eval "echo \${$((_i + 1))}"
}

wmo_to_cond() {
    case "$1" in
        0|1) echo CLEAR ;;
        2) echo CLOUDY ;;
        3) echo OVERCAST ;;
        45|48) echo FOG ;;
        51|53|55|56|57) echo DRIZZLE ;;
        61|63|65|66|67) echo RAIN ;;
        71|73|75|77|85|86) echo SNOW ;;
        80|81|82) echo SHOWERS ;;
        95|96|99) echo THUNDER ;;
        *) echo CLOUDY ;;
    esac
}

epoch_fmt() {
    _ep=$1
    _fo=$2
    _out=$(date -d "@$_ep" +"$_fo" 2>/dev/null) && [ -n "$_out" ] && { echo "$_out"; return 0; }
    _out=$(date -r "$_ep" +"$_fo" 2>/dev/null) && [ -n "$_out" ] && { echo "$_out"; return 0; }
    _out=$(date -D '%s' -d "$_ep" +"$_fo" 2>/dev/null) && [ -n "$_out" ] && { echo "$_out"; return 0; }
    echo ""
    return 1
}

precip_ge_tenth() {
    awk -v p="$1" 'BEGIN { exit (p + 0 >= 0.1) ? 0 : 1 }'
}

wmo_is_drizzle() {
    case "$1" in
        51|53|55|56|57) return 0 ;;
        *) return 1 ;;
    esac
}

wmo_is_rain() {
    case "$1" in
        51|53|55|56|57|61|63|65|66|67|80|81|82|95|96|99) return 0 ;;
        *) return 1 ;;
    esac
}

fmt_sun_short() {
    _s=$(echo "$1" | tr 'a-z' 'A-Z')
    case "$_s" in
        ''|--|"NO SUNRISE"|"NO SUNSET"|"NO DATA") echo "--" ;;
        *) echo "$_s" | sed 's/^0//;s/ //g' ;;
    esac
}

fmt_wind_short() {
    echo "$WEATHER_WIND" | tr 'a-z' 'A-Z' | sed 's/KM\/H/K/;s/KMH/K/;s/  */ /g;s/ K/K/'
}

board_date_parts() {
    # "Mon 17 Aug 2026" -> DATE_PRI="SUN 17 AUG" DATE_YEAR="2026"
    DATE_YEAR=$(echo "$1" | awk '{print $NF}')
    DATE_PRI=$(echo "$1" | awk '{
        n=NF
        if (n >= 4) printf "%s %s %s", $1, $(n-2), $(n-1)
        else if (n >= 3) printf "%s %s", $(n-2), $(n-1)
        else print $0
    }' | tr 'a-z' 'A-Z' | sed 's/ 0/ /;s/^0//')
}

json_first() {
    # First "key": "value" in pretty or compact JSON.
    awk -F'"' -v k="$1" '$2==k { print $4; exit }'
}

dezero() {
    _z=$1
    _z=${_z#0}
    [ -n "$_z" ] || _z=0
    echo "$_z"
}

fmt_rain_hour() {
    # wttr hourly time is 0, 300, 900, 1500, ...
    _rh=$(($1 / 100))
    if [ "$SHOW_AMPM" = "1" ]; then
        if [ "$_rh" -eq 0 ]; then
            echo "12AM"
        elif [ "$_rh" -lt 12 ]; then
            echo "${_rh}AM"
        elif [ "$_rh" -eq 12 ]; then
            echo "12PM"
        else
            echo "$((_rh - 12))PM"
        fi
    else
        printf '%02d:00' "$_rh"
    fi
}

fmt_rain_in() {
    _m=$1
    if [ "$_m" -le 15 ]; then
        echo "15M"
    elif [ "$_m" -le 30 ]; then
        echo "30M"
    elif [ "$_m" -le 45 ]; then
        echo "45M"
    elif [ "$_m" -le 60 ]; then
        echo "1H"
    elif [ "$_m" -le 75 ]; then
        echo "1H15"
    elif [ "$_m" -le 90 ]; then
        echo "1H30"
    elif [ "$_m" -le 105 ]; then
        echo "1H45"
    else
        echo "2H"
    fi
}

fmt_ampm_clock() {
    _h=$1
    _m=$2
    _h=$(dezero "$_h")
    _m=$(dezero "$_m")
    if [ "$_h" -eq 0 ]; then
        _ap=12
        _suf=AM
    elif [ "$_h" -lt 12 ]; then
        _ap=$_h
        _suf=AM
    elif [ "$_h" -eq 12 ]; then
        _ap=12
        _suf=PM
    else
        _ap=$((_h - 12))
        _suf=PM
    fi
    if [ "$_m" -eq 0 ]; then
        echo "${_ap}${_suf}"
    else
        printf '%d:%02d%s' "$_ap" "$_m" "$_suf"
    fi
}

fmt_rain_at_epoch() {
    # Hour only — drop :15 so 6:15PM and 6:00PM both read 6PM.
    _h=$(epoch_fmt "$1" '%H')
    [ -n "$_h" ] || { echo "--"; return 0; }
    if [ "$SHOW_AMPM" = "1" ]; then
        fmt_ampm_clock "$_h" 0
    else
        printf '%02d:00' "$(dezero "$_h")"
    fi
}

compute_seattle_rain() {
    # Seattle-specific: rain now, drizzle, rain-in / rain-at, or dry sky.
    WEATHER_RAIN_LABEL="DRY"
    WEATHER_RAIN="CLEAR"
    _cond=$WEATHER_COND
    case "$_cond" in
        *DRIZZLE*)
            WEATHER_RAIN_LABEL="DRIZZLE"
            WEATHER_RAIN="NOW"
            return 0
            ;;
        *RAIN*|*SHOWER*|*THUNDER*|*STORM*)
            WEATHER_RAIN_LABEL="RAIN"
            WEATHER_RAIN="NOW"
            return 0
            ;;
    esac
    if precip_ge_tenth "$WEATHER_PRECIP"; then
        WEATHER_RAIN_LABEL="RAIN"
        WEATHER_RAIN="NOW"
        return 0
    fi

    _now=$(date +%s 2>/dev/null)
    [ -n "$_now" ] || _now=0
    _nowh=$(dezero "$(date +%H 2>/dev/null)")
    _nowm=$(dezero "$(date +%M 2>/dev/null)")
    _nowx=$((_nowh * 100 + _nowm))
    _next=""
    _next_kind=""
    for _pair in $WEATHER_HOURLY; do
        _t=${_pair%%:*}
        _rest=${_pair#*:}
        _p=${_rest%%:*}
        _code=${_rest#*:}
        [ "$_code" = "$_rest" ] && _code=""
        case "$_t" in
            ''|*[!0-9]*) continue ;;
        esac
        # Open-Meteo: unix:mm or unix:mm:wmo. wttr: HHMM:chance (time <= 2400).
        if [ "$_t" -gt 2400 ]; then
            [ "$_t" -gt "$_now" ] || continue
            if precip_ge_tenth "$_p" || wmo_is_rain "$_code"; then
                _next=$_t
                _next_kind=om
                break
            fi
        else
            case "$_p" in
                ''|*[!0-9]*) continue ;;
            esac
            if [ "$_t" -gt "$_nowx" ] && [ "$_p" -ge 40 ]; then
                _next=$_t
                _next_kind=wttr
                break
            fi
        fi
    done
    if [ -n "$_next" ]; then
        if [ "$_next_kind" = "om" ]; then
            _mins=$(( (_next - _now + 59) / 60 ))
            if [ "$_mins" -le 120 ]; then
                WEATHER_RAIN_LABEL="RAIN IN"
                WEATHER_RAIN=$(fmt_rain_in "$_mins")
            else
                WEATHER_RAIN_LABEL="RAIN AT"
                WEATHER_RAIN=$(fmt_rain_at_epoch "$_next")
            fi
        else
            WEATHER_RAIN_LABEL="RAIN AT"
            WEATHER_RAIN=$(fmt_rain_hour "$_next")
        fi
        return 0
    fi
    case "$_cond" in
        *CLOUD*|*OVERCAST*|*FOG*|*MIST*)
            WEATHER_RAIN_LABEL="DRY"
            WEATHER_RAIN="CLDY"
            ;;
        *)
            WEATHER_RAIN_LABEL="DRY"
            WEATHER_RAIN="CLEAR"
            ;;
    esac
}

parse_wttr_j1() {
    _jfile=$1
    [ -s "$_jfile" ] || return 1
    _cond=$(json_first value < "$_jfile")
    _temp=$(json_first temp_C < "$_jfile")
    _feels=$(json_first FeelsLikeC < "$_jfile")
    _hum=$(json_first humidity < "$_jfile")
    _wspd=$(json_first windspeedKmph < "$_jfile")
    _wdir=$(json_first winddir16Point < "$_jfile")
    _precip=$(json_first precipMM < "$_jfile")
    _rise=$(json_first sunrise < "$_jfile")
    _set=$(json_first sunset < "$_jfile")
    [ -n "$_temp" ] || return 1
    WEATHER_COND=$(echo "$_cond" | tr 'a-z' 'A-Z')
    [ -n "$WEATHER_COND" ] || WEATHER_COND="NO DATA"
    WEATHER_TEMP="${_temp}°C"
    WEATHER_FEELS="${_feels}°C"
    WEATHER_HUM="${_hum}%"
    WEATHER_WIND=$(echo "${_wspd}KMH ${_wdir}" | tr 'a-z' 'A-Z')
    WEATHER_PRECIP=${_precip:-0}
    WEATHER_RISE=$(fmt_sun_short "$_rise")
    WEATHER_SET=$(fmt_sun_short "$_set")
    WEATHER_HOURLY=$(awk -F'"' '
        $2=="time" && $4 ~ /^[0-9]+$/ { times[++nt]=$4 }
        $2=="chanceofrain" { rains[++nr]=$4 }
        END {
            n=nr
            if (n > 8) n=8
            for (i = 1; i <= n; i++) {
                printf "%s:%s%s", times[i], rains[i], (i < n ? " " : "")
            }
        }
    ' "$_jfile")
    [ -n "$WEATHER_WIND" ] || WEATHER_WIND="--"
    [ -n "$WEATHER_FEELS" ] || WEATHER_FEELS="--"
    [ -n "$WEATHER_HUM" ] || WEATHER_HUM="--"
    compute_seattle_rain
    return 0
}

parse_open_meteo() {
    _jfile=$1
    [ -s "$_jfile" ] || return 1
    _parsed=$(awk '
        function needle(key) { return "\"" key "\":" }
        function grab_obj(s, key,   i, n) {
            n = needle(key) "{"
            i = index(s, n)
            if (i == 0) return ""
            return substr(s, i + length(n) - 1)
        }
        function grab_arr(s, key,   i, n, r, j, ch, depth, out) {
            n = needle(key) "["
            i = index(s, n)
            if (i == 0) return ""
            r = substr(s, i + length(n))
            out = ""
            depth = 1
            for (j = 1; j <= length(r); j++) {
                ch = substr(r, j, 1)
                if (ch == "[") depth++
                if (ch == "]") {
                    depth--
                    if (depth == 0) break
                }
                out = out ch
            }
            return out
        }
        function num(s, key,   i, n, r, j, ch, out) {
            n = needle(key)
            i = index(s, n)
            if (i == 0) return ""
            r = substr(s, i + length(n))
            while (substr(r, 1, 1) == " ") r = substr(r, 2)
            out = ""
            for (j = 1; j <= length(r); j++) {
                ch = substr(r, j, 1)
                if (ch ~ /[0-9.eE+-]/) out = out ch
                else break
            }
            return out
        }
        {
            json = json $0
        }
        END {
            gsub(/[ \t\r\n]/, "", json)
            cur = grab_obj(json, "current")
            if (cur == "") exit 1
            temp = num(cur, "temperature_2m")
            if (temp == "") exit 1
            print temp
            print num(cur, "apparent_temperature")
            print num(cur, "relative_humidity_2m")
            print num(cur, "precipitation")
            print num(cur, "weather_code")
            print num(cur, "cloud_cover")
            print num(cur, "wind_speed_10m")
            print num(cur, "wind_direction_10m")
            print grab_arr(json, "time")
            print grab_arr(json, "precipitation")
            print grab_arr(json, "weather_code")
            print grab_arr(json, "sunrise")
            print grab_arr(json, "sunset")
        }
    ' "$_jfile") || return 1
    [ -n "$_parsed" ] || return 1
    _temp=$(printf '%s\n' "$_parsed" | sed -n '1p')
    _feels=$(printf '%s\n' "$_parsed" | sed -n '2p')
    _hum=$(printf '%s\n' "$_parsed" | sed -n '3p')
    _precip=$(printf '%s\n' "$_parsed" | sed -n '4p')
    _wmo=$(printf '%s\n' "$_parsed" | sed -n '5p')
    _cloud=$(printf '%s\n' "$_parsed" | sed -n '6p')
    _wspd=$(printf '%s\n' "$_parsed" | sed -n '7p')
    _wdir=$(printf '%s\n' "$_parsed" | sed -n '8p')
    _times=$(printf '%s\n' "$_parsed" | sed -n '9p')
    _precs=$(printf '%s\n' "$_parsed" | sed -n '10p')
    _codes=$(printf '%s\n' "$_parsed" | sed -n '11p')
    _rise_e=$(printf '%s\n' "$_parsed" | sed -n '12p' | awk -F',' '{print $1}')
    _set_e=$(printf '%s\n' "$_parsed" | sed -n '13p' | awk -F',' '{print $1}')
    [ -n "$_temp" ] || return 1

    _temp=$(round_weather_num "$_temp")
    _feels=$(round_weather_num "$_feels")
    _wspd=$(round_weather_num "$_wspd")
    _wmo=$(round_weather_num "$_wmo")
    _cloud=$(round_weather_num "$_cloud")
    [ -n "$_cloud" ] || _cloud=0
    _compass=$(deg_to_compass "$_wdir")

    WEATHER_COND=$(wmo_to_cond "$_wmo")
    if precip_ge_tenth "$_precip" || wmo_is_rain "$_wmo"; then
        if wmo_is_drizzle "$_wmo"; then
            WEATHER_COND="DRIZZLE"
        elif [ "$WEATHER_COND" = "DRIZZLE" ] || [ "$WEATHER_COND" = "SHOWERS" ] || [ "$WEATHER_COND" = "THUNDER" ] || [ "$WEATHER_COND" = "RAIN" ] || [ "$WEATHER_COND" = "SNOW" ]; then
            :
        else
            WEATHER_COND="RAIN"
        fi
    elif [ "${_cloud:-0}" -ge 60 ]; then
        case "$WEATHER_COND" in
            CLEAR) WEATHER_COND="OVERCAST" ;;
        esac
    fi
    [ -n "$WEATHER_COND" ] || WEATHER_COND="NO DATA"
    WEATHER_TEMP="${_temp}°C"
    WEATHER_FEELS="${_feels}°C"
    WEATHER_HUM="${_hum}%"
    WEATHER_WIND=$(echo "${_wspd}KMH ${_compass}" | tr 'a-z' 'A-Z')
    WEATHER_PRECIP=${_precip:-0}
    _rise_s=$(epoch_fmt "$_rise_e" '%l:%M%p')
    [ -n "$_rise_s" ] || _rise_s=$(epoch_fmt "$_rise_e" '%I:%M%p')
    _set_s=$(epoch_fmt "$_set_e" '%l:%M%p')
    [ -n "$_set_s" ] || _set_s=$(epoch_fmt "$_set_e" '%I:%M%p')
    WEATHER_RISE=$(fmt_sun_short "$_rise_s")
    WEATHER_SET=$(fmt_sun_short "$_set_s")
    WEATHER_HOURLY=$(awk -v times="$_times" -v precs="$_precs" -v codes="$_codes" '
        BEGIN {
            nt = split(times, ta, ",")
            np = split(precs, pa, ",")
            nc = split(codes, ca, ",")
            n = nt
            if (np < n) n = np
            if (n > 48) n = 48
            for (i = 1; i <= n; i++) {
                t = ta[i]; p = pa[i]; c = ca[i]
                gsub(/^[ \t]+|[ \t]+$/, "", t)
                gsub(/^[ \t]+|[ \t]+$/, "", p)
                gsub(/^[ \t]+|[ \t]+$/, "", c)
                if (t == "") continue
                if (p == "") p = "0"
                if (c == "") printf "%s:%s%s", t, p, (i < n ? " " : "")
                else printf "%s:%s:%s%s", t, p, c, (i < n ? " " : "")
            }
        }
    ')
    [ -n "$WEATHER_WIND" ] || WEATHER_WIND="--"
    [ -n "$WEATHER_FEELS" ] || WEATHER_FEELS="--"
    [ -n "$WEATHER_HUM" ] || WEATHER_HUM="--"
    compute_seattle_rain
    return 0
}

http_get() {
    _url=$1
    _timeout=${2:-8}
    _body=""
    if command -v curl >/dev/null 2>&1; then
        _body=$(curl -s -L -f -m "$_timeout" -A "pw3clock/1.0" "$_url" 2>/dev/null)
    fi
    if [ -z "$_body" ] && command -v wget >/dev/null 2>&1; then
        _body=$(wget -q -T "$_timeout" -U "pw3clock/1.0" -O - "$_url" 2>/dev/null)
    fi
    printf '%s' "$_body"
}

fetch_weather() {
    _jfile="${PW3_TMP}/pw3clock.om"
    for _proto in https http; do
        _url=$(weather_url_om "$_proto")
        _raw=$(http_get "$_url" 15)
        printf '%s\n' "$_raw" > "$_jfile" 2>/dev/null
        log "weather om bytes=$(wc -c < "$_jfile" 2>/dev/null) url=$_url"
        if parse_open_meteo "$_jfile"; then
            rm -f "$_jfile"
            save_weather_cache
            log "weather om cond=$WEATHER_COND temp=$WEATHER_TEMP rain=$WEATHER_RAIN_LABEL $WEATHER_RAIN hourly=$WEATHER_HOURLY"
            return 0
        fi
        rm -f "$_jfile"
    done

    _jfile="${PW3_TMP}/pw3clock.wttr"
    _url=$(weather_url_j1)
    _raw=$(http_get "$_url" 15)
    printf '%s\n' "$_raw" > "$_jfile" 2>/dev/null
    log "weather j1 bytes=$(wc -c < "$_jfile" 2>/dev/null) url=$_url"
    if parse_wttr_j1 "$_jfile"; then
        rm -f "$_jfile"
        save_weather_cache
        log "weather j1 cond=$WEATHER_COND temp=$WEATHER_TEMP rain=$WEATHER_RAIN_LABEL $WEATHER_RAIN hourly=$WEATHER_HOURLY"
        return 0
    fi
    rm -f "$_jfile"

    _url=$(weather_url)
    _raw=$(http_get "$_url" 8)
    log "weather pipe raw=$_raw url=$_url"
    case "$_raw" in
        *"|"*)
            WEATHER_COND=$(echo "$_raw" | awk -F'|' '{print $1}' | tr 'a-z' 'A-Z')
            WEATHER_TEMP=$(echo "$_raw" | awk -F'|' '{print $2}' | sed 's/^+//')
            WEATHER_WIND=$(echo "$_raw" | awk -F'|' '{print $3}' | tr 'a-z' 'A-Z')
            WEATHER_FEELS=$(echo "$_raw" | awk -F'|' '{print $4}' | sed 's/^+//')
            WEATHER_HUM=$(echo "$_raw" | awk -F'|' '{print $5}')
            WEATHER_PRECIP=$(echo "$_raw" | awk -F'|' '{print $6}' | sed 's/mm//;s/MM//;s/ //g')
            WEATHER_RISE=$(fmt_sun_short "$(echo "$_raw" | awk -F'|' '{print $7}')")
            WEATHER_SET=$(fmt_sun_short "$(echo "$_raw" | awk -F'|' '{print $8}')")
            WEATHER_HOURLY=""
            [ -n "$WEATHER_COND" ] || WEATHER_COND="NO DATA"
            [ -n "$WEATHER_TEMP" ] || WEATHER_TEMP="--"
            [ -n "$WEATHER_WIND" ] || WEATHER_WIND="--"
            [ -n "$WEATHER_FEELS" ] || WEATHER_FEELS="--"
            [ -n "$WEATHER_HUM" ] || WEATHER_HUM="--"
            [ -n "$WEATHER_PRECIP" ] || WEATHER_PRECIP="0"
            compute_seattle_rain
            save_weather_cache
            return 0
            ;;
    esac
    return 1
}

update_weather() {
    load_weather_cache
    _st=$(wifi_state)
    if [ "$_st" != "CONNECTED" ]; then
        if [ "$WEATHER_WIFI" != "1" ]; then
            log "wifi down, skip weather"
            return 1
        fi
        enable_wifi
        if ! wait_wifi; then
            log "wifi wait failed"
            disable_wifi
            return 1
        fi
    fi
    # #region agent log
    _pre_ntp=$(date '+%H:%M:%S' 2>/dev/null)
    _pre_epoch=$(date +%s 2>/dev/null)
    # #endregion
    try_ntp_sync
    fetch_weather
    _rc=$?
    # #region agent log
    _post_ntp=$(date '+%H:%M:%S' 2>/dev/null)
    _post_epoch=$(date +%s 2>/dev/null)
    agent_dbg E "clock.sh:update_weather" "after wifi weather" \
        "{\"pre\":\"$_pre_ntp\",\"post\":\"$_post_ntp\",\"preEpoch\":${_pre_epoch:-0},\"postEpoch\":${_post_epoch:-0},\"rc\":$_rc}"
    # #endregion
    # Always drop the radio after a fetch — leaving WiFi up drains the pack.
    disable_wifi
    return $_rc
}

# "03:00" -> minutes since midnight. Empty or bad input -> -1.
hm_to_minutes() {
    case "$1" in
        [0-9]:[0-9][0-9]|[0-1][0-9]:[0-9][0-9]|2[0-3]:[0-9][0-9])
            _hh=${1%%:*}
            _mm=${1##*:}
            _hh=$(dezero "$_hh")
            _mm=$(dezero "$_mm")
            echo $((_hh * 60 + _mm))
            ;;
        *)
            echo -1
            ;;
    esac
}

now_minutes() {
    _hh=$(dezero "$(date +%H 2>/dev/null)")
    _mm=$(dezero "$(date +%M 2>/dev/null)")
    echo $((_hh * 60 + _mm))
}

is_quiet_hours() {
    [ -n "$QUIET_START" ] || return 1
    _qs=$(hm_to_minutes "$QUIET_START")
    _qe=$(hm_to_minutes "$QUIET_END")
    [ "$_qs" -ge 0 ] && [ "$_qe" -ge 0 ] || return 1
    _n=$(now_minutes)
    if [ "$_qs" -le "$_qe" ]; then
        [ "$_n" -ge "$_qs" ] && [ "$_n" -lt "$_qe" ]
    else
        # Window wraps midnight, e.g. 23:00–07:00.
        [ "$_n" -ge "$_qs" ] || [ "$_n" -lt "$_qe" ]
    fi
}

# Minutes between clock draws: quiet interval, otherwise 1.
clock_interval_minutes() {
    if is_quiet_hours; then
        _qi=${QUIET_CLOCK_EVERY:-5}
        case "$_qi" in
            ''|*[!0-9]*|0) echo 5 ;;
            *) echo "$_qi" ;;
        esac
    else
        echo 1
    fi
}

fill_rect() {
    # color top left w h
    "$FBINK" -q -b -B "$1" -k "top=$2,left=$3,width=$4,height=$5"
}

outline_rect() {
    # top left w h thickness
    _ot=$1
    _ol=$2
    _ow=$3
    _oh=$4
    _oth=$5
    fill_rect "$INK" "$_ot" "$_ol" "$_ow" "$_oh"
    _it=$((_ot + _oth))
    _il=$((_ol + _oth))
    _iw=$((_ow - _oth - _oth))
    _ih=$((_oh - _oth - _oth))
    if [ "$_iw" -gt 4 ] && [ "$_ih" -gt 4 ]; then
        fill_rect "$PAPER" "$_it" "$_il" "$_iw" "$_ih"
    fi
}

print_bitmap() {
    # Built-in bitmap font. Positions are computed by hand rather than using
    # -m, because -m centres across the whole screen and would pile every
    # centred string into the middle of the board.
    _bpx="$1"
    _btop="$2"
    _bleft="$3"
    _bright="$4"
    _btext="$5"
    _bcenter="$6"

    _bmult=$((_bpx / 8))
    [ "$_bmult" -lt 1 ] && _bmult=1
    [ "$_bmult" -gt 16 ] && _bmult=16
    _bx=$_bleft
    if [ "$_bcenter" = "1" ]; then
        _bcw=$((8 * _bmult))
        _bw=$((${#_btext} * _bcw))
        _bbox=$((VIEW_W - _bleft - _bright))
        _bx=$((_bleft + (_bbox - _bw) / 2))
        [ "$_bx" -lt 0 ] && _bx=0
    fi
    # "--" stops option parsing: strings like "---" or a negative temperature
    # would otherwise be read as flags.
    "$FBINK" -q -b -C "$INK" -B "$PAPER" -O -S "$_bmult" \
        -y 0 -Y "$_btop" -x 0 -X "$_bx" -- "$_btext" 2>/dev/null
}

print_ot() {
    # font pixels top left right text [centered]
    # Text is laid out downward from the top margin, so only `top` positions it.
    # The bottom margin must leave room for the full line height (~1.3x the em
    # size), not just the em size, or FBInk refuses to render anything.
    _pfont="$1"
    _ppx="$2"
    _ptop="$3"
    _pleft="$4"
    _pright="$5"
    _ptext="$6"
    _pcenter="$7"

    if [ "${FONT_GRID:-1}" -gt 1 ]; then
        _ppx=$(( (_ppx + FONT_GRID / 2) / FONT_GRID * FONT_GRID ))
        [ "$_ppx" -lt "$FONT_GRID" ] && _ppx=$FONT_GRID
    fi

    [ "$_ptop" -lt 0 ] && _ptop=0
    [ "$_pleft" -lt 0 ] && _pleft=0
    [ "$_pright" -lt 0 ] && _pright=0
    if [ $((_ptop + _ppx + _ppx / 2)) -ge "$VIEW_H" ]; then
        _ptop=$((VIEW_H - _ppx - _ppx / 2))
        [ "$_ptop" -lt 0 ] && _ptop=0
    fi
    if [ $((_pleft + _pright)) -ge "$VIEW_W" ]; then
        _pright=0
    fi

    if [ "$USE_BITMAP" = "1" ] || [ -z "$_pfont" ]; then
        print_bitmap "$_ppx" "$_ptop" "$_pleft" "$_pright" "$_ptext" "$_pcenter"
        return 0
    fi

    _palign=""
    [ "$_pcenter" = "1" ] && _palign="-m"

    # px= is pixels. size= is points, which at 300dpi overshoots the panel.
    # "--" stops option parsing so text beginning with a dash is not read as
    # a flag; FBInk answers those by dumping its entire usage text.
    _perr=$("$FBINK" -q -b -C "$INK" -B "$PAPER" -O $_palign \
        -t "regular=${_pfont},px=${_ppx},top=${_ptop},bottom=0,left=${_pleft},right=${_pright}" \
        -- "$_ptext" 2>&1)
    _prc=$?
    if [ "$_prc" -ne 0 ]; then
        # Degrade only this string. Switching the whole board to the bitmap
        # font would redraw over everything that rendered correctly.
        # Keep one line: FBInk answers a bad argument with its whole usage text.
        OT_FAILED=1
        log "print failed px=$_ppx t=$_ptop l=$_pleft r=$_pright text='$_ptext' err=$(echo "$_perr" | head -1)"
        print_bitmap "$_ppx" "$_ptop" "$_pleft" "$_pright" "$_ptext" "$_pcenter"
    fi
    return 0
}

print_ot_fit() {
    # Same args as print_ot. Shrinks px until the string fits left..right.
    _ffont="$1"
    _fpx="$2"
    _ftop="$3"
    _fl="$4"
    _fr="$5"
    _ftxt="$6"
    _fc="$7"
    _fbox=$((VIEW_W - _fl - _fr))
    _fadv=${FONT_ADVANCE:-50}
    _fneed=$(( ${#_ftxt} * _fpx * _fadv / 100 ))
    while [ "$_fneed" -gt "$_fbox" ] && [ "$_fpx" -gt 36 ]; do
        _fpx=$((_fpx - 8))
        _fneed=$(( ${#_ftxt} * _fpx * _fadv / 100 ))
    done
    print_ot "$_ffont" "$_fpx" "$_ftop" "$_fl" "$_fr" "$_ftxt" "$_fc"
}

draw_flap() {
    # left top w h digit
    _fl=$1
    _ft=$2
    _fw=$3
    _fh=$4
    _fd="$5"
    outline_rect "$_ft" "$_fl" "$_fw" "$_fh" 3
    _dsize=$((_fh * 75 / 100))
    # Optical centre of the digit, not the em square, on the hinge line.
    _dtop=$((_ft + _fh / 2 - _dsize * FONT_FLAP_MID / 100))
    [ "$_dtop" -lt "$_ft" ] && _dtop=$_ft
    _dleft=$_fl
    _dright=$((VIEW_W - _fl - _fw))
    print_ot "$FONT_BOLD" "$_dsize" "$_dtop" "$_dleft" "$_dright" "$_fd" 1
    _mid=$((_ft + _fh / 2))
    fill_rect "$INK" "$_mid" "$_fl" "$_fw" 2
}

draw_battery() {
    # left top w h percent — bar with nub, percentage printed to its left.
    _btl=$1
    _btt=$2
    _btw=$3
    _bth=$4
    _btp=$5
    case "$_btp" in
        ''|*[!0-9]*) _btp=0 ;;
    esac
    [ "$_btp" -gt 100 ] && _btp=100

    _bpct="${_btp}%"
    _bp_size=$((_bth * 72 / 100))
    [ "$_bp_size" -lt 28 ] && _bp_size=28
    # Room for up to "100%" left of the icon.
    _bp_w=$((_bp_size * 30 / 10))
    _bp_gap=14
    _bp_l=$((_btl - _bp_gap - _bp_w))
    [ "$_bp_l" -lt 0 ] && _bp_l=0
    _bp_top=$((_btt + _bth / 2 - _bp_size * FONT_MID / 100))
    [ "$_bp_top" -lt 0 ] && _bp_top=0
    print_ot "$FONT_BOLD" "$_bp_size" "$_bp_top" \
        "$_bp_l" $((VIEW_W - _btl + _bp_gap)) "$_bpct" 1

    outline_rect "$_btt" "$_btl" "$_btw" "$_bth" 3
    # Terminal nub, so it reads as a battery rather than a progress bar.
    fill_rect "$INK" $((_btt + _bth / 3)) $((_btl + _btw)) 10 $((_bth / 3))
    _btfill=$(((_btw - 18) * _btp / 100))
    if [ "$_btfill" -gt 0 ]; then
        fill_rect "$INK" $((_btt + 9)) $((_btl + 9)) "$_btfill" $((_bth - 18))
    fi
}

draw_colon() {
    # left top w h
    _cl=$1
    _ct=$2
    _cw=$3
    _ch=$4
    _sq=$((_ch * 8 / 100))
    [ "$_sq" -lt 10 ] && _sq=12
    _cx=$((_cl + (_cw - _sq) / 2))
    _cy1=$((_ct + _ch * 34 / 100))
    _cy2=$((_ct + _ch * 56 / 100))
    fill_rect "$INK" "$_cy1" "$_cx" "$_sq" "$_sq"
    fill_rect "$INK" "$_cy2" "$_cx" "$_sq" "$_sq"
}

draw_airport() {
    _time="$1"
    _date="$2"
    _bat="$3"
    _full="$4"
    W=$VIEW_W
    H=$VIEW_H

    if [ "$_full" = "1" ]; then
        "$FBINK" -q -b -c -f -C "$INK" -B "$PAPER"
    else
        "$FBINK" -q -b -c -C "$INK" -B "$PAPER"
    fi
    fill_rect "$PAPER" 0 0 "$W" "$H"

    OT_FAILED=0
    board_date_parts "$_date"
    _margin=48
    _hint_h=34
    _gap_v=16
    _box_h=$((H * 36 / 100))
    [ "$_box_h" -lt 300 ] && _box_h=300

    _bat_w=130
    _bat_h=48
    # Leave room left of the icon for "100%" (drawn inside draw_battery).
    _bat_pct_room=$((_bat_h * 72 / 100 * 30 / 10 + 14))
    _bat_l=$((W - _margin - _bat_w))
    _bat_block_l=$((_bat_l - _bat_pct_room))
    [ "$_bat_block_l" -lt 0 ] && _bat_block_l=0

    # Weather values grow with the panel. Date stays in the header band.
    _primary=$((_box_h * 62 / 100))
    _caption=$((_box_h * 15 / 100))
    _secondary=$((_box_h * 24 / 100))
    [ "$_caption" -lt 28 ] && _caption=28
    [ "$_secondary" -lt 42 ] && _secondary=42
    [ "$_secondary" -ge "$_primary" ] && _secondary=$((_primary * 40 / 100))

    _date_px=$((H * 16 / 100))
    [ "$_date_px" -lt 140 ] && _date_px=140
    [ "$_date_px" -gt 190 ] && _date_px=190
    _year_size=$((_date_px * 40 / 100))
    [ "$_year_size" -lt 42 ] && _year_size=42

    _header=$((16 + _date_px * 82 / 100))
    [ "$_header" -lt 120 ] && _header=120
    _box_top=$((H - 8 - _hint_h - _box_h))
    _cap_top=$((_box_top + 18))
    _val_top=$((_box_top + _box_h * 30 / 100))
    _foot_top=$((_box_top + _box_h - _secondary - 20))
    while [ $((_val_top + _primary + _primary / 2)) -ge "$H" ]; do
        _primary=$((_primary - 8))
        [ "$_primary" -lt 80 ] && break
        _secondary=$((_primary * 32 / 100))
        [ "$_secondary" -lt 42 ] && _secondary=42
        [ "$_secondary" -ge "$_primary" ] && _secondary=$((_primary * 40 / 100))
        _foot_top=$((_box_top + _box_h - _secondary - 20))
    done

    rm -f "$EXIT_RECT"

    _hdr_mid=$((_header / 2))
    _bat_t=$((_hdr_mid - _bat_h / 2))
    [ "$_bat_t" -lt 8 ] && _bat_t=8
    _date_top=$((_hdr_mid - _date_px * FONT_FLAP_MID / 100))
    [ "$_date_top" -lt 8 ] && _date_top=8
    _year_top=$((_hdr_mid - _year_size * FONT_MID / 100))
    _date_right=$((W - _bat_block_l + 24))
    # Year sits after weekday+day+month. SUN 17 AUG is about 5.2em of Jersey.
    _year_left=$((_margin + _date_px * 52 / 10))
    _year_limit=$((_bat_block_l - _year_size * 4))
    [ "$_year_left" -gt "$_year_limit" ] && _year_left=$_year_limit

    draw_battery "$_bat_l" "$_bat_t" "$_bat_w" "$_bat_h" "$_bat"
    print_ot "$FONT_BOLD" "$_date_px" "$_date_top" "$_margin" "$_date_right" "$DATE_PRI" 0
    print_ot "$FONT_REG" "$_year_size" "$_year_top" "$_year_left" $((W - _bat_block_l + 8)) "$DATE_YEAR" 0

    _band_top=$((_header + _gap_v))
    _band_bot=$((_box_top - _gap_v))
    _cell_h=$((_band_bot - _band_top))

    _area_w=$((W - _margin - _margin))
    _gap=16
    _colon_w=$((_area_w * 7 / 100))
    _cell_w=$(( (_area_w - _gap * 3 - _colon_w) / 4 ))
    _cell_max=$((_cell_w * 210 / 100))
    if [ "$_cell_h" -gt "$_cell_max" ]; then
        _cell_h=$_cell_max
    fi
    [ "$_cell_h" -lt 80 ] && _cell_h=80
    _cells_top=$((_band_top + (_band_bot - _band_top - _cell_h) / 2))
    _x=$_margin

    _h1=$(echo "$_time" | cut -c1)
    _h2=$(echo "$_time" | cut -c2)
    _m1=$(echo "$_time" | cut -c4)
    _m2=$(echo "$_time" | cut -c5)
    if [ -z "$_m2" ]; then
        print_ot "$FONT_BOLD" $((_cell_h * 60 / 100)) $((_cells_top + _cell_h / 2 - _cell_h * 60 / 100 * FONT_FLAP_MID / 100)) "$_margin" "$_margin" "$_time" 1
    else
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_h1"
        _x=$((_x + _cell_w + _gap))
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_h2"
        _x=$((_x + _cell_w + _gap))
        draw_colon "$_x" "$_cells_top" "$_colon_w" "$_cell_h"
        if [ -n "$CLOCK_AMPM" ]; then
            _apx=$((_colon_w * 48 / 100))
            print_ot "$FONT_BOLD" "$_apx" $((_cells_top + _cell_h * 74 / 100)) \
                "$_x" $((W - _x - _colon_w)) "$CLOCK_AMPM" 1
        fi
        _x=$((_x + _colon_w + _gap))
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_m1"
        _x=$((_x + _cell_w + _gap))
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_m2"
    fi

    _box_w=$((W - _margin - _margin))
    outline_rect "$_box_top" "$_margin" "$_box_w" "$_box_h" 3
    # print_ot centres between `left` and W-`right`, so each column's right
    # value is the distance from the screen edge to that column's right edge.
    _col_w=$((_box_w / 3))
    _col_pad=18
    _c0l=$((_margin + _col_pad))
    _c0r=$((W - _margin - _col_w + _col_pad))
    _c1l=$((_margin + _col_w + _col_pad))
    _c1r=$((W - _margin - _col_w - _col_w + _col_pad))
    _c2l=$((_margin + _col_w + _col_w + _col_pad))
    _c2r=$((_margin + _col_pad))

    print_ot_fit "$FONT_REG" "$_caption" "$_cap_top" "$_c0l" "$_c0r" "FEELS" 1
    print_ot_fit "$FONT_REG" "$_caption" "$_cap_top" "$_c1l" "$_c1r" "AIR" 1
    print_ot_fit "$FONT_REG" "$_caption" "$_cap_top" "$_c2l" "$_c2r" "$WEATHER_RAIN_LABEL" 1

    print_ot_fit "$FONT_BOLD" "$_primary" "$_val_top" "$_c0l" "$_c0r" "$WEATHER_FEELS" 1
    print_ot_fit "$FONT_BOLD" "$_primary" "$_val_top" "$_c1l" "$_c1r" "$WEATHER_TEMP" 1
    print_ot_fit "$FONT_BOLD" "$_primary" "$_val_top" "$_c2l" "$_c2r" "$WEATHER_RAIN" 1

    _wind="WIND $(fmt_wind_short)"
    _hum="HUM $WEATHER_HUM"
    print_ot_fit "$FONT_REG" "$_secondary" "$_foot_top" "$_c0l" "$_c0r" "$_wind" 1
    print_ot_fit "$FONT_REG" "$_secondary" "$_foot_top" "$_c2l" "$_c2r" "$_hum" 1

    _hint="$WEATHER_COND · TAP 3X TO QUIT"
    print_ot "$FONT_REG" 24 $((_box_top + _box_h + 6)) "$_margin" "$_margin" "$_hint" 1

    "$FBINK" -q -w -s
}

draw_eips() {
    _time="$1"
    _date="$2"
    _bat="$3"
    eips -c >/dev/null 2>&1
    eips 1 1 "$_date" >/dev/null 2>&1
    eips 2 8 "$_time" >/dev/null 2>&1
    eips 1 16 "$WEATHER_FEELS $WEATHER_TEMP $WEATHER_RAIN" >/dev/null 2>&1
    eips 1 18 "$WEATHER_RAIN_LABEL $WEATHER_COND" >/dev/null 2>&1
    eips 1 20 "BAT ${_bat}%" >/dev/null 2>&1
}

draw_clock() {
    _full="${1:-0}"
    _time=$(date "+${TIME_FORMAT}" 2>/dev/null)
    _date=$(date "+${DATE_FORMAT}" 2>/dev/null)
    _bat=$(get_battery)
    CLOCK_AMPM=""
    if [ "$SHOW_AMPM" = "1" ]; then
        CLOCK_AMPM=$(date +%p 2>/dev/null | tr 'a-z' 'A-Z')
    fi
    compute_seattle_rain
    log "draw time=$_time date=$_date bat=$_bat weather=$WEATHER_COND $WEATHER_TEMP rain=$WEATHER_RAIN_LABEL $WEATHER_RAIN fbink=$HAVE_FBINK ${VIEW_W}x${VIEW_H}"
    # #region agent log
    _sys24=$(date '+%H:%M:%S' 2>/dev/null)
    _epoch=$(date +%s 2>/dev/null)
    _rtc=$(rtc_stamp)
    _quiet_now=0
    is_quiet_hours && _quiet_now=1
    agent_dbg D "clock.sh:draw_clock" "drawn face" \
        "{\"time\":\"$_time\",\"ampm\":\"$CLOCK_AMPM\",\"sys24\":\"$_sys24\",\"epoch\":${_epoch:-0},\"rtc\":\"$_rtc\",\"full\":$_full,\"quiet\":$_quiet_now}"
    # #endregion

    if [ "$HAVE_FBINK" -eq 1 ] && [ -n "$FONT_BOLD" ]; then
        if ! draw_airport "$_time" "$_date" "$_bat" "$_full"; then
            log "airport draw failed, eips fallback"
            HAVE_FBINK=0
            draw_eips "$_time" "$_date" "$_bat"
            return 0
        fi
    else
        draw_eips "$_time" "$_date" "$_bat"
    fi
}

should_stop() {
    if [ -f "$EXIT_FLAG" ]; then
        rm -f "$EXIT_FLAG"
        return 0
    fi
    if [ -f "${EXT_DIR}/STOP" ]; then
        rm -f "${EXT_DIR}/STOP"
        return 0
    fi
    if [ -f /mnt/us/pw3clock.STOP ]; then
        rm -f /mnt/us/pw3clock.STOP
        return 0
    fi
    return 1
}

kill_touch_watcher() {
    if [ -n "$TOUCH_PID" ]; then
        kill "$TOUCH_PID" 2>/dev/null
    fi
    if [ -f "$TOUCH_PIDFILE" ]; then
        kill "$(cat "$TOUCH_PIDFILE" 2>/dev/null)" 2>/dev/null
        rm -f "$TOUCH_PIDFILE"
    fi
    TOUCH_PID=""
}

start_touch_watcher() {
    kill_touch_watcher
    rm -f "$EXIT_FLAG"
    if [ ! -f "$FBINFO" ]; then
        log "skip touch watcher (no fbinfo)"
        return 1
    fi
    TOUCH_MAP="${TOUCH_MAP:-1}"
    export TOUCH_MAP LOG
    /bin/sh "${EXT_DIR}/bin/touch-exit.sh" >> "$LOG" 2>&1 &
    TOUCH_PID=$!
    echo "$TOUCH_PID" > "$TOUCH_PIDFILE"
    log "touch watcher pid=$TOUCH_PID"
}

sleep_for_secs() {
    _secs="$1"
    [ "$_secs" -gt 0 ] || _secs=1
    log "sleeping ${_secs}s (suspend=$USE_SUSPEND)"
    # #region agent log
    _pre_e=$(date +%s 2>/dev/null)
    _pre_t=$(date '+%H:%M:%S' 2>/dev/null)
    _pre_rtc=$(rtc_stamp)
    agent_dbg A "clock.sh:sleep_for_secs:before" "before sleep/suspend" \
        "{\"secs\":$_secs,\"suspend\":\"$USE_SUSPEND\",\"sys\":\"$_pre_t\",\"epoch\":${_pre_e:-0},\"rtc\":\"$_pre_rtc\"}"
    # #endregion
    if [ "$USE_SUSPEND" = "1" ]; then
        echo 0 > /sys/class/rtc/rtc1/wakealarm 2>/dev/null
        rtcwake -d /dev/rtc1 -m no -s "$_secs" >> "$LOG" 2>&1
        echo mem > /sys/power/state
        sync_system_from_rtc
    else
        sleep "$_secs"
    fi
    # #region agent log
    _post_e=$(date +%s 2>/dev/null)
    _post_t=$(date '+%H:%M:%S' 2>/dev/null)
    _post_rtc=$(rtc_stamp)
    _delta=0
    if [ -n "$_pre_e" ] && [ -n "$_post_e" ]; then
        _delta=$((_post_e - _pre_e))
    fi
    _slip=$((_secs - _delta))
    _post_skew=0
    if [ -n "$_post_e" ] && [ -n "$_post_rtc" ]; then
        _post_skew=$((_post_e - _post_rtc))
    fi
    agent_dbg A "clock.sh:sleep_for_secs:after" "after sleep/suspend" \
        "{\"secs\":$_secs,\"suspend\":\"$USE_SUSPEND\",\"sys\":\"$_post_t\",\"epoch\":${_post_e:-0},\"rtc\":\"$_post_rtc\",\"delta\":$_delta,\"slip\":$_slip,\"skew\":$_post_skew}"
    # #endregion
}

# Sleep until the next N-minute boundary (aligned to midnight).
sleep_until_next_tick() {
    _interval=${1:-1}
    case "$_interval" in
        ''|*[!0-9]*|0) _interval=1 ;;
    esac
    _ih=$(dezero "$(date +%H 2>/dev/null)")
    _im=$(dezero "$(date +%M 2>/dev/null)")
    _is=$(dezero "$(date +%S 2>/dev/null)")
    _into=$((_ih * 3600 + _im * 60 + _is))
    _span=$((_interval * 60))
    _secs=$((_span - (_into % _span)))
    if [ "$_secs" -lt 3 ]; then
        _secs=$((_secs + _span))
    fi
    # #region agent log
    agent_dbg C "clock.sh:sleep_until_next_tick" "tick math" \
        "{\"interval\":$_interval,\"h\":$_ih,\"m\":$_im,\"s\":$_is,\"into\":$_into,\"span\":$_span,\"secs\":$_secs,\"quietStart\":\"$QUIET_START\",\"quietEnd\":\"$QUIET_END\"}"
    # #endregion
    sleep_for_secs "$_secs"
}

# True if at least _mins minutes have passed since unix epoch _since (0 = never).
minutes_elapsed() {
    _since=$1
    _mins=$2
    case "$_mins" in
        ''|*[!0-9]*|0) return 0 ;;
    esac
    if [ "$_since" -eq 0 ]; then
        return 0
    fi
    _now=$(date +%s)
    [ $((_now - _since)) -ge $((_mins * 60)) ]
}

probe_one() {
    # Render off to the side purely to record whether FBInk accepts the call.
    _qpx="$1"
    _qfont="$2"
    _qtext="$3"
    _qout=$("$FBINK" -q -b -C "$INK" -B "$PAPER" -O \
        -t "regular=${_qfont},px=${_qpx},top=4,bottom=0,left=4,right=4" -- "$_qtext" 2>&1)
    _qrc=$?
    if [ "$_qrc" -eq 0 ]; then
        log "probe OK   px=$_qpx '$_qtext'"
    else
        log "probe FAIL px=$_qpx '$_qtext' rc=$_qrc err=$(echo "$_qout" | head -1)"
    fi
}

dump_selftest() {
    log "======== pw3clock self-test ========"
    log "ext=$EXT_DIR"
    log "uname=$(uname -a 2>/dev/null)"
    log "date=$(date 2>/dev/null)"
    log "lipc batt=$(lipc-get-prop com.lab126.powerd battLevel 2>&1)"
    log "wifi=$(lipc-get-prop com.lab126.wifid cmState 2>&1)"
    log "FBINK_NO_SW_ROTA=$FBINK_NO_SW_ROTA"
    log "fonts bold=$FONT_BOLD"
    ls -l "${EXT_DIR}/fonts" >> "$LOG" 2>&1
    if [ "$HAVE_FBINK" -eq 1 ]; then
        "$FBINK" -e >> "$LOG" 2>&1
    fi
    log "input devices:"
    cat /proc/bus/input/devices >> "$LOG" 2>&1
    ls -l /dev/input >> "$LOG" 2>&1
    log "--- text probes (every size the board uses) ---"
    probe_one 24 "$FONT_REG" "OVERCAST · TAP 3X TO QUIT"
    probe_one 52 "$FONT_REG" "WIND 8K NW"
    probe_one 54 "$FONT_REG" "RAIN AT"
    probe_one 168 "$FONT_BOLD" "SUN 17 AUG"
    probe_one 168 "$FONT_BOLD" "18°C"
    probe_one 168 "$FONT_BOLD" "20°C"
    probe_one 168 "$FONT_BOLD" "9PM"
    probe_one 440 "$FONT_BOLD" "4"
    log "===================================="
}

run_debug() {
    load_config
    log "debug start"
    status "self-test running"
    prepare_fbink
    pick_font
    setup_landscape 0
    load_weather_cache
    dump_selftest
    prevent_screensaver

    _i=0
    while [ "$_i" -lt "$DEBUG_SECONDS" ]; do
        draw_clock 0
        _i=$((_i + 2))
        sleep 2
    done

    status "self-test finished. Open pw3clock.log on USB."
    log "debug finished"
}

run_clock() {
    load_config
    log "clock start pid=$$"
    echo $$ > "$PIDFILE"
    status "clock starting"
    GOT_SIGNAL=0
    trap 'GOT_SIGNAL=1' USR1
    prepare_fbink
    pick_font
    prevent_screensaver
    frontlight_off
    # Lowest CPU clock while the board is running.
    echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
    load_weather_cache

    sleep 2
    stop_gui
    setup_landscape 1
    frontlight_off
    prevent_screensaver
    disable_wifi

    draw_clock 1
    start_touch_watcher
    update_weather
    _last_weather=$(date +%s)
    _last_full=$(date +%s)
    draw_clock 0

    _cycle=0
    while true; do
        _interval=$(clock_interval_minutes)
        sleep_until_next_tick "$_interval"

        if [ "$GOT_SIGNAL" = "1" ] || should_stop; then
            log "stop requested"
            break
        fi

        _quiet=0
        is_quiet_hours && _quiet=1
        # Interval can change when we cross into/out of quiet hours.
        _interval=$(clock_interval_minutes)

        # Flashing full refresh on a wall-clock cadence during the day only.
        _full=0
        if [ "$_quiet" -eq 0 ] && minutes_elapsed "$_last_full" "$FULL_REFRESH_EVERY"; then
            _full=1
            _last_full=$(date +%s)
        fi

        # Weather on its own timer; quiet hours keep the radio cold.
        if [ "$_quiet" -eq 0 ] && minutes_elapsed "$_last_weather" "$WEATHER_EVERY"; then
            update_weather
            _last_weather=$(date +%s)
        fi

        draw_clock "$_full"
        status "running $_cycle quiet=$_quiet every=${_interval}m"
        [ $((_cycle % 60)) -eq 0 ] && trim_log
        frontlight_off
        _cycle=$((_cycle + 1))
    done

    trap - USR1
    kill_touch_watcher
    rm -f "$PIDFILE" "$EXIT_FLAG" "$EXIT_RECT"
    start_gui
    status "clock stopped"
    log "clock exit"
}
