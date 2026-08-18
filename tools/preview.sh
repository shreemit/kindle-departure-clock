#!/bin/sh
# Render the board locally to a PNG, using the real layout code from clock.sh.
#
#   tools/preview.sh [output.png]
#
# Env overrides:
#   THEME_OVERRIDE=dark  FONT_OVERRIDE=barlow  TIME=09:05  DATE="Mon 17 Aug 2026"
#   BAT=50  COND=SUNNY  TEMP=20°C  WIND="8 KM/H"  W=1448  H=1072

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

OUT=${1:-/tmp/pw3clock-preview.png}
W=${W:-1448}
H=${H:-1072}

SCRATCH="$ROOT/tools/.preview"
mkdir -p "$SCRATCH"

export FBINK_SIM_CANVAS="$OUT"
export FBINK_SIM_W="$W"
export FBINK_SIM_H="$H"
export EXT_DIR="$ROOT"
export PW3_TMP="$SCRATCH"
export LOG="$SCRATCH/preview.log"
export LOG2=/dev/null

rm -f "$OUT"
: > "$LOG"

# shellcheck disable=SC1091
. "$ROOT/bin/clock.sh"

FBINK="$ROOT/tools/fbink"
HAVE_FBINK=1
VIEW_W=$W
VIEW_H=$H

load_config
if [ -n "$THEME_OVERRIDE" ]; then
    THEME="$THEME_OVERRIDE"
    apply_theme
fi
if [ -n "$FONT_OVERRIDE" ]; then
    FONT="$FONT_OVERRIDE"
fi
pick_font

# Default to the live clock rendered through the configured formats, so the
# preview reflects config.sh rather than a hardcoded sample.
: "${TIME:=$(date "+$TIME_FORMAT")}"
: "${DATE:=$(date "+$DATE_FORMAT")}"
if [ "$SHOW_AMPM" = "1" ]; then
    CLOCK_AMPM=${AMPM:-$(date +%p | tr 'a-z' 'A-Z')}
fi

WEATHER_COND=${COND:-OVERCAST}
WEATHER_TEMP=${TEMP:-20°C}
WEATHER_WIND=${WIND:-8K NW}
WEATHER_FEELS=${FEELS:-18°C}
WEATHER_HUM=${HUM:-62%}
WEATHER_PRECIP=${PRECIP:-0.0}
WEATHER_HOURLY=${HOURLY:-"0:10 300:10 600:10 900:12 1200:15 1500:20 1800:70 2100:40"}
WEATHER_RISE=${RISE:-6:12AM}
WEATHER_SET=${SET:-8:20PM}
if [ -n "${RAIN:-}" ]; then
    WEATHER_RAIN=$RAIN
    WEATHER_RAIN_LABEL=${RAIN_LABEL:-DRY}
else
    compute_seattle_rain
fi

draw_airport "$TIME" "$DATE" "${BAT:-50}" 1

if grep -q "print failed" "$LOG" 2>/dev/null; then
    echo "!! text calls were rejected:"
    grep "print failed" "$LOG"
fi

echo "$OUT"
