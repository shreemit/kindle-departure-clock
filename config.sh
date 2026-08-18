# shellcheck shell=sh
# Edit these values, then restart the clock from KUAL.

# light = black text on white paper. dark = white text on a black board.
THEME="light"

# Typeface. arcade = pixel digits with clear 2/5/6 (Jersey 25).
# retro = classic NES arcade (Press Start 2P). barlow = airport condensed.
FONT="arcade"

# Flap board time. Must stay in HH:MM shape (four digits and a colon).
#   12-hour: %I:%M   adds an AM/PM marker under the colon
#   24-hour: %H:%M
TIME_FORMAT="%I:%M"

# Airport-style date. Size is large on purpose.
DATE_FORMAT="%a %d %b %Y"

# Weather city for wttr.in. Leave empty to guess from IP.
# Examples: Seattle  London  "San Francisco"
WEATHER_CITY="Seattle"

# 1 = turn WiFi on briefly to fetch weather. 0 = only fetch if already online.
WEATHER_WIFI=1

# Minutes between weather refreshes.
WEATHER_EVERY=30

# Seconds to stay on screen during self-test.
DEBUG_SECONDS=20

# 1 = suspend-to-RAM between minute updates. 0 = stay awake (better if plugged in).
USE_SUSPEND=0

# Framebuffer rotate value if the board is sideways after Start.
# auto = try 0,1,2,3 until width > height. Or set 0, 1, 2, or 3.
ROTATE=auto

# Which corner the EXIT box responds to. Only matters if tapping EXIT does
# nothing but "tap 3 times anywhere" works. Try 2, then 3, then 4.
# pw3clock.log prints "tap raw=... fb=..." for every tap to help pick.
TOUCH_MAP=1
