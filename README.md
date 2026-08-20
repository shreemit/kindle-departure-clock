# Kindle Departure Clock

An airport departure-board clock for a **Kindle Paperwhite 3 (7th gen)** on
firmware **5.16.2.1.1**, held in landscape.

```
  17 AUG 2026             87% [====]   [ EXIT ]

     ┌────┐ ┌────┐   ▪   ┌────┐ ┌────┐
    │ 0  │ │ 2  │       │ 0  │ │ 8  │
     └────┘ └────┘  PM   └────┘ └────┘

  RISE 6:12AM   ┌─┐┌─┐┌─┐┌─┐┌─┐┌─┐┌─┐   SET 8:20PM
                │M││T││W││T││F││S││S│

   ┌──────────────────────────────────────────┐
   │  FEELS          AIR          RAIN AT     │
   │  18°C           20°C         9PM         │
   │  WIND 8K NW                  HUM 62%     │
   └──────────────────────────────────────────┘
           OVERCAST · TAP 3X TO QUIT
```

A KUAL extension. Needs no SSH, and no WiFi except to refresh the weather.

Flap corners are square: FBInk draws rectangles, not rounded shapes.

It appears in KUAL as **PW3 Clock**, and installs to `extensions/pw3clock`.
Those names are baked into the scripts and are deliberately left alone.

## Install

1. Plug the Kindle in over USB.
2. Create a folder called `pw3clock` inside `extensions` on the Kindle drive,
   replacing any earlier copy.
3. Copy the *contents* of this repository into it. The folder must be named
   `pw3clock`: that path is baked into the launcher scripts and `menu.json`.
4. Check that `extensions/pw3clock/config.xml` exists, and that you have not
   ended up with a nested `extensions/pw3clock/kindle-departure-clock/`.
   KUAL will not see the extension otherwise.
5. Eject.

Set the Kindle's own clock in Settings first; the board just displays it.

## Run

| Action | How |
| --- | --- |
| Check it works | KUAL → **PW3 Clock** → **1. Self-test** |
| Start | KUAL → **PW3 Clock** → **2. Start clock** |
| Stop | Tap **EXIT**, or tap anywhere **3 times** |

Starting stops the Kindle UI so the board can keep the screen, and rotates the
framebuffer to landscape. **Turn the Kindle sideways** — EXIT belongs in the
top-right.

The self-test draws over the running Kindle UI for 20 seconds without stopping
it, and writes `pw3clock.log` to the Kindle's drive root. Run it first.

### Stopping

Tapping **EXIT** is the normal way. Tapping **anywhere 3 times** within a few
seconds also works and needs no touch-coordinate mapping, so it is the reliable
fallback if EXIT is not registering on your device.

If neither responds, hold **power for ~10 seconds**, or plug in over USB and
create an empty file named `pw3clock.STOP` in the drive root.

## Settings

All in `extensions/pw3clock/config.sh`. Restart the clock to apply.

| Setting | Default | Notes |
| --- | --- | --- |
| `THEME` | `light` | `light` is black on white. `dark` is white on black. |
| `FONT` | `arcade` | `arcade` = Jersey 25 pixel (clearest digits). `retro` = Press Start 2P. `barlow` = airport condensed. |
| `TIME_FORMAT` | `%I:%M` | `%I` is 12-hour and adds AM/PM under the colon. `%H` is 24-hour with no marker. Must stay four digits and a colon. |
| `DATE_FORMAT` | `%a %d %b %Y` | Any busybox `date` format. Drawn in caps. |
| `WEATHER_CITY` | `Seattle` | Empty guesses from your IP. Quote names with spaces. |
| `WEATHER_WIFI` | `1` | `1` briefly enables WiFi to refresh. `0` only fetches if already online. Radio is always turned off after a fetch. |
| `WEATHER_EVERY` | `60` | Minutes between weather refreshes. Skipped during quiet hours. |
| `FULL_REFRESH_EVERY` | `60` | Minutes between flashing full refreshes during the day. Skipped while quiet. |
| `QUIET_START` / `QUIET_END` | `03:00` / `07:00` | Quiet window (24h `HH:MM`). Empty `QUIET_START` disables quiet hours. |
| `QUIET_CLOCK_EVERY` | `5` | Minutes between clock updates while quiet. |
| `USE_SUSPEND` | `1` | `1` suspends to RAM between ticks. Unplug USB first. `0` if plugged in. |
| `ROTATE` | `auto` | Set `0`–`3` if `auto` leaves the board portrait or upside down. |
| `TOUCH_MAP` | `1` | Only matters if EXIT ignores taps but 3-tap works. Try `2`, `3`, `4`. |
| `DEBUG_SECONDS` | `20` | How long self-test stays on screen. |

## Weather

One request to wttr.in per refresh returns current conditions plus today's
hourly chance of rain, so the extra readings cost no additional wake time.
Metric only. If a fetch fails the previous values stay on screen.

The right-hand complication is Seattle-flavoured rain, not humidity:

| On screen | Meaning |
| --- | --- |
| `RAIN` / `NOW` | Raining |
| `DRIZZLE` / `NOW` | Fine Seattle rain |
| `RAIN AT` / `6PM` | Dry now; rain likely from that hour (≥40%) |
| `CLOUDY` / `DRY` | Overcast, no rain coming |
| `DRY` / `CLEAR` | Sunny, no rain coming |

Humidity, wind, sunrise and sunset are secondary. The weekday strip is Monday–Sunday, with today filled. Date is `17 AUG` at primary size; the weekday lives on that strip.

## Refresh and battery

The screen redraws once a minute by day, and every `QUIET_CLOCK_EVERY`
minutes between `QUIET_START` and `QUIET_END` (default 03:00–07:00). A flashing
full refresh runs about once an hour during the day to clear e-ink ghosting;
weather uses the same hourly cadence and is skipped while quiet. Between ticks
the script suspends to RAM when `USE_SUSPEND=1`, so the CPU and radio stay cold.

WiFi is only brought up for a weather fetch, then turned off again.

The EXIT watcher blocks on the touchscreen rather than polling, so it costs
nothing while idle.

Expect roughly several days on battery with suspend on; leave it on a charger
for permanent use, or set `USE_SUSPEND=0` while plugged in (suspend fails over
USB).

## Previewing on your computer

Renders the board to a PNG without touching the Kindle, using the same layout
code from `bin/clock.sh`:

```
sh tools/preview.sh out.png
```

One-time setup, from the repo root:

```
python3 -m venv .venv && ./.venv/bin/pip install Pillow
```

Defaults to the live time in your configured format. Override anything:

```
THEME_OVERRIDE=dark FONT_OVERRIDE=barlow TIME=09:05 TEMP="-15°C" FEELS="-19°C" HUM=88% BAT=8 \
  sh tools/preview.sh out.png
```

Accepted: `THEME_OVERRIDE`, `FONT_OVERRIDE`, `TIME`, `AMPM`, `DATE`, `BAT`, `TEMP`, `FEELS`,
`HUM`, `COND`, `WIND`, `PRECIP`, `HOURLY`, `RAIN`, `RAIN_LABEL`, `RISE`, `SET`, `W`, `H`.

`tools/fbink-sim.py` stands in for the FBInk CLI. It deliberately reproduces
FBInk's failure modes — refusing text that will not fit its margins, and
rejecting strings that begin with a dash — so those bugs surface locally instead
of as blank or overlapping boxes on the device. `preview.sh` prints the reason
when a call is rejected.

`tools/` is desktop-only. Copying it to the Kindle is harmless.

## Troubleshooting

Everything is logged to `pw3clock.log` in the Kindle's drive root, readable over
USB. It self-trims past 256 KB.

**Blank or empty boxes.** A text call was rejected. The log records
`print failed ... err=` naming the string and the reason. That element falls
back to the built-in bitmap font; the rest of the board is unaffected.

**Board is portrait, or upside down.** Set `ROTATE` to `0`–`3` in `config.sh`.

**EXIT does nothing.** Use the 3-tap gesture. The log records
`tap raw=... fb=...` for every tap; compare `fb=` against the EXIT box position
it logs at startup and set `TOUCH_MAP` accordingly.

**Nothing happens at all, no log.** The folder is probably nested one level too
deep. Check `extensions/pw3clock/config.xml` exists.

### If you modify the drawing code

Two FBInk behaviours cause most of the trouble:

- Font size in `-t` is `px=` for pixels. `size=` is **points**, which at this
  screen's 300 DPI is about 4× larger than intended and gets rejected.
- Always pass text after `--`. Otherwise a reading like `-15°C` is parsed as a
  command-line flag, and FBInk replies with its entire usage text.

Text is laid out downward from the `top` margin, and needs room for the full
line height — roughly 1.25× the em size — not just the em size.

## Licence

This project's own code — everything under `bin/` and `tools/`, plus the KUAL
extension metadata — is [MIT licensed](LICENSE).

Third-party components are bundled and keep their own licences:

| Component | Licence | Source |
| --- | --- | --- |
| `bin/fbink` | GPL-3.0-or-later | [NiLuJe/FBInk](https://github.com/NiLuJe/FBInk), via the KOReader `kindlepw2` build |
| `fonts/BarlowCondensed-*.ttf` | SIL OFL 1.1 | [jpt/barlow](https://github.com/jpt/barlow) |
| `fonts/Jersey25-Regular.ttf` | SIL OFL 1.1 | [Google Fonts / Jersey 25](https://github.com/google/fonts/tree/main/ofl/jersey25) |
| `fonts/PressStart2P-Regular.ttf` | SIL OFL 1.1 | [CodeMan38 / Press Start 2P](https://github.com/google/fonts/tree/main/ofl/pressstart2p) |

The scripts run `fbink` as a separate executable rather than linking against
it, so they are not a derivative work of it. Weather comes from
[wttr.in](https://wttr.in) at runtime. Full detail in `CREDITS`.
