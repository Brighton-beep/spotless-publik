#!/usr/bin/env python3
"""The owner's Spotless mark: a dark-pink disc on a black tile, a black beamed pair of eighth
notes inside it. This file constructs the note and writes the master SVG.

    python3 scripts/brand/final.py master [#RRGGBB]   # assets/brand/spotless.svg
    python3 scripts/brand/final.py shades <out.png>   # shade options side by side

Construction (100 box, disc r = 40 at the centre, so the disc is 80 % of the tile):
  heads   ellipses 8.5 x 6.2, tilted -22 deg, the second 5.5 higher (the beam rises with it)
  stems   3.9 wide, flush with each head's rightmost point, running up into the beam
  beam    a parallelogram 8.0 thick, ends cut vertically flush with the stems' outer edges
  centre  the glyph's area centroid (its visual mass), not its bounding box, sits on the disc's
          centre, nudged 1 unit up because the heads carry the weight low; then scaled 1.12.
"""
import math, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

TILE = "#000000"
NOTE = "#000000"
PINK = "#FF2D7A"          # chosen shade (see `shades`): owner asked for a brighter, high-contrast pink
SHADES = [("Hot pink", "#FF2D7A"), ("Magenta pink", "#F72585"), ("Rose", "#FF3D8B")]
DISC_R = 40.0

HEAD_RX, HEAD_RY, HEAD_ROT = 8.5, 6.2, -22.0
STEM_W, BEAM_T = 3.9, 8.0
H1 = (0.0, 0.0)           # head centres (local units; y down)
H2 = (20.5, -5.5)
STEM_TOP = -33.5          # top of the beam at the first stem


def ell_pts(cx, cy, n=96):
    a = math.radians(HEAD_ROT)
    return [(cx + HEAD_RX * math.cos(t) * math.cos(a) - HEAD_RY * math.sin(t) * math.sin(a),
             cy + HEAD_RX * math.cos(t) * math.sin(a) + HEAD_RY * math.sin(t) * math.cos(a))
            for t in (2 * math.pi * i / n for i in range(n))]


def rightmost(cx, cy):
    a = math.radians(HEAD_ROT)
    t = math.atan2(-HEAD_RY * math.sin(a), HEAD_RX * math.cos(a))
    return (cx + HEAD_RX * math.cos(t) * math.cos(a) - HEAD_RY * math.sin(t) * math.sin(a),
            cy + HEAD_RX * math.cos(t) * math.sin(a) + HEAD_RY * math.sin(t) * math.cos(a))


def shapes():
    """The glyph as polygons (local units), all clockwise in screen space."""
    polys = []
    slope = (H2[1] - H1[1]) / (H2[0] - H1[0])  # the beam rises with the heads
    tops = []
    for (cx, cy) in (H1, H2):
        polys.append(ell_pts(cx, cy))
        rx, ry = rightmost(cx, cy)
        x0, x1 = rx - STEM_W, rx
        top = STEM_TOP + slope * (x0 - (rightmost(*H1)[0] - STEM_W))
        polys.append([(x0, top + BEAM_T / 2), (x1, top + BEAM_T / 2), (x1, ry), (x0, ry + 0.6)])
        tops.append((x0, x1))
    bx0, bx1 = tops[0][0], tops[1][1]
    y0 = STEM_TOP
    y1 = STEM_TOP + slope * (bx1 - bx0)
    polys.append([(bx0, y0), (bx1, y1), (bx1, y1 + BEAM_T), (bx0, y0 + BEAM_T)])
    return polys


def inside(pt, poly):
    x, y = pt; c = False
    for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            c = not c
    return c


def centroid(polys, step=0.25):
    xs = [p[0] for poly in polys for p in poly]; ys = [p[1] for poly in polys for p in poly]
    sx = sy = n = 0
    y = min(ys)
    while y < max(ys):
        x = min(xs)
        while x < max(xs):
            if any(inside((x, y), p) for p in polys):
                sx += x; sy += y; n += 1
            x += step
        y += step
    return sx / n, sy / n, (min(xs), min(ys), max(xs), max(ys))


SCALE = 1.12   # glyph size in the disc (about 58 % of its diameter wide, 62 % tall)


def note_path():
    """The glyph as one path in the 100 box, scaled and mass-centred on the disc."""
    polys = shapes()
    cx, cy, _ = centroid(polys)
    T = lambda x, y: (50 + (x - cx) * SCALE, 49 + (y - cy) * SCALE)
    d = ""
    rx, ry = HEAD_RX * SCALE, HEAD_RY * SCALE
    for (hx, hy) in (H1, H2):
        p = [T(*q) for q in ell_pts(hx, hy, 4)]
        d += f"M{p[0][0]:.2f} {p[0][1]:.2f}"
        for q in p[1:] + p[:1]:
            d += f"A{rx:.3f} {ry:.3f} {HEAD_ROT} 0 1 {q[0]:.2f} {q[1]:.2f}"
        d += "Z"
    for poly in [polys[1], polys[3], polys[4]]:
        d += "M" + "L".join("%.2f %.2f" % T(x, y) for x, y in poly) + "Z"
    return d


def master(pink=PINK):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">'
            f'<rect id="bg" width="100" height="100" fill="{TILE}"/>'
            f'<g id="mark"><circle id="disc" cx="50" cy="50" r="{DISC_R:g}" fill="{pink}"/>'
            f'<path id="note" fill="{NOTE}" d="{note_path()}"/></g></svg>\n')


def shades(out):
    import importlib.util
    spec = importlib.util.spec_from_file_location("gb", HERE / "gen-brand.py")
    gb = importlib.util.module_from_spec(spec); spec.loader.exec_module(gb)
    W, H = 1500, 900
    b = [f'<rect width="{W}" height="{H}" fill="#F2F2F7"/>', f'<rect y="330" width="{W}" height="300" fill="#1C1C1E"/>',
         '<defs><linearGradient id="wall" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2B3A67"/>'
         '<stop offset="1" stop-color="#B06AB3"/></linearGradient></defs>',
         f'<rect y="630" width="{W}" height="270" fill="url(#wall)"/>']
    for i, (name, hexc) in enumerate(SHADES):
        m = master(hexc)
        x0 = 40 + i * 490
        b.append(gb.framed(m, x0, 30, 240))
        for sz, oy in ((64, 0), (32, 84), (16, 136)):
            b.append(gb.framed(m, x0 + 270, 60 + oy, sz))
        tag = "  (shipped)" if hexc == PINK else ""
        b.append(f'<text x="{x0}" y="300" font-family="Helvetica Neue" font-size="22" fill="#1C1C1E">{name} {hexc}{tag}</text>')
        b.append(gb.framed(m, x0, 370, 180))
        for sz, oy in ((64, 0), (32, 84), (16, 136)):
            b.append(gb.framed(m, x0 + 210, 380 + oy, sz))
        b.append(f'<rect x="{x0 - 10}" y="680" width="300" height="100" rx="26" fill="#fff" fill-opacity="0.22"/>')
        for k in range(3):
            b.append(gb.framed(m, x0 + 8 + k * 96, 698, 64) if k == 1 else
                     f'<rect x="{x0 + 8 + k * 96}" y="698" width="64" height="64" rx="14" fill="{["#0A84FF", "#FF9F0A"][k // 2]}"/>')
    r = gb.Renderer()
    try:
        r.add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">{"".join(b)}</svg>',
              out, f"{W}x{H}")
        r.run()
    finally:
        r.close()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "master":
        pink = sys.argv[2] if len(sys.argv) > 2 else PINK
        p = ROOT / "assets/brand/spotless.svg"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(master(pink)); print("wrote", p)
    elif cmd == "shades":
        shades(sys.argv[2])
    else:
        sys.exit(__doc__)
