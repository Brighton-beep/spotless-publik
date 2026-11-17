"""Phosphor icons (MIT) -> template SVG imagesets for the asset catalog.
Reads the path data from the desktop's phosphor-svelte package so both apps draw the same glyphs.
Run: python3 gen-icons.py <phosphor-svelte/lib dir> <Assets.xcassets dir>"""
import sys, os, re, json

ICONS = ["House", "MagnifyingGlass", "Books", "Plus", "PlusCircle", "CheckCircle", "Play", "Pause",
         "SkipBack", "SkipForward", "Shuffle", "Repeat", "RepeatOnce", "Devices", "Export", "Queue",
         "DotsThree", "DotsThreeVertical", "CaretDown", "CaretLeft", "CaretRight", "ArrowCircleDown", "Heart",
         "MusicNotesPlus", "Folder", "User", "Disc", "Broadcast", "ListPlus", "MinusCircle", "Camera", "X",
         "ArrowsDownUp", "SquaresFour", "ListBullets", "PushPin", "MicrophoneStage", "Clock", "Timer",
         "ShareNetwork", "Prohibit", "ArrowLeft", "Link", "MusicNote", "UserPlus", "Gear", "Bell",
         "ClockCounterClockwise", "SpeakerHigh", "ArrowsOutSimple", "XCircle", "Trash", "PencilSimple",
         "Check", "Lightning", "Sparkle", "UsersThree", "Radio", "SealCheck", "Microphone", "Info"]
ICONS += ["ArrowClockwise", "ArrowCounterClockwise", "BookmarkSimple"]  # podcasts (ios-screens2)
ICONS += ["MonitorPlay", "ArrowsInSimple"]  # Now Playing "Switch to video", full-screen video collapse (ios-video)
# Settings pages (ios-screens2-b)
ICONS += ["Lock", "SlidersHorizontal", "HardDrives", "CellSignalFull", "WifiHigh", "PlayCircle", "Moon",
          "Equalizer", "DeviceMobile", "Eye", "Waveform", "UserCircle", "DownloadSimple", "FileText", "Code"]
ICONS += ["WarningCircle"]  # Home error state (parity)

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(dst, "Contents.json"), "w"))
ph = os.path.join(dst, "Phosphor")
os.makedirs(ph, exist_ok=True)
json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}},
          open(os.path.join(ph, "Contents.json"), "w"))

def kebab(n):
    return re.sub(r"(?<!^)(?=[A-Z])", "-", n).lower()

for name in ICONS:
    text = open(os.path.join(src, f"{name}.svelte")).read()
    for weight in ("regular", "fill"):
        m = re.search(r'weight === "%s"\}\s*(.*?)\s*\{:' % weight, text, re.S)
        if not m:
            print("missing", name, weight); continue
        body = m.group(1)
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" fill="#000">{body}</svg>'
        asset = f"ph-{kebab(name)}" + ("-fill" if weight == "fill" else "")
        d = os.path.join(ph, f"{asset}.imageset")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, f"{asset}.svg"), "w").write(svg)
        json.dump({"images": [{"filename": f"{asset}.svg", "idiom": "universal"}],
                   "info": {"author": "xcode", "version": 1},
                   "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}},
                  open(os.path.join(d, "Contents.json"), "w"))
print("done", len(ICONS))
