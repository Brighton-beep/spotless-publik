"""The DMG's volume icon: the app icon with a download badge, so "Spotless Installer" on the desktop
never looks like the app itself. Run: python3 scripts/brand/make-installer-icon.py (needs Pillow);
writes scripts/macos/installer-icon.icns."""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ICNS_SRC = os.path.join(ROOT, "src-tauri/icons/icon.icns")  # the Mac app icon, 1024 px slice
OUT = os.path.join(ROOT, "scripts/macos/installer-icon.icns")
S = 1024

def badge(size):
    """Dark disc, white ring, white down-arrow over a bar (the install glyph)."""
    b = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(b)
    d.ellipse((0, 0, size - 1, size - 1), fill=(255, 255, 255, 255))
    r = int(size * 0.05)
    d.ellipse((r, r, size - 1 - r, size - 1 - r), fill=(28, 28, 32, 255))
    w = size * 0.075
    cx = size / 2
    d.rectangle((cx - w / 2, size * 0.24, cx + w / 2, size * 0.56), fill="white")
    d.polygon([(size * 0.30, size * 0.50), (size * 0.70, size * 0.50), (cx, size * 0.70)], fill="white")
    d.rounded_rectangle((size * 0.29, size * 0.76 - w / 2, size * 0.71, size * 0.76 + w / 2), radius=w / 2, fill="white")
    return b

with tempfile.TemporaryDirectory() as t0:
    subprocess.run(["iconutil", "-c", "iconset", ICNS_SRC, "-o", os.path.join(t0, "app.iconset")], check=True)
    base = Image.open(os.path.join(t0, "app.iconset", "icon_512x512@2x.png")).convert("RGBA").resize((S, S), Image.LANCZOS)
bs = int(S * 0.40)
img = base.copy()
img.alpha_composite(badge(bs), (S - bs - int(S * 0.04), S - bs - int(S * 0.04)))

with tempfile.TemporaryDirectory() as t:
    iconset = os.path.join(t, "installer.iconset")
    os.mkdir(iconset)
    for px in (16, 32, 128, 256, 512):
        img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{px}x{px}.png"))
        img.resize((px * 2, px * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{px}x{px}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT], check=True)
    img.save(os.path.join(ROOT, "scripts/macos/installer-icon.png"))
print("wrote", OUT)
