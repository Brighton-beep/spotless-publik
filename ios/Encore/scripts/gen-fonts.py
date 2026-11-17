"""Static Figtree TTFs for iOS from the desktop's fontsource variable woff2 files.
iOS can't load woff2, and static instances give exact weights by PostScript name.
Run: python gen-fonts.py <fontsource figtree files dir> <out dir>   (needs fonttools + brotli)"""
import sys, os
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.merge import Merger

src, out = sys.argv[1], sys.argv[2]
WEIGHTS = {400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black"}

def inst(path, w, tmp):
    f = TTFont(path)
    s = instantiateVariableFont(f, {"wght": w})
    s.save(tmp)
    return tmp

os.makedirs(out, exist_ok=True)
for w, style in WEIGHTS.items():
    tmpdir = os.environ.get("TMPDIR", "/tmp")
    pa = inst(os.path.join(src, "figtree-latin-wght-normal.woff2"), w, os.path.join(tmpdir, f"fl{w}.ttf"))
    pb = inst(os.path.join(src, "figtree-latin-ext-wght-normal.woff2"), w, os.path.join(tmpdir, f"fx{w}.ttf"))
    try:
        merged = Merger().merge([pa, pb])
    except Exception as e:  # fall back to the latin subset alone
        print("merge failed, latin only:", e)
        merged = TTFont(pa)
    merged.flavor = None
    name = merged["name"]
    ps = f"Figtree-{style}"
    for rec in list(name.names):
        if rec.nameID in (1, 16):
            rec.string = "Figtree"
        elif rec.nameID in (2, 17):
            rec.string = style
        elif rec.nameID == 4:
            rec.string = f"Figtree {style}"
        elif rec.nameID == 6:
            rec.string = ps
        elif rec.nameID == 3:
            rec.string = f"{ps};encore"
    merged["OS/2"].usWeightClass = w
    merged.save(os.path.join(out, f"{ps}.ttf"))
    print("wrote", ps)
