#!/usr/bin/env python3
"""Spotless logo, round 2: 12 explorations + 3 refined finalists (review sheets only, nothing ships).

    python3 scripts/brand/round2.py <out dir>

Every mark is a hand-constructed master in a 1024 box (full bleed; the platform frame rounds it).
No fonts or Unicode symbols in any mark; labels on the review sheets only.
"""
import math, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import importlib.util
_spec = importlib.util.spec_from_file_location("gb", Path(__file__).resolve().parent / "gen-brand.py")
gb = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(gb)

F = lambda v: f"{v:.2f}"


# --- geometry helpers ----------------------------------------------------------------------------

def rot(x, y, cx, cy, a):
    c, s = math.cos(a), math.sin(a)
    return cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c


def ell(cx, cy, rx, ry, deg, ccw=False):
    """Ellipse as a 4-arc path, rotated `deg`; ccw reverses winding (to punch holes)."""
    a = math.radians(deg)
    ts = [0, 0.5, 1, 1.5] if not ccw else [0, -0.5, -1, -1.5]
    pts = [(cx + rx * math.cos(t * math.pi) * math.cos(a) - ry * math.sin(t * math.pi) * math.sin(a),
            cy + rx * math.cos(t * math.pi) * math.sin(a) + ry * math.sin(t * math.pi) * math.cos(a)) for t in ts]
    sweep = 0 if ccw else 1
    d = f"M{F(pts[0][0])} {F(pts[0][1])}"
    for p in pts[1:] + pts[:1]:
        d += f"A{rx} {ry} {deg} 0 {sweep} {F(p[0])} {F(p[1])}"
    return d + "Z"


def ell_extreme_right(cx, cy, rx, ry, deg):
    a = math.radians(deg)
    t = math.atan2(-ry * math.sin(a), rx * math.cos(a))
    return (cx + rx * math.cos(t) * math.cos(a) - ry * math.sin(t) * math.sin(a),
            cy + rx * math.cos(t) * math.sin(a) + ry * math.sin(t) * math.cos(a))


def cubic(p0, p1, p2, p3, n=60):
    out = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        out.append((mt ** 3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t ** 3 * p3[0],
                    mt ** 3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t ** 3 * p3[1]))
    return out


def dist_to_poly(p, pts):
    best = 1e9
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        dx, dy = bx - ax, by - ay
        L = dx * dx + dy * dy or 1e-9
        t = max(0, min(1, ((p[0] - ax) * dx + (p[1] - ay) * dy) / L))
        best = min(best, math.hypot(p[0] - ax - t * dx, p[1] - ay - t * dy))
    return best


def smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def lin(gid, stops, x1=0, y1=0, x2=0, y2=1, user=False):
    u = ' gradientUnits="userSpaceOnUse"' if user else ""
    s = "".join(f'<stop offset="{o}" stop-color="{c}"' + (f' stop-opacity="{op}"' if op != 1 else "") + "/>"
                for o, c, op in [(st + (1,))[:3] for st in stops])
    return f'<linearGradient id="{gid}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"{u}>{s}</linearGradient>'


def rad(gid, stops, cx=0.5, cy=0.5, r=0.5, fx=None, fy=None):
    f = f' fx="{fx}" fy="{fy}"' if fx is not None else ""
    s = "".join(f'<stop offset="{o}" stop-color="{c}"' + (f' stop-opacity="{op}"' if op != 1 else "") + "/>"
                for o, c, op in [(st + (1,))[:3] for st in stops])
    return f'<radialGradient id="{gid}" cx="{cx}" cy="{cy}" r="{r}"{f}>{s}</radialGradient>'


def blur(fid, sd):
    return (f'<filter id="{fid}" x="-30%" y="-30%" width="160%" height="160%">'
            f'<feGaussianBlur stdDeviation="{sd}"/></filter>')


def shadowed(p, d, fill, sd=18, dy=16, op=0.28, colour="#000", rule="nonzero"):
    """A shape with a soft contact shadow under it (blurred offset copy)."""
    return (f'<path d="{d}" fill="{colour}" fill-opacity="{op}" fill-rule="{rule}" '
            f'transform="translate(0 {dy})" filter="url(#{p}blur)"/>'
            f'<path d="{d}" fill="{fill}" fill-rule="{rule}"/>'), blur(f"{p}blur", sd)


def light(p, strength=0.22):
    """Soft key light from the top: a white radial bloom over the upper half of the square."""
    return (rad(f"{p}key", [(0, "#FFFFFF", strength), (1, "#FFFFFF", 0)], 0.5, 0.0, 0.85),
            f'<rect width="1024" height="1024" fill="url(#{p}key)"/>')


def master(defs, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs}</defs>{body}</svg>')


# --- the 12 explorations -------------------------------------------------------------------------
# Each returns (defs, body) in the 1024 box with ids prefixed by `p`.

def open_note(p, refined=False):
    """A half note: the head is open. The spot is literally gone from the note."""
    hx, hy, rx, ry, deg = 455, 662, 214, 152, -24
    # Engraved-style hollow: narrower, steeper ellipse, nudged so the stroke swells at the
    # ends of the long axis and thins top and bottom (like a pen-drawn note head).
    inner = ell(hx + 4, hy + 2, 166, 74, -38, ccw=True)
    head = ell(hx, hy, rx, ry, deg) + inner
    ex, ey = ell_extreme_right(hx, hy, rx, ry, deg)
    w = 64
    top = 168
    sx = ex - w
    # Stem: square top with a 10 px optical round, foot ends just inside the head at its rightmost.
    stem = (f"M{F(sx)} {top + 10}Q{F(sx)} {top} {F(sx + 10)} {top}H{F(ex - 10)}Q{F(ex)} {top} {F(ex)} {top + 10}"
            f"V{F(ey + 4)}H{F(sx)}Z")
    d = head + stem
    # Centre the glyph's box: x 241..ex, y 168..~810 -> shift.
    gx = 512 - (hx - 207 + ex) / 2
    defs = lin(f"{p}bg", [(0, "#FFFFFF"), (1, "#E9E7F1")])
    defs += lin(f"{p}ink", [(0, "#4361FF"), (1, "#1C2AA8")])
    lk, lb = light(p, 0.0)
    sh, bd = shadowed(p, d, f"url(#{p}ink)", 22, 22, 0.22, "#1C2AA8")
    body = f'<rect width="1024" height="1024" fill="url(#{p}bg)"/><g transform="translate({F(gx)} -6)">{sh}</g>'
    return defs + bd, body


def wiped(p, refined=False):
    """A field of spots with one clean S wiped through it; the dots shrink towards the wipe like
    a halftone, so the clean path has a soft, physical edge."""
    n = 8 if refined else 9
    step = 1024 / n
    pts = (cubic((760, 170), (520, 60), (230, 240), (400, 430), 80)
           + cubic((400, 430), (520, 560), (840, 640), (620, 860), 80)[1:])
    dots = []
    for i in range(n):
        for j in range(n):
            x, y = step * (i + 0.5), step * (j + 0.5)
            dd = dist_to_poly((x, y), pts)
            r = step * 0.36 * smooth(70, 230, dd)
            if r > step * 0.07:
                dots.append(f'<circle cx="{F(x)}" cy="{F(y)}" r="{F(r)}"/>')
    defs = lin(f"{p}bg", [(0, "#22164F"), (1, "#120B2E")])
    defs += lin(f"{p}dot", [(0, "#FF8A5C"), (1, "#FF3E8A")], 0, 0, 1, 1)
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<g fill="url(#{p}dot)">{"".join(dots)}</g>')


def ribbon_s(p, refined=False):
    """An S folded from one band: the upper turn shows the face, the lower the reverse."""
    w = 150
    cx, r = 512, 148
    top = (f"M{F(cx + r * math.cos(math.radians(-35)))} {F(372 + r * math.sin(math.radians(-35)))}"
           f"A{r} {r} 0 1 0 {cx} {372 + r}")
    bot = (f"M{cx} {372 + r}A{r} {r} 0 1 1 {F(cx + r * math.cos(math.radians(145)))} "
           f"{F(372 + 2 * r + r * math.sin(math.radians(145)))}")
    defs = lin(f"{p}bg", [(0, "#0F1F3D"), (1, "#081022")])
    defs += lin(f"{p}a", [(0, "#FFE29A"), (1, "#FFB547")], 0, 0, 1, 1)
    defs += lin(f"{p}b", [(0, "#F08A2E"), (1, "#C8551C")], 0, 0, 1, 1)
    defs += blur(f"{p}blur", 14)
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="{bot}" fill="none" stroke="url(#{p}b)" stroke-width="{w}"/>'
                  f'<path d="{top}" fill="none" stroke="#000" stroke-opacity="0.35" stroke-width="{w}" '
                  f'transform="translate(0 14)" filter="url(#{p}blur)"/>'
                  f'<path d="{top}" fill="none" stroke="url(#{p}a)" stroke-width="{w}"/>')


def pebble(p, refined=False):
    """A smooth pebble with its spot cut clean out."""
    d = ("M512 186C716 186 842 300 842 500C842 720 704 846 500 846C300 846 182 716 182 520"
         "C182 312 318 186 512 186Z")
    hole = ell(612, 418, 74, 74, 0, ccw=True)
    defs = lin(f"{p}bg", [(0, "#2A2D34"), (1, "#15161A")])
    defs += rad(f"{p}stone", [(0, "#FFFFFF"), (0.55, "#E9E6E1"), (1, "#B9B3AC")], 0.4, 0.3, 0.8, 0.35, 0.25)
    defs += blur(f"{p}blur", 26)
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="{d}{hole}" fill="#000" fill-opacity="0.45" transform="translate(0 30)" filter="url(#{p}blur)"/>'
                  f'<path d="{d}{hole}" fill="url(#{p}stone)"/>')


def negative_gleam(p, refined=False):
    """Four quarter-discs; the gleam is only the space they leave."""
    a, b = 222, 802
    parts = []
    for (cx, cy, sx, sy) in [(a, a, 1, 1), (b, a, -1, 1), (a, b, 1, -1), (b, b, -1, -1)]:
        r = (b - a) / 2 - 8
        parts.append(f"M{cx} {cy}H{F(cx + sx * r)}A{r} {r} 0 0 {1 if sx * sy > 0 else 0} {cx} {F(cy + sy * r)}Z")
    defs = lin(f"{p}bg", [(0, "#FFF6EC"), (1, "#F6E6D6")])
    defs += lin(f"{p}q", [(0, "#FF7A45"), (1, "#E0245E")], 0, 0, 1, 1)
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="{"".join(parts)}" fill="url(#{p}q)"/>')


def lacquer(p, refined=False):
    """Nothing but a deep lacquered surface and one S-shaped reflection."""
    d = ("M690 230C560 170 330 210 340 360C350 500 690 470 690 640C690 790 470 840 330 790")
    defs = lin(f"{p}bg", [(0, "#6E0F2B"), (1, "#24030D")])
    defs += lin(f"{p}hl", [(0, "#FFFFFF", 0.95), (1, "#FFC7D6", 0.6)])
    defs += blur(f"{p}blur", 10)
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="{d}" fill="none" stroke="#FF8FB0" stroke-opacity="0.35" stroke-width="120" '
                  f'stroke-linecap="round" filter="url(#{p}blur)"/>'
                  f'<path d="{d}" fill="none" stroke="url(#{p}hl)" stroke-width="54" stroke-linecap="round"/>')


def lens(p, refined=False):
    """A vesica lens standing upright, catching a spectrum along one edge."""
    d = "M512 150C700 300 700 724 512 874C324 724 324 300 512 150Z"
    defs = lin(f"{p}bg", [(0, "#0E1530"), (1, "#05070F")])
    defs += lin(f"{p}glass", [(0, "#9EE7FF"), (0.5, "#7C8CFF"), (1, "#E07BFF")], 0, 0, 1, 1)
    defs += lin(f"{p}edge", [(0, "#FFFFFF", 0.9), (1, "#FFFFFF", 0)], 0, 0, 1, 0)
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="{d}" fill="url(#{p}glass)"/>'
                  f'<path d="M512 150C420 300 420 724 512 874C380 724 380 300 512 150Z" fill="url(#{p}edge)"/>')


def droplet(p, refined=False):
    """A single pristine bead of water."""
    d = "M512 160C512 160 760 450 760 620C760 760 650 864 512 864C374 864 264 760 264 620C264 450 512 160 512 160Z"
    defs = lin(f"{p}bg", [(0, "#0B6CFF"), (1, "#0039B8")])
    defs += lin(f"{p}w", [(0, "#FFFFFF"), (1, "#CFE3FF")])
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/><path d="{d}" fill="url(#{p}w)"/>'
                  f'<path d="M420 600C420 520 470 450 500 420" fill="none" stroke="#0B6CFF" stroke-opacity="0.35" '
                  f'stroke-width="36" stroke-linecap="round"/>')


def nib_s(p, refined=False):
    """An S drawn with a broad nib at 35 degrees: thick downstrokes, hairline joins."""
    pts = (cubic((700, 250), (600, 150), (300, 170), (330, 380), 90)
           + cubic((330, 380), (360, 540), (700, 480), (700, 680), 90)[1:]
           + cubic((700, 680), (700, 870), (400, 880), (310, 760), 90)[1:])
    a = math.radians(-35)
    nib = []
    for (x, y) in pts:
        x1, y1 = x + 70 * math.cos(a), y + 70 * math.sin(a)
        x2, y2 = x - 70 * math.cos(a), y - 70 * math.sin(a)
        nib.append(f"M{F(x1)} {F(y1)}L{F(x2)} {F(y2)}")
    defs = lin(f"{p}bg", [(0, "#F4F1EA"), (1, "#E6E1D6")])
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="{"".join(nib)}" stroke="#14213D" stroke-width="16" stroke-linecap="round"/>')


def note_wipe(p, refined=False):
    """A filled note whose flag is a single tapering wipe."""
    hx, hy = 400, 690
    head = ell(hx, hy, 150, 108, -24)
    ex, ey = ell_extreme_right(hx, hy, 150, 108, -24)
    stem = f"M{F(ex - 58)} 230H{F(ex)}V{F(ey)}H{F(ex - 58)}Z"
    flag = (f"M{F(ex - 2)} 230C{F(ex + 60)} 330 {F(ex + 300)} 330 {F(ex + 250)} 560"
            f"C{F(ex + 260)} 420 {F(ex + 120)} 400 {F(ex - 2)} 380Z")
    defs = lin(f"{p}bg", [(0, "#00C2A8"), (1, "#007A8A")])
    return defs, f'<rect width="1024" height="1024" fill="url(#{p}bg)"/><path d="{head}{stem}{flag}" fill="#fff"/>'


def fold(p, refined=False):
    """A clean sheet with its corner turned: a fresh page."""
    defs = lin(f"{p}bg", [(0, "#5B3DF5"), (1, "#3420B8")])
    defs += lin(f"{p}back", [(0, "#D9D4FF"), (1, "#FFFFFF")], 1, 0, 0, 1)
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="M262 212H592L792 412V812H262Z" fill="#fff"/>'
                  f'<path d="M592 212V412H792Z" fill="url(#{p}back)"/>'
                  f'<path d="M592 212L792 412H612Q592 412 592 392Z" fill="#000" fill-opacity="0.12"/>')


def groove(p, refined=False):
    """An S cut into a smooth surface: the record groove, made clean."""
    d = "M690 300C620 200 340 210 350 380C360 520 680 480 680 650C680 820 400 830 330 720"
    defs = lin(f"{p}bg", [(0, "#ECEFF4"), (1, "#C9CFDA")])
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/>'
                  f'<path d="{d}" fill="none" stroke="#FFFFFF" stroke-width="112" stroke-linecap="round" transform="translate(0 8)"/>'
                  f'<path d="{d}" fill="none" stroke="#8C95A8" stroke-width="112" stroke-linecap="round" transform="translate(0 -6)"/>'
                  f'<path d="{d}" fill="none" stroke="#B4BCCB" stroke-width="104" stroke-linecap="round"/>')


EXPLORATIONS = [
    ("Open note", open_note), ("Wiped", wiped), ("Ribbon S", ribbon_s), ("Pebble", pebble),
    ("Negative gleam", negative_gleam), ("Lacquer", lacquer), ("Lens", lens), ("Droplet", droplet),
    ("Nib S", nib_s), ("Note wipe", note_wipe), ("Fold", fold), ("Groove", groove),
]


def framed(defs, body, x, y, size, p, mac=False):
    """Draw a master at (x, y): clipped to the 22.4 % rounded square; mac adds a rim light."""
    s = size / 1024
    r = 229.4
    clip = f'<clipPath id="{p}clip"><rect width="1024" height="1024" rx="{r}"/></clipPath>'
    rim = ""
    if mac:
        rim = (lin(f"{p}rim", [(0, "#FFFFFF", 0.55), (0.25, "#FFFFFF", 0.0), (1, "#FFFFFF", 0.12)]),
               f'<rect x="3" y="3" width="1018" height="1018" rx="{r - 3}" fill="none" stroke="url(#{p}rim)" stroke-width="6"/>')
        clip += rim[0]
        rim = rim[1]
    return (f'<defs>{defs}{clip}</defs><g transform="translate({F(x)} {F(y)}) scale({s:.5f})">'
            f'<g clip-path="url(#{p}clip)">{body}{rim}</g></g>')


def render_all(out):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    r = gb.Renderer()
    try:
        # Exploration grid: 4 x 3, each at 200 px with its 32 and 16 px beside it.
        W, H = 1240, 1020
        parts = [f'<rect width="{W}" height="{H}" fill="#EDEDF0"/>']
        for i, (name, fn) in enumerate(EXPLORATIONS):
            col, row = i % 4, i // 4
            x, y = 30 + col * 300, 30 + row * 330
            d, b = fn(f"e{i}")
            parts.append(framed(d, b, x, y, 200, f"e{i}a"))
            d, b = fn(f"f{i}")
            parts.append(framed(d, b, x + 216, y + 120, 32, f"f{i}a"))
            d, b = fn(f"g{i}")
            parts.append(framed(d, b, x + 254, y + 136, 16, f"g{i}a"))
            parts.append(f'<text x="{x}" y="{y + 232}" font-family="Helvetica Neue" font-size="20" '
                         f'fill="#1C1C1E">{i + 1:02d}  {name}</text>')
        sheet = f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">{"".join(parts)}</svg>'
        r.add(sheet, out / "round2-explorations.png", f"{W}x{H}")
        for i, (name, fn) in enumerate(EXPLORATIONS):
            d, b = fn(f"m{i}")
            r.add(gb.svg(1024, 1024, framed(d, b, 100, 100, 824, f"m{i}a", mac=True)),
                  out / f"round2-{i + 1:02d}.png", 1024, "shadow")
        r.run()
    finally:
        r.close()


# --- finalists (refined) -------------------------------------------------------------------------

def fit_glyph(bbox, height, cx=512, cy=512, dy=0):
    """transform that scales a glyph box to `height` and centres it (plus an optical dy)."""
    x0, y0, x1, y1 = bbox
    k = height / (y1 - y0)
    return f"translate({F(cx - (x0 + x1) / 2 * k)} {F(cy + dy - (y0 + y1) / 2 * k)}) scale({k:.5f})", k


def final_note(p):
    """A. Whole note. The one note with nothing in it: an engraved whole note, a wide oval
    whose hollow leans like a pen stroke (heavy upper-left and lower-right, hairline at the
    sides of the lean). The spot is gone from the note, and nothing else is needed."""
    rx, ry = 282, 200
    # The hollow: long axis tilted -52 deg, offset a hair so the two heavy swells balance.
    d = ell(0, 0, rx, ry, 0) + ell(0, 0, 150, 76, -58, ccw=True)
    tf, k = fit_glyph((-rx, -ry, rx, ry), 400, 512, 512, 0)
    defs = (lin(f"{p}bg", [(0, "#5A2370"), (0.55, "#3A1450"), (1, "#1E0830")])
            + rad(f"{p}key", [(0, "#E7A6FF", 0.30), (1, "#E7A6FF", 0)], 0.5, -0.05, 0.75)
            + lin(f"{p}ivory", [(0, "#FFFFFF"), (0.5, "#FBF4E6"), (1, "#E6D3B2")])
            + lin(f"{p}lip", [(0, "#FFFFFF", 0), (1, "#FFFFFF", 0.0)])
            + blur(f"{p}blur", 26))
    body = (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/><rect width="1024" height="1024" fill="url(#{p}key)"/>'
            f'<g transform="{tf}">'
            f'<path d="{d}" fill="#12021C" fill-opacity="0.55" transform="translate(0 {F(30 / k)})" filter="url(#{p}blur)"/>'
            f'<path d="{d}" fill="url(#{p}ivory)"/></g>')
    return defs, body


def s_spine(r=150, c1=(512, 372), c2=(512, 672), a_top=(336, 90), a_bot=(270, 516), n=90):
    """Centre line of the S used by B and C: two arcs meeting at the spine."""
    pts = []
    for (cx, cy), (a0, a1) in ((c1, a_top), (c2, a_bot)):
        for i in range(n + 1):
            a = math.radians(a0 + (a1 - a0) * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def final_wiped(p):
    """B. Wiped clean. A field of spots with an S wiped out of it: the dots shrink towards the
    S like a halftone, so the letter is made only of absence, with a soft printed edge."""
    # A print halftone: staggered rows, every dot whole and inside the icon's safe inset, dot
    # area falling off smoothly towards the S so the letter has a soft, inked edge.
    step = 1024 / 19
    pts = s_spine(170, (512, 344), (512, 684), (330, 90), (270, 510))
    dots = []
    for j in range(-1, 21):
        y = step * (j + 0.5)
        off = step / 2 if j % 2 else 0
        for i in range(-1, 21):
            x = step * (i + 0.5) + off
            dist = dist_to_poly((x, y), pts)
            r = step * 0.46 * math.sqrt(smooth(40, 170, dist))
            if r < 2.5 or not (r + 34 < x < 1024 - 34 - r and r + 34 < y < 1024 - 34 - r):
                continue
            dots.append(f'<circle cx="{F(x)}" cy="{F(y)}" r="{F(r)}"/>')
    defs = (lin(f"{p}bg", [(0, "#1A1033"), (1, "#0B0618")])
            + rad(f"{p}key", [(0, "#FFFFFF", 0.10), (1, "#FFFFFF", 0)], 0.5, 0.0, 0.8)
            + lin(f"{p}dot", [(0, "#FFB45C"), (0.5, "#FF5E7E"), (1, "#C03CFF")], 0, 0, 1024, 1024, user=True))
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/><rect width="1024" height="1024" fill="url(#{p}key)"/>'
                  f'<g fill="url(#{p}dot)">{"".join(dots)}</g>')


def band(arc_c, r, w, a0, a1, c0=0, c1=0, n=120):
    """A band of width w along an arc (centre, radius, a0 -> a1 degrees in screen coords) as a
    filled outline. c0/c1 slant the end cuts: the outer edge runs c degrees further than the
    inner edge at that end (negative flips the slant), so each cut is one straight line."""
    cx, cy = arc_c
    sg = 1 if a1 > a0 else -1
    def edge(rr, s0, s1):
        return [(cx + rr * math.cos(math.radians(s0 + (s1 - s0) * i / n)),
                 cy + rr * math.sin(math.radians(s0 + (s1 - s0) * i / n))) for i in range(n + 1)]
    outer = edge(r + w / 2, a0 - sg * c0, a1 + sg * c1)
    inner = edge(r - w / 2, a0 + sg * c0, a1 - sg * c1)
    pts = outer + inner[::-1]
    return "M" + "L".join(f"{F(x)} {F(y)}" for x, y in pts) + "Z"


def final_ribbon(p):
    """C. Tape. One length of ribbon (think magnetic tape, pristine and gold) folded into an S:
    the upper turn shows its face, the lower its reverse, with real curl shading on each turn."""
    r, w = 156, 150
    c1, c2 = (512, 356), (512, 668)
    # Upper turn: from the upper right, counter-clockwise over the top to the spine. Lower turn:
    # from the spine, clockwise round to the lower left. Both free ends are cut on the same
    # vertical-ish slant (parallel cuts read as one deliberate cut through folded tape).
    top = band(c1, r, w, 334, 92, 9, 12)
    bot = band(c2, r, w, 266, 514, 0, 9)
    defs = (lin(f"{p}bg", [(0, "#13234A"), (1, "#070D1E")])
            + rad(f"{p}key", [(0, "#6F8CFF", 0.22), (1, "#6F8CFF", 0)], 0.5, -0.05, 0.75)
            + f'<radialGradient id="{p}curlA" cx="{c1[0]}" cy="{c1[1]}" r="{r + w / 2}" gradientUnits="userSpaceOnUse">'
              f'<stop offset="{(r - w / 2) / (r + w / 2):.3f}" stop-color="#F3A93C"/><stop offset="0.72" stop-color="#FFD98A"/>'
              f'<stop offset="1" stop-color="#FFE9B8"/></radialGradient>'
            + f'<radialGradient id="{p}curlB" cx="{c2[0]}" cy="{c2[1]}" r="{r + w / 2}" gradientUnits="userSpaceOnUse">'
              f'<stop offset="{(r - w / 2) / (r + w / 2):.3f}" stop-color="#9C3E10"/><stop offset="0.7" stop-color="#D9702A"/>'
              f'<stop offset="1" stop-color="#EE8F3F"/></radialGradient>'
            + blur(f"{p}blur", 16) + blur(f"{p}blur2", 28))
    return defs, (f'<rect width="1024" height="1024" fill="url(#{p}bg)"/><rect width="1024" height="1024" fill="url(#{p}key)"/>'
                  f'<g transform="translate(0 -2)">'
                  f'<path d="{top}{bot}" fill="#000" fill-opacity="0.5" transform="translate(0 30)" filter="url(#{p}blur2)"/>'
                  f'<path d="{bot}" fill="url(#{p}curlB)"/>'
                  f'<path d="{top}" fill="#000" fill-opacity="0.45" transform="translate(0 16)" filter="url(#{p}blur)"/>'
                  f'<path d="{top}" fill="url(#{p}curlA)"/></g>')


FINALISTS = [("A  Whole note", final_note), ("B  Wiped clean", final_wiped), ("C  Tape", final_ribbon)]


def neighbour(x, y, size, colour):
    r, i = size * 0.224, size * 0.36
    return (f'<rect x="{F(x)}" y="{F(y)}" width="{size}" height="{size}" rx="{F(r)}" fill="{colour}"/>'
            f'<rect x="{F(x + (size - i) / 2)}" y="{F(y + (size - i) / 2)}" width="{F(i)}" height="{F(i)}" '
            f'rx="{F(i * 0.25)}" fill="#fff" fill-opacity="0.85"/>')


def render_finalists(out):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    NB = ["#3A3A3C", "#E8E8ED", "#0A84FF", "#FF9F0A", "#5E5CE6", "#FF375F", "#64D2FF", "#BF5AF2", "#30B0C7"]
    W, H = 1500, 1440
    b = [f'<rect width="{W}" height="{H}" fill="#F2F2F7"/>', f'<rect y="400" width="{W}" height="400" fill="#1C1C1E"/>']
    n = 0
    def put(fn, x, y, size, mac=False):
        nonlocal n; n += 1
        d, bd = fn(f"z{n}")
        b.append(framed(d, bd, x, y, size, f"z{n}a", mac))
    for i, (name, fn) in enumerate(FINALISTS):
        x0 = 40 + i * 490
        for band_y in (40, 440):
            put(fn, x0, band_y, 280, True)
            for sz, oy in ((64, 0), (32, 90), (16, 150)):
                put(fn, x0 + 310, band_y + oy + 40, sz)
            fill = "#1C1C1E" if band_y == 40 else "#F2F2F7"
            b.append(f'<text x="{x0}" y="{band_y + 330}" font-family="Helvetica Neue" font-size="22" fill="{fill}">{name}</text>')
    b.append('<defs>' + lin("wall", [(0, "#2B3A67"), (1, "#B06AB3")], 0, 0, 1, 1)
             + lin("home", [(0, "#F6D6BD"), (1, "#8E9CC8")], 0, 0, 1, 1) + '</defs>')
    b.append(f'<rect y="800" width="{W}" height="640" fill="url(#wall)"/>')
    b.append('<rect x="160" y="850" width="1180" height="100" rx="26" fill="#fff" fill-opacity="0.22" stroke="#fff" stroke-opacity="0.35"/>')
    x = 182
    order = [0, 1, "0", 2, 3, "1", 4, 5, "2", 6, 7, 8]
    for it in order:
        if isinstance(it, str): put(FINALISTS[int(it)][1], x, 868, 64, True)
        else: b.append(neighbour(x + 4, 872, 56, NB[it]))
        x += 96
    b.append('<rect x="420" y="990" width="660" height="420" rx="40" fill="url(#home)"/>')
    items = ["0", 0, 2, 4, 3, "1", 6, 1, 5, 7, "2", 8, 2, 4, 0, 6, 1, 3]
    for i, it in enumerate(items):
        x, y = 452 + (i % 6) * 104, 1015 + (i // 6) * 130
        if isinstance(it, str): put(FINALISTS[int(it)][1], x, y, 72)
        else: b.append(neighbour(x, y, 72, NB[it]))
        b.append(f'<rect x="{x + 14}" y="{y + 82}" width="44" height="7" rx="3.5" fill="#fff" fill-opacity="0.75"/>')
    r = gb.Renderer()
    try:
        r.add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">{"".join(b)}</svg>',
              out / "round2-sheet.png", f"{W}x{H}")
        for i, (name, fn) in enumerate(FINALISTS):
            d, bd = fn(f"big{i}")
            tag = "abc"[i]
            r.add(gb.svg(1024, 1024, framed(d, bd, 100, 100, 824, f"big{i}a", mac=True)),
                  out / f"round2-finalist-{tag}.png", 1024, "shadow")
            (out / f"round2-finalist-{tag}.svg").write_text(master(d, bd))
        r.run()
    finally:
        r.close()


if __name__ == "__main__":
    o = sys.argv[1] if len(sys.argv) > 1 else "docs/compare/logo"
    if "--finalists-only" not in sys.argv: render_all(o)
    render_finalists(o)
