#!/usr/bin/env python3
"""Desktop stand-in for the FBInk CLI so the Kindle board can be previewed locally.

Each call mutates a persistent PNG canvas, mirroring how clock.sh invokes fbink
as a separate process per drawing primitive. Only the flags clock.sh actually
uses are implemented.

Margin handling deliberately reproduces FBInk's behaviour of refusing to render
a string that cannot fit, so layout bugs surface here instead of on the device.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

GRAY = {
    "BLACK": 0, "GRAY1": 17, "GRAY2": 34, "GRAY3": 51, "GRAY4": 68,
    "GRAY5": 85, "GRAY6": 102, "GRAY7": 119, "GRAY8": 136, "GRAY9": 153,
    "GRAYA": 170, "GRAYB": 187, "GRAYC": 204, "GRAYD": 221, "GRAYE": 238,
    "WHITE": 255,
}

CANVAS = os.environ.get("FBINK_SIM_CANVAS", "/tmp/fbink-sim.png")
VIEW_W = int(os.environ.get("FBINK_SIM_W", "1448"))
VIEW_H = int(os.environ.get("FBINK_SIM_H", "1072"))
MONO = os.environ.get("FBINK_SIM_MONO", "/System/Library/Fonts/Menlo.ttc")


def color(name, default):
    return GRAY.get(str(name).upper(), default)


def subopts(raw):
    out = {}
    for part in raw.split(","):
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
        else:
            out[part.strip()] = True
    return out


def load_canvas():
    if os.path.exists(CANVAS):
        img = Image.open(CANVAS).convert("L")
        if img.size == (VIEW_W, VIEW_H):
            return img
    return Image.new("L", (VIEW_W, VIEW_H), 255)


def state_dump():
    return (
        "FBINK_VERSION='sim';FBINK_TARGET=1;"
        f"viewWidth={VIEW_W};viewHeight={VIEW_H};"
        f"screenWidth={VIEW_W};screenHeight={VIEW_H};"
        "DPI=300;BPP=8;FONTW=8;FONTH=8;FONTNAME='IBM';"
        "deviceName='PaperWhite 3';deviceCodename='muscat';"
    )


def parse(argv):
    o = {
        "eval": False, "clear": False, "centered": False,
        "fg": 0, "bg": 255, "tt": None, "mult": 0,
        "x": 0, "y": 0, "X": 0, "Y": 0,
        "cls": None, "text": [],
    }
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-q", "-b", "-w", "-f", "-O", "-h", "-v"):
            pass
        elif a == "-e":
            o["eval"] = True
        elif a == "-c":
            o["clear"] = True
        elif a == "-m":
            o["centered"] = True
        elif a in ("-C", "-B"):
            i += 1
            key = "fg" if a == "-C" else "bg"
            o[key] = color(argv[i], 0 if a == "-C" else 255)
        elif a == "-t":
            i += 1
            o["tt"] = subopts(argv[i])
        elif a in ("-S", "-x", "-y", "-X", "-Y"):
            i += 1
            key = {"-S": "mult"}.get(a, a.lstrip("-"))
            o[key] = int(argv[i])
        elif a == "--":
            o["text"].extend(argv[i + 1:])
            break
        elif a.startswith("-k") or a.startswith("-s"):
            # Optional-argument flags: value may be attached or a separate token.
            val = a[2:]
            if not val and i + 1 < len(argv) and "=" in argv[i + 1]:
                i += 1
                val = argv[i]
            if a.startswith("-k"):
                o["cls"] = subopts(val) if val else {}
        elif a.startswith("-") and a != "-":
            # Matches FBInk: an unknown dash-led token is a bad flag, not text.
            # Reproduces the failure for strings like "---" or "-7°C".
            raise ValueError(f"unrecognized option '{a}'")
        else:
            o["text"].append(a)
        i += 1
    return o


def draw_tt(img, o):
    tt = o["tt"]
    px = int(tt.get("px") or 0)
    if not px:
        # size= is points; FBInk converts at the panel's DPI.
        px = int(float(tt.get("size", 12)) * 300 / 72)
    top = int(tt.get("top", 0))
    bottom = int(tt.get("bottom", 0))
    left = int(tt.get("left", 0))
    right = int(tt.get("right", 0))

    if left + right >= VIEW_W or top + bottom >= VIEW_H:
        sys.stderr.write("A margin was out of range\n")
        return 1

    path = tt.get("regular") or tt.get("bold")
    if not path or not os.path.exists(path):
        sys.stderr.write(f"Failed to open font {path}\n")
        return 1
    font = ImageFont.truetype(path, px)
    ascent, descent = font.getmetrics()
    line_h = ascent + descent

    avail_h = VIEW_H - top - bottom
    if line_h > avail_h:
        sys.stderr.write(
            f"Not enough vertical space: need {line_h}px, have {avail_h}px\n")
        return 1

    text = " ".join(o["text"])
    box_l, box_r = left, VIEW_W - right
    d = ImageDraw.Draw(img)
    w = d.textlength(text, font=font)
    x = box_l + (box_r - box_l - w) / 2 if o["centered"] else box_l
    d.text((x, top + ascent), text, font=font, fill=o["fg"], anchor="ls")
    return 0


def draw_bitmap(img, o):
    mult = o["mult"] or 1
    px = 8 * mult
    try:
        font = ImageFont.truetype(MONO, px)
    except OSError:
        font = ImageFont.load_default()
    text = " ".join(o["text"])
    d = ImageDraw.Draw(img)
    top = o["Y"] + o["y"] * px
    if o["centered"]:
        w = d.textlength(text, font=font)
        x = (VIEW_W - w) / 2
    else:
        x = o["X"] + o["x"] * (px // 2)
    d.text((x, top), text, font=font, fill=o["fg"], anchor="lt")
    return 0


def main():
    try:
        o = parse(sys.argv[1:])
    except ValueError as exc:
        sys.stderr.write(f"fbink-sim: {exc}\n")
        return 1
    if o["eval"]:
        print(state_dump())
        return 0

    img = load_canvas()
    rc = 0

    if o["cls"] is not None:
        c = o["cls"]
        if c:
            t, l = int(c.get("top", 0)), int(c.get("left", 0))
            w, h = int(c.get("width", VIEW_W)), int(c.get("height", VIEW_H))
        else:
            t = l = 0
            w, h = VIEW_W, VIEW_H
        ImageDraw.Draw(img).rectangle([l, t, l + w - 1, t + h - 1], fill=o["bg"])
        img.save(CANVAS)
        return 0

    if o["clear"]:
        ImageDraw.Draw(img).rectangle([0, 0, VIEW_W, VIEW_H], fill=o["bg"])

    if o["text"]:
        rc = draw_tt(img, o) if o["tt"] else draw_bitmap(img, o)

    img.save(CANVAS)
    return rc


if __name__ == "__main__":
    sys.exit(main())
