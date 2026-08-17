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
VIEW_W=1072
VIEW_H=1448
ORIG_ROTATE=""
ROTATE_PATH=""
WEATHER_COND="NO DATA"
WEATHER_TEMP="--"
WEATHER_WIND="--"
WEATHER_FEELS="--"
WEATHER_HUM="--"
WIFI_WAS=""
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
    WEATHER_EVERY="${WEATHER_EVERY:-30}"
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
    FONT_BOLD="${EXT_DIR}/fonts/BarlowCondensed-SemiBold.ttf"
    FONT_REG="${EXT_DIR}/fonts/BarlowCondensed-Regular.ttf"
    if [ -f "$FONT_BOLD" ] && [ -f "$FONT_REG" ]; then
        log "Using bundled Barlow Condensed"
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
        [ -n "$WEATHER_COND" ] || WEATHER_COND="NO DATA"
        [ -n "$WEATHER_TEMP" ] || WEATHER_TEMP="--"
        [ -n "$WEATHER_WIND" ] || WEATHER_WIND="--"
        [ -n "$WEATHER_FEELS" ] || WEATHER_FEELS="--"
        [ -n "$WEATHER_HUM" ] || WEATHER_HUM="--"
    fi
}

save_weather_cache() {
    printf '%s\n%s\n%s\n%s\n%s\n' "$WEATHER_COND" "$WEATHER_TEMP" \
        "$WEATHER_WIND" "$WEATHER_FEELS" "$WEATHER_HUM" > "$WEATHER_CACHE" 2>/dev/null
}

wifi_state() {
    lipc-get-prop com.lab126.wifid cmState 2>/dev/null
}

enable_wifi() {
    lipc-set-prop com.lab126.cmd wirelessEnable 1 >/dev/null 2>&1
}

restore_wifi() {
    if [ "$WIFI_WAS" = "off" ]; then
        lipc-set-prop com.lab126.cmd wirelessEnable 0 >/dev/null 2>&1
    fi
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

weather_url() {
    _city=$(echo "$WEATHER_CITY" | sed 's/ /+/g')
    # cond | temp | wind | feels-like | humidity
    if [ -n "$_city" ]; then
        echo "http://wttr.in/${_city}?m&format=%C|%t|%w|%f|%h"
    else
        echo "http://wttr.in/?m&format=%C|%t|%w|%f|%h"
    fi
}

fetch_weather() {
    _url=$(weather_url)
    _raw=""
    if command -v curl >/dev/null 2>&1; then
        _raw=$(curl -s -f -m 8 "$_url" 2>/dev/null)
    fi
    if [ -z "$_raw" ] && command -v wget >/dev/null 2>&1; then
        _raw=$(wget -q -T 8 -O - "$_url" 2>/dev/null)
    fi
    log "weather raw=$_raw url=$_url"
    case "$_raw" in
        *"|"*)
            WEATHER_COND=$(echo "$_raw" | awk -F'|' '{print $1}' | tr 'a-z' 'A-Z')
            WEATHER_TEMP=$(echo "$_raw" | awk -F'|' '{print $2}' | sed 's/^+//')
            WEATHER_WIND=$(echo "$_raw" | awk -F'|' '{print $3}' | tr 'a-z' 'A-Z')
            WEATHER_FEELS=$(echo "$_raw" | awk -F'|' '{print $4}' | sed 's/^+//')
            WEATHER_HUM=$(echo "$_raw" | awk -F'|' '{print $5}')
            [ -n "$WEATHER_COND" ] || WEATHER_COND="NO DATA"
            [ -n "$WEATHER_TEMP" ] || WEATHER_TEMP="--"
            [ -n "$WEATHER_WIND" ] || WEATHER_WIND="--"
            [ -n "$WEATHER_FEELS" ] || WEATHER_FEELS="--"
            [ -n "$WEATHER_HUM" ] || WEATHER_HUM="--"
            save_weather_cache
            return 0
            ;;
    esac
    return 1
}

update_weather() {
    load_weather_cache
    _st=$(wifi_state)
    WIFI_WAS="on"
    if [ "$_st" != "CONNECTED" ]; then
        WIFI_WAS="off"
        if [ "$WEATHER_WIFI" != "1" ]; then
            log "wifi down, skip weather"
            return 1
        fi
        enable_wifi
        if ! wait_wifi; then
            log "wifi wait failed"
            restore_wifi
            return 1
        fi
    fi
    fetch_weather
    _rc=$?
    restore_wifi
    return $_rc
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
    # The glyph hangs below the top margin by its ascent, so the offset that
    # centres a digit is roughly cell/2 - 0.64*em.
    _dtop=$((_ft + _fh / 2 - _dsize * 64 / 100))
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
    _dateu=$(echo "$_date" | tr 'a-z' 'A-Z')
    # Scale with width so the date still fits if the panel is not landscape.
    _date_size=$((W * 86 / 1000))
    _margin=48
    _header=$((_date_size * 155 / 100))

    _exit_w=200
    _exit_h=76
    _exit_l=$((W - 40 - _exit_w))
    _exit_t=$(((_header - _exit_h) / 2))
    [ "$_exit_t" -lt 8 ] && _exit_t=8
    outline_rect "$_exit_t" "$_exit_l" "$_exit_w" "$_exit_h" 3
    printf '%s %s %s %s\n' "$_exit_l" "$_exit_t" "$_exit_w" "$_exit_h" > "$EXIT_RECT" 2>/dev/null

    # One shared baseline keeps date, battery and EXIT optically aligned even
    # though their sizes differ. baseline = centre + 0.36em (see draw_flap).
    _hdr_mid=$((_header / 2))
    _hdr_base=$((_hdr_mid + _date_size * 36 / 100))
    _bat_w=150
    _bat_h=54
    _bat_l=$((_exit_l - _bat_w - 56))
    _bat_t=$((_hdr_mid - _bat_h / 2))

    print_ot "$FONT_BOLD" 40 $((_hdr_mid - 40 * 64 / 100)) "$_exit_l" $((W - _exit_l - _exit_w)) "EXIT" 1
    draw_battery "$_bat_l" "$_bat_t" "$_bat_w" "$_bat_h" "$_bat"
    print_ot "$FONT_BOLD" "$_date_size" $((_hdr_base - _date_size)) "$_margin" $((W - _bat_l + 30)) "$_dateu" 0

    # Vertical stack, bottom up: hint, temperature band, flaps. The flaps take
    # whatever is left so there is no dead space between them and the weather.
    _hint_h=40
    _gap_v=26
    _box_h=$((H * 28 / 100))
    _box_top=$((H - 14 - _hint_h - _box_h))
    _box_w=$((W - _margin - _margin))

    _band_top=$((_header + _gap_v))
    _band_bot=$((_box_top - _gap_v))
    _cell_h=$((_band_bot - _band_top))

    _area_w=$((W - _margin - _margin))
    _gap=16
    _colon_w=$((_area_w * 7 / 100))
    _cell_w=$(( (_area_w - _gap * 3 - _colon_w) / 4 ))
    # Split-flap cells are tall, but cap the ratio so odd geometries stay sane.
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
        print_ot "$FONT_BOLD" $((_cell_h * 60 / 100)) $((_cells_top + _cell_h / 2 - _cell_h * 60 / 100 * 64 / 100)) "$_margin" "$_margin" "$_time" 1
    else
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_h1"
        _x=$((_x + _cell_w + _gap))
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_h2"
        _x=$((_x + _cell_w + _gap))
        draw_colon "$_x" "$_cells_top" "$_colon_w" "$_cell_h"
        if [ -n "$CLOCK_AMPM" ]; then
            _apx=$((_colon_w * 52 / 100))
            print_ot "$FONT_BOLD" "$_apx" $((_cells_top + _cell_h * 74 / 100)) \
                "$_x" $((W - _x - _colon_w)) "$CLOCK_AMPM" 1
        fi
        _x=$((_x + _colon_w + _gap))
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_m1"
        _x=$((_x + _cell_w + _gap))
        draw_flap "$_x" "$_cells_top" "$_cell_w" "$_cell_h" "$_m2"
    fi

    # Temperature centred, feels-like and humidity flanking it. Each side value
    # is large with a small caption above, so the reading stays legible from a
    # distance while the word stays out of the way. Captions let the values be
    # far bigger than "FEELS 18°C" on one line would allow.
    outline_rect "$_box_top" "$_margin" "$_box_w" "$_box_h" 3
    _cs=$((_box_w * 27 / 100))
    _wtemp=$((_box_h * 70 / 100))
    _wval=$((_box_h * 44 / 100))
    _wlab=$((_box_h * 14 / 100))

    # Everything shares the temperature's baseline: baseline = centre + 0.36em.
    _wbase=$((_box_top + _box_h / 2 + _wtemp * 36 / 100))
    _wval_top=$((_wbase - _wval))
    _wlab_top=$((_wbase - _wval * 72 / 100 - 20 - _wlab))

    _wl_right=$((W - _margin - _cs))
    _wr_left=$((W - _margin - _cs))

    print_ot "$FONT_BOLD" "$_wtemp" $((_wbase - _wtemp)) \
        $((_margin + _cs)) $((_margin + _cs)) "$WEATHER_TEMP" 1

    print_ot "$FONT_REG" "$_wlab" "$_wlab_top" "$_margin" "$_wl_right" "FEELS" 1
    print_ot "$FONT_BOLD" "$_wval" "$_wval_top" "$_margin" "$_wl_right" "$WEATHER_FEELS" 1

    print_ot "$FONT_REG" "$_wlab" "$_wlab_top" "$_wr_left" "$_margin" "HUMIDITY" 1
    print_ot "$FONT_BOLD" "$_wval" "$_wval_top" "$_wr_left" "$_margin" "$WEATHER_HUM" 1

    print_ot "$FONT_REG" 20 $((_box_top + _box_h + 10)) "$_margin" "$_margin" "TAP EXIT OR TAP 3X TO QUIT" 1

    "$FBINK" -q -w -s
}

draw_eips() {
    _time="$1"
    _date="$2"
    _bat="$3"
    eips -c >/dev/null 2>&1
    eips 1 1 "$_date" >/dev/null 2>&1
    eips 2 8 "$_time" >/dev/null 2>&1
    eips 1 16 "$WEATHER_COND $WEATHER_TEMP" >/dev/null 2>&1
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
    log "draw time=$_time date=$_date bat=$_bat weather=$WEATHER_COND $WEATHER_TEMP fbink=$HAVE_FBINK ${VIEW_W}x${VIEW_H}"

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

sleep_until_next_minute() {
    _now=$(date +%s)
    _secs=$((60 - (_now % 60)))
    if [ "$_secs" -lt 3 ]; then
        _secs=$((_secs + 60))
    fi
    log "sleeping ${_secs}s"
    if [ "$USE_SUSPEND" = "1" ]; then
        rtcwake -d /dev/rtc1 -m no -s "$_secs" >> "$LOG" 2>&1
        echo mem > /sys/power/state
    else
        sleep "$_secs"
    fi
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
    probe_one 20 "$FONT_REG" "TAP EXIT OR TAP 3X TO QUIT"
    probe_one 30 "$FONT_REG" "BAT 50%"
    probe_one 38 "$FONT_BOLD" "EXIT"
    probe_one 54 "$FONT_REG" "SUNNY"
    probe_one 68 "$FONT_REG" "MON 17 AUG 2026"
    probe_one 98 "$FONT_BOLD" "20C"
    probe_one 98 "$FONT_BOLD" "20°C"
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
    load_weather_cache

    sleep 2
    stop_gui
    setup_landscape 1
    frontlight_off
    prevent_screensaver

    draw_clock 1
    start_touch_watcher
    update_weather
    draw_clock 0

    _cycle=0
    while true; do
        if [ "$GOT_SIGNAL" = "1" ] || should_stop; then
            log "stop requested"
            break
        fi
        # Flashing refresh periodically to clear accumulated e-ink ghosting.
        _full=0
        if [ $((_cycle % 10)) -eq 0 ]; then
            _full=1
        fi
        if [ $((_cycle % WEATHER_EVERY)) -eq 0 ] && [ "$_cycle" -gt 0 ]; then
            update_weather
        fi
        draw_clock "$_full"
        status "running $_cycle"
        [ $((_cycle % 60)) -eq 0 ] && trim_log
        frontlight_off
        sleep_until_next_minute
        _cycle=$((_cycle + 1))
    done

    trap - USR1
    kill_touch_watcher
    rm -f "$PIDFILE" "$EXIT_FLAG" "$EXIT_RECT"
    start_gui
    status "clock stopped"
    log "clock exit"
}
