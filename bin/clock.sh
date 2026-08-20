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
    WEATHER_WIFI="${WEATHER_WIFI:-1}"
    WEATHER_EVERY="${WEATHER_EVERY:-60}"
    FULL_REFRESH_EVERY="${FULL_REFRESH_EVERY:-60}"
    QUIET_START="${QUIET_START:-}"
    QUIET_END="${QUIET_END:-07:00}"
    QUIET_CLOCK_EVERY="${QUIET_CLOCK_EVERY:-5}"
    ROTATE="${ROTATE:-auto}"
    THEME="${THEME:-light}"
    TOUCH_MAP="${TOUCH_MAP:-1}"
    FONT="${FONT:-arcade}"
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

    case "$FONT" in
        arcade|mario|game|pixel|pixelify|jersey)
            FONT_BOLD="${EXT_DIR}/fonts/Jersey25-Regular.ttf"
            FONT_REG="${EXT_DIR}/fonts/Jersey25-Regular.ttf"
            if [ -f "$FONT_REG" ]; then
                # Jersey 25: tall pixel digits with clear 2/5/6 shapes.
                # Slightly narrower date than Pixelify so the header still fits.
                FONT_DATE_MUL=80
                FONT_GRID=4
                # Jersey ink sits at ~0.50em. 64 was for mixed text and left
                # the flap digits sitting above the hinge line.
                FONT_FLAP_MID=50
                log "Using bundled Jersey 25 (arcade)"
                return 0
            fi
            log "Jersey missing, falling back to Barlow"
            ;;
        retro|pressstart|nes)
            FONT_BOLD="${EXT_DIR}/fonts/PressStart2P-Regular.ttf"
            FONT_REG="${EXT_DIR}/fonts/PressStart2P-Regular.ttf"
            if [ -f "$FONT_REG" ]; then
                # Classic Namco/NES arcade face. Very wide — date is smaller.
                FONT_DATE_MUL=52
                FONT_GRID=8
                FONT_FLAP_MID=50
                log "Using bundled Press Start 2P (retro)"
                return 0
            fi
            log "Press Start missing, falling back to Barlow"
            ;;
    esac

    FONT_BOLD="${EXT_DIR}/fonts/BarlowCondensed-SemiBold.ttf"
    FONT_REG="${EXT_DIR}/fonts/BarlowCondensed-Regular.ttf"
    if [ -f "$FONT_BOLD" ] && [ -f "$FONT_REG" ]; then
        log "Using bundled Barlow Condensed"
        FONT_FLAP_MID=65
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
    # "Mon 17 Aug 2026" -> DATE_PRI="17 AUG" DATE_YEAR="2026"
    DATE_YEAR=$(echo "$1" | awk '{print $NF}')
    DATE_PRI=$(echo "$1" | awk '{
        n=NF
        if (n >= 3) printf "%s %s", $(n-2), $(n-1)
        else print $0
    }' | tr 'a-z' 'A-Z' | sed 's/^0//')
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

compute_seattle_rain() {
    # Seattle-specific: rain now, drizzle, dry-until-hour, or gray-and-dry.
    WEATHER_RAIN_LABEL="DRY"
    WEATHER_RAIN="DAY"
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
    case "$WEATHER_PRECIP" in
        ''|0|0.0|0.00|--|-) ;;
        *)
            WEATHER_RAIN_LABEL="RAIN"
            WEATHER_RAIN="NOW"
            return 0
            ;;
    esac

    _nowh=$(dezero "$(date +%H 2>/dev/null)")
    _nowm=$(dezero "$(date +%M 2>/dev/null)")
    _nowx=$((_nowh * 100 + _nowm))
    _next=""
    for _pair in $WEATHER_HOURLY; do
        _t=${_pair%%:*}
        _c=${_pair#*:}
        case "$_t" in
            ''|*[!0-9]*) continue ;;
        esac
        case "$_c" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$_t" -gt "$_nowx" ] && [ "$_c" -ge 40 ]; then
            _next=$_t
            break
        fi
    done
    if [ -n "$_next" ]; then
        WEATHER_RAIN_LABEL="RAIN AT"
        WEATHER_RAIN=$(fmt_rain_hour "$_next")
        return 0
    fi
    case "$_cond" in
        *CLOUD*|*OVERCAST*|*FOG*|*MIST*)
            WEATHER_RAIN_LABEL="CLOUDY"
            WEATHER_RAIN="DRY"
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

http_get() {
    _url=$1
    _timeout=${2:-8}
    _body=""
    if command -v curl >/dev/null 2>&1; then
        _body=$(curl -s -f -m "$_timeout" -A "pw3clock/1.0" "$_url" 2>/dev/null)
    fi
    if [ -z "$_body" ] && command -v wget >/dev/null 2>&1; then
        _body=$(wget -q -T "$_timeout" -U "pw3clock/1.0" -O - "$_url" 2>/dev/null)
    fi
    printf '%s' "$_body"
}

fetch_weather() {
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
    fetch_weather
    _rc=$?
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
    # left top w h percent
    _btl=$1
    _btt=$2
    _btw=$3
    _bth=$4
    _btp=$5
    case "$_btp" in
        ''|*[!0-9]*) _btp=0 ;;
    esac
    [ "$_btp" -gt 100 ] && _btp=100
    outline_rect "$_btt" "$_btl" "$_btw" "$_bth" 3
    # Terminal nub, so it reads as a battery rather than a progress bar.
    fill_rect "$INK" $((_btt + _bth / 3)) $((_btl + _btw)) 10 $((_bth / 3))
    _btfill=$(((_btw - 18) * _btp / 100))
    if [ "$_btfill" -gt 0 ]; then
        fill_rect "$INK" $((_btt + 9)) $((_btl + 9)) "$_btfill" $((_bth - 18))
    fi
}

print_ot_ink() {
    # Temporarily swap fg/bg so inverted week cells can print in paper on ink.
    _oi=$INK
    _op=$PAPER
    INK=$1
    PAPER=$2
    shift 2
    print_ot "$@"
    INK=$_oi
    PAPER=$_op
}

draw_week_cell() {
    # left top w h letter selected
    _wl=$1
    _wt=$2
    _ww=$3
    _wh=$4
    _wch=$5
    _won=$6
    if [ "$_won" = "1" ]; then
        fill_rect "$INK" "$_wt" "$_wl" "$_ww" "$_wh"
        _wfg=$PAPER
        _wbg=$INK
    else
        outline_rect "$_wt" "$_wl" "$_ww" "$_wh" 3
        _wfg=$INK
        _wbg=$PAPER
    fi
    _wsize=$((_wh * 48 / 100))
    _wtop=$((_wt + _wh / 2 - _wsize * FONT_MID / 100))
    [ "$_wtop" -lt "$_wt" ] && _wtop=$_wt
    print_ot_ink "$_wfg" "$_wbg" "$FONT_BOLD" "$_wsize" "$_wtop" \
        "$_wl" $((VIEW_W - _wl - _ww)) "$_wch" 1
}

draw_week() {
    # top  — seven small flaps, Monday first, today inverted.
    _wkt=$1
    _wkh=$2
    _wkgap=10
    _wkcell=$_wkh
    _wktotal=$((_wkcell * 7 + _wkgap * 6))
    _area=$((VIEW_W * 42 / 100))
    if [ "$_wktotal" -gt "$_area" ]; then
        _wkcell=$(( (_area - _wkgap * 6) / 7 ))
        _wktotal=$((_wkcell * 7 + _wkgap * 6))
    fi
    _wkx=$(( (VIEW_W - _wktotal) / 2 ))
    _today=$(date +%u 2>/dev/null)
    case "$_today" in
        [1-7]) ;;
        *) _today=1 ;;
    esac
    _d=1
    for _ch in M T W T F S S; do
        _sel=0
        [ "$_d" -eq "$_today" ] && _sel=1
        draw_week_cell "$_wkx" "$_wkt" "$_wkcell" "$_wkh" "$_ch" "$_sel"
        _wkx=$((_wkx + _wkcell + _wkgap))
        _d=$((_d + 1))
    done
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
    _hint_h=28
    _gap_v=16
    _week_h=56
    _box_h=$((H * 26 / 100))
    [ "$_box_h" -lt 220 ] && _box_h=220

    _exit_w=190
    _exit_h=70
    _exit_l=$((W - 40 - _exit_w))
    _bat_w=150
    _bat_h=48
    _bat_l=$((_exit_l - _bat_w - 40))

    # Primary type is the air-temp size. Feels, rain value and date match it.
    _primary=$((_box_h * 60 / 100))
    _caption=$((_box_h * 12 / 100))
    _secondary=$((_box_h * 22 / 100))
    [ "$_caption" -lt 22 ] && _caption=22
    [ "$_secondary" -lt 36 ] && _secondary=36
    [ "$_secondary" -ge "$_primary" ] && _secondary=$((_primary * 40 / 100))

    _header=$((16 + _primary * 82 / 100))
    [ "$_header" -lt 120 ] && _header=120
    _box_top=$((H - 8 - _hint_h - _box_h))
    _week_top=$((_box_top - _gap_v - _week_h))
    _cap_top=$((_box_top + 14))
    _val_top=$((_box_top + _box_h * 30 / 100))
    _foot_top=$((_box_top + _box_h - _secondary - 16))
    while [ $((_val_top + _primary + _primary / 2)) -ge "$H" ]; do
        _primary=$((_primary - 8))
        [ "$_primary" -lt 80 ] && break
        _header=$((16 + _primary * 82 / 100))
        _secondary=$((_primary * 32 / 100))
        [ "$_secondary" -lt 36 ] && _secondary=36
        [ "$_secondary" -ge "$_primary" ] && _secondary=$((_primary * 40 / 100))
        _foot_top=$((_box_top + _box_h - _secondary - 16))
    done

    _exit_t=$(((_header - _exit_h) / 2))
    [ "$_exit_t" -lt 8 ] && _exit_t=8
    outline_rect "$_exit_t" "$_exit_l" "$_exit_w" "$_exit_h" 3
    printf '%s %s %s %s\n' "$_exit_l" "$_exit_t" "$_exit_w" "$_exit_h" > "$EXIT_RECT" 2>/dev/null

    _hdr_mid=$((_header / 2))
    _bat_t=$((_hdr_mid - _bat_h / 2))
    _date_top=$((_hdr_mid - _primary * FONT_FLAP_MID / 100))
    [ "$_date_top" -lt 8 ] && _date_top=8
    _year_size=$_secondary
    _year_top=$((_hdr_mid - _year_size * FONT_MID / 100))
    _date_right=$((W - _bat_l + 24))
    # Year sits after the day+month. 17 AUG is about 3.2em of Jersey.
    _year_left=$((_margin + _primary * 32 / 10))

    print_ot "$FONT_BOLD" 36 $((_hdr_mid - 36 * FONT_MID / 100)) \
        "$_exit_l" $((W - _exit_l - _exit_w)) "EXIT" 1
    draw_battery "$_bat_l" "$_bat_t" "$_bat_w" "$_bat_h" "$_bat"
    print_ot "$FONT_BOLD" "$_primary" "$_date_top" "$_margin" "$_date_right" "$DATE_PRI" 0
    print_ot "$FONT_REG" "$_year_size" "$_year_top" "$_year_left" $((W - _bat_l + 8)) "$DATE_YEAR" 0

    _band_top=$((_header + _gap_v))
    _band_bot=$((_week_top - _gap_v))
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

    draw_week "$_week_top" "$_week_h"
    _wk_mid=$((_week_top + _week_h / 2 - _secondary * FONT_MID / 100))
    print_ot "$FONT_REG" "$_secondary" "$_wk_mid" "$_margin" $((W * 58 / 100)) "RISE $WEATHER_RISE" 0
    print_ot "$FONT_REG" "$_secondary" "$_wk_mid" $((W * 58 / 100)) "$_margin" "SET $WEATHER_SET" 1

    _box_w=$((W - _margin - _margin))
    outline_rect "$_box_top" "$_margin" "$_box_w" "$_box_h" 3
    # print_ot centres between `left` and W-`right`, so each column's right
    # value is the distance from the screen edge to that column's right edge.
    _col_w=$((_box_w / 3))
    _c0l=$_margin
    _c0r=$((W - _margin - _col_w))
    _c1l=$((_margin + _col_w))
    _c1r=$((W - _margin - _col_w - _col_w))
    _c2l=$((_margin + _col_w + _col_w))
    _c2r=$_margin

    print_ot "$FONT_REG" "$_caption" "$_cap_top" "$_c0l" "$_c0r" "FEELS" 1
    print_ot "$FONT_REG" "$_caption" "$_cap_top" "$_c1l" "$_c1r" "AIR" 1
    print_ot "$FONT_REG" "$_caption" "$_cap_top" "$_c2l" "$_c2r" "$WEATHER_RAIN_LABEL" 1

    print_ot "$FONT_BOLD" "$_primary" "$_val_top" "$_c0l" "$_c0r" "$WEATHER_FEELS" 1
    print_ot "$FONT_BOLD" "$_primary" "$_val_top" "$_c1l" "$_c1r" "$WEATHER_TEMP" 1
    print_ot "$FONT_BOLD" "$_primary" "$_val_top" "$_c2l" "$_c2r" "$WEATHER_RAIN" 1

    _wind="WIND $(fmt_wind_short)"
    _hum="HUM $WEATHER_HUM"
    print_ot "$FONT_REG" "$_secondary" "$_foot_top" "$_c0l" "$_c0r" "$_wind" 1
    print_ot "$FONT_REG" "$_secondary" "$_foot_top" "$_c2l" "$_c2r" "$_hum" 1

    _hint="$WEATHER_COND · TAP 3X TO QUIT"
    print_ot "$FONT_REG" 20 $((_box_top + _box_h + 6)) "$_margin" "$_margin" "$_hint" 1

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
    if [ ! -f "$EXIT_RECT" ] || [ ! -f "$FBINFO" ]; then
        log "skip touch watcher (no rect/fbinfo)"
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
    if [ "$USE_SUSPEND" = "1" ]; then
        rtcwake -d /dev/rtc1 -m no -s "$_secs" >> "$LOG" 2>&1
        echo mem > /sys/power/state
    else
        sleep "$_secs"
    fi
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
    log "fonts face=$FONT bold=$FONT_BOLD"
    ls -l "${EXT_DIR}/fonts" >> "$LOG" 2>&1
    if [ "$HAVE_FBINK" -eq 1 ]; then
        "$FBINK" -e >> "$LOG" 2>&1
    fi
    log "input devices:"
    cat /proc/bus/input/devices >> "$LOG" 2>&1
    ls -l /dev/input >> "$LOG" 2>&1
    log "--- text probes (every size the board uses) ---"
    probe_one 20 "$FONT_REG" "OVERCAST · TAP 3X TO QUIT"
    probe_one 36 "$FONT_BOLD" "EXIT"
    probe_one 52 "$FONT_REG" "RISE 6:12AM"
    probe_one 52 "$FONT_REG" "WIND 8K NW"
    probe_one 54 "$FONT_REG" "RAIN AT"
    probe_one 168 "$FONT_BOLD" "17 AUG"
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
