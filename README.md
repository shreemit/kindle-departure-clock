# PW3 Clock

Airport split-flap clock for a **Kindle Paperwhite 3 (7th gen)** on firmware
**5.16.2.1.1**, held in landscape.

```
  MON 17 AUG 2026            [==battery==]   [ EXIT ]

     ┌────┐ ┌────┐   ▪   ┌────┐ ┌────┐
     │ 0  │ │ 2  │       │ 0  │ │ 8  │
     └────┘ └────┘  PM   └────┘ └────┘

   ┌──────────────────────────────────────────┐
   │  FEELS        20°C          HUMIDITY     │
   │  18°C                       62%          │
   └──────────────────────────────────────────┘
              TAP EXIT OR TAP 3X TO QUIT
```

A KUAL extension. Needs no SSH, and no WiFi except to refresh the weather.

Flap corners are square: FBInk draws rectangles, not rounded shapes.

## Install

1. Plug the Kindle in over USB.
2. Copy the whole `pw3clock` folder to `extensions/pw3clock`, replacing any
   earlier copy.
3. Check the path is `extensions/pw3clock/config.xml` — not an extra nested
   `pw3clock/pw3clock/`. KUAL will not see it otherwise.
4. Eject.

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
| `TIME_FORMAT` | `%I:%M` | `%I` is 12-hour and adds AM/PM under the colon. `%H` is 24-hour with no marker. Must stay four digits and a colon. |
| `DATE_FORMAT` | `%a %d %b %Y` | Any busybox `date` format. Drawn in caps. |
| `WEATHER_CITY` | `Seattle` | Empty guesses from your IP. Quote names with spaces. |
| `WEATHER_WIFI` | `1` | `1` briefly enables WiFi to refresh. `0` only fetches if already online. |
| `WEATHER_EVERY` | `30` | Minutes between weather refreshes. |
| `USE_SUSPEND` | `0` | `1` suspends to RAM between minutes to save power. `0` is simpler and fine on mains. |
| `ROTATE` | `auto` | Set `0`–`3` if `auto` leaves the board portrait or upside down. |
| `TOUCH_MAP` | `1` | Only matters if EXIT ignores taps but 3-tap works. Try `2`, `3`, `4`. |
| `DEBUG_SECONDS` | `20` | How long self-test stays on screen. |

## Weather

One request to wttr.in per refresh returns the temperature, feels-like and
humidity together, so the extra readings cost no additional wake time. Metric
only. If a fetch fails the previous values stay on screen.

## Refresh and battery

The screen redraws once a minute, with a flashing full refresh every 10 minutes
to clear e-ink ghosting. Between updates the script sleeps, so it uses no CPU.

The EXIT watcher blocks on the touchscreen rather than polling, so it costs
nothing while idle.

Expect roughly a couple of days on battery. Leave it on a charger for permanent
use, or set `USE_SUSPEND=1`.

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
THEME_OVERRIDE=dark TIME=09:05 TEMP="-15°C" FEELS="-19°C" HUM=88% BAT=8 \
  sh tools/preview.sh out.png
```

Accepted: `THEME_OVERRIDE`, `TIME`, `AMPM`, `DATE`, `BAT`, `TEMP`, `FEELS`,
`HUM`, `COND`, `WIND`, `W`, `H`.

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

Two third-party components are bundled and keep their own licences:

| Component | Licence | Source |
| --- | --- | --- |
| `bin/fbink` | GPL-3.0-or-later | [NiLuJe/FBInk](https://github.com/NiLuJe/FBInk), via the KOReader `kindlepw2` build |
| `fonts/BarlowCondensed-*.ttf` | SIL OFL 1.1 | [jpt/barlow](https://github.com/jpt/barlow) |

The scripts run `fbink` as a separate executable rather than linking against
it, so they are not a derivative work of it. Weather comes from
[wttr.in](https://wttr.in) at runtime. Full detail in `CREDITS`.
