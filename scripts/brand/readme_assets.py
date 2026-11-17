#!/usr/bin/env python3
"""Compose the README / website images in docs/readme/ from raw captures (needs Pillow).

    python3 scripts/brand/readme_assets.py <mac shots dir> <iPhone App Store shots dir>

  <mac shots dir>     2880x1800 captures of the Mac UI made by scripts/brand/readme-mac-shots.sh
                      (mac-home.png, mac-album.png): the dev mock with a fictional catalogue.
  <iPhone shots dir>  the captioned 6.9" App Store screenshots (01-home.png ... 08-import.png),
                      which also use a fictional catalogue.

Writes docs/readme/{hero,mac-home,mac-album,iphone-row,iphone-more,download-mac}.png, plus
mac-home-2x.png and mac-album-2x.png (full 2x size, for the website), squeezing the big ones with
pngquant when it is installed. Every image has a transparent outside, so it sits well on both
GitHub themes.
"""
import shutil, subprocess, sys
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "readme"
FONTS = ROOT / "ios" / "Encore" / "Encore" / "Resources" / "Fonts"
ICON = ROOT / "src-tauri" / "icons" / "icon.png"
PINK = (255, 45, 122)
BG = (11, 11, 13)


def font(weight, size):
    return ImageFont.truetype(str(FONTS / f"Figtree-{weight}.ttf"), size)


def rounded_mask(size, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), r, fill=255)
    return m


def glow(size, centre, radius, colour, strength):
    """A soft radial glow as an RGBA layer."""
    layer = Image.new("RGBA", size, colour + (0,))
    a = Image.new("L", size, 0)
    cx, cy = centre
    ImageDraw.Draw(a).ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=strength)
    layer.putalpha(a.filter(ImageFilter.GaussianBlur(radius * 0.55)))
    return layer


def drop_shadow(img, pad, blur, dy, opacity):
    """img (RGBA) on a transparent canvas `pad` larger on each side, with a soft shadow."""
    w, h = img.size
    canvas = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    sh = Image.new("L", canvas.size, 0)
    sh.paste(img.getchannel("A").point(lambda v: v * opacity // 255), (pad, pad + dy))
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    canvas.putalpha(sh)
    canvas.alpha_composite(img, (pad, pad))
    return canvas


def hero():
    W, H = 1760, 600
    img = Image.new("RGBA", (W, H), BG + (255,))
    img.alpha_composite(glow((W, H), (W // 2, H // 2 + 40), 420, PINK, 70))
    img.alpha_composite(glow((W, H), (W // 2 - 380, H // 2), 200, PINK, 90))
    # Faint grain-free vignette towards the edges.
    vig = Image.new("L", (W, H), 0)
    ImageDraw.Draw(vig).rectangle((0, 0, W, H), fill=90)
    ImageDraw.Draw(vig).rounded_rectangle((90, 60, W - 90, H - 60), 200, fill=0)
    black = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    black.putalpha(vig.filter(ImageFilter.GaussianBlur(80)))
    img.alpha_composite(black)

    icon = Image.open(ICON).convert("RGBA").resize((236, 236), Image.LANCZOS)
    title_f, tag_f, sub_f = font("Black", 150), font("SemiBold", 44), font("Medium", 32)
    d = ImageDraw.Draw(img)
    title = "Spotless"
    tag = "Music, podcasts and audiobooks."
    sub = "Free. No ads. No account."
    tw = d.textbbox((0, 0), title, font=title_f)[2]
    gw = max(tw, d.textbbox((0, 0), tag, font=tag_f)[2])
    gap = 64
    x0 = (W - (236 + gap + gw)) // 2
    iy = (H - 236) // 2
    # Icon with its own pink halo.
    img.alpha_composite(glow((W, H), (x0 + 118, iy + 118), 170, PINK, 110))
    img.alpha_composite(icon, (x0, iy))
    tx = x0 + 236 + gap
    d = ImageDraw.Draw(img)
    d.text((tx - 6, iy - 30), title, font=title_f, fill=(255, 255, 255))
    d.text((tx, iy + 150), tag, font=tag_f, fill=(236, 236, 240))
    # "Free. No ads. No account." with the dots in pink.
    x = tx
    for word in sub.split(" "):
        body = word.rstrip(".")
        d.text((x, iy + 210), body, font=sub_f, fill=(170, 170, 178))
        x += d.textlength(body, font=sub_f)
        if word.endswith("."):
            d.text((x, iy + 210), ".", font=sub_f, fill=PINK)
            x += d.textlength(".", font=sub_f)
        x += d.textlength(" ", font=sub_f)
    img.putalpha(rounded_mask((W, H), 40))
    # Hairline edge so the card reads on a dark GitHub page too.
    edge = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, W - 1, H - 1), 40, outline=(255, 255, 255, 28), width=2)
    img.alpha_composite(edge)
    return img


def mac_window(path, out_w=1800):  # out_w None: keep the capture's 2x scale
    """A 2880x1800 capture as a macOS window: rounded corners, traffic lights over the top bar
    (where the app puts them: 20 pt in, centred on its 64 pt bar), hairline edge, soft shadow."""
    shot = Image.open(path).convert("RGBA")
    W, H = shot.size
    s = W / 1440  # pixels per point
    d = ImageDraw.Draw(shot)
    for i, (fill, rim) in enumerate([((255, 95, 87), (224, 68, 62)), ((254, 188, 46), (222, 161, 35)),
                                      ((40, 200, 64), (29, 173, 43))]):
        cx, cy, r = (26 + 20 * i) * s, 32 * s, 6 * s
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill, outline=rim, width=max(1, round(0.5 * s)))
    radius = round(12 * s)
    shot.putalpha(rounded_mask((W, H), radius))
    edge = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, W - 1, H - 1), radius, outline=(255, 255, 255, 46), width=round(s))
    shot.alpha_composite(edge)
    pad = 200
    framed = drop_shadow(shot, pad, 70, 40, 150)
    if out_w is None:
        return framed
    k = out_w / framed.width
    return framed.resize((out_w, round(framed.height * k)), Image.LANCZOS)


def phone_row(paths, out_w=1760, gap=36):
    n = len(paths)
    pw = (out_w - gap * (n - 1)) // n
    ims = []
    for p in paths:
        im = Image.open(p).convert("RGBA")
        im = im.resize((pw, round(im.height * pw / im.width)), Image.LANCZOS)
        im.putalpha(rounded_mask(im.size, round(pw * 0.075)))
        ims.append(im)
    ph = ims[0].height
    row = Image.new("RGBA", (out_w, ph), (0, 0, 0, 0))
    for i, im in enumerate(ims):
        row.alpha_composite(im, (i * (pw + gap), 0))
    return drop_shadow(row, 40, 22, 14, 110)


def button(label="Download for Mac", note="Free  ·  macOS 13.3+"):
    """A pink pill (2x) for the README's download link, since GitHub markdown cannot style one."""
    H, f, nf = 128, font("Bold", 46), font("SemiBold", 30)
    d0 = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    lw, nw = d0.textlength(label, font=f), d0.textlength(note, font=nf)
    icon, gap = 40, 22
    W = round(56 + icon + gap + lw + 34 + nw + 56)
    pad = 24
    img = Image.new("RGBA", (W, H), PINK + (255,))
    # Gentle top-to-bottom sheen.
    sheen = Image.linear_gradient("L").resize((W, H)).point(lambda v: 40 - v * 40 // 255)
    white = Image.new("RGBA", (W, H), (255, 255, 255, 0)); white.putalpha(sheen)
    img.alpha_composite(white)
    d = ImageDraw.Draw(img)
    x, cy = 56, H // 2
    # Download arrow into a tray.
    lw2 = 6
    d.line((x + icon / 2, cy - 22, x + icon / 2, cy + 8), fill="white", width=lw2)
    d.line((x + icon / 2 - 13, cy - 5, x + icon / 2, cy + 9, x + icon / 2 + 13, cy - 5), fill="white", width=lw2, joint="curve")
    d.line((x + 2, cy + 22, x + icon - 2, cy + 22), fill="white", width=lw2)
    x += icon + gap
    d.text((x, cy), label, font=f, fill="white", anchor="lm")
    x += lw + 17
    d.line((x, cy - 24, x, cy + 24), fill=(255, 255, 255, 110), width=2)
    d.text((x + 17, cy + 1), note, font=nf, fill=(255, 235, 243), anchor="lm")
    img.putalpha(rounded_mask((W, H), H // 2))
    return drop_shadow(img, pad, 12, 6, 90)


def save(img, name):
    p = OUT / name
    img.save(p, optimize=True)
    if shutil.which("pngquant") and p.stat().st_size > 300 * 1024:
        subprocess.run(["pngquant", "--force", "--skip-if-larger", "--quality=75-95", "--speed=1",
                        "--strip", "--output", str(p), str(p)], check=False)
    print(f"{p.relative_to(ROOT)}  {img.size[0]}x{img.size[1]}  {p.stat().st_size // 1024} KB")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    mac, phones = Path(sys.argv[1]), Path(sys.argv[2])
    OUT.mkdir(parents=True, exist_ok=True)
    save(hero(), "hero.png")
    save(mac_window(mac / "mac-home.png"), "mac-home.png")
    save(mac_window(mac / "mac-album.png"), "mac-album.png")
    save(phone_row([phones / f for f in ("01-home.png", "02-now-playing.png", "06-podcast.png", "05-library.png")]),
         "iphone-row.png")
    save(phone_row([phones / f for f in ("03-lyrics.png", "04-search.png", "07-audiobooks.png", "08-import.png")]),
         "iphone-more.png")
    save(button(), "download-mac.png")
    # Full-size (2x) framed Mac shots for the website to reuse.
    for n in ("mac-home", "mac-album"):
        save(mac_window(mac / f"{n}.png", out_w=None), f"{n}-2x.png")


if __name__ == "__main__":
    main()
