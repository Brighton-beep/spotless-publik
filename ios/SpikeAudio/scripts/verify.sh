#!/bin/bash
# iOS spike S1 verification on the simulator, no speakers and no taps:
#   1. build (xcodegen + xcodebuild; the Rust staticlib builds in a pre-build phase)
#   2. launch with a fresh googlevideo URL (VISIONOS, crates/innertube resolve example):
#      self-tests run with ao=pcm, then live playback on ao=audiounit at volume 0
#   3. push the app to the background (open Settings) and check the logged position keeps moving
# Usage: scripts/verify.sh [videoId]    Output: $OUT (default build/verify)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
vid="${1:-dQw4w9WgXcQ}"
OUT="${OUT:-$here/build/verify}"
# A simulator of our own (an iPhone 17 Pro on iOS 27), so parallel streams' "booted" devices
# never get our launches.
SIM_NAME="${SIM_NAME:-S1 Audio iPhone 17 Pro}"
AO="${SPIKE_AO:-audiounit}"
mkdir -p "$OUT"
cd "$here"
udid="$(xcrun simctl list devices -j | python3 -c "import json,sys; n=sys.argv[1]; print(next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']==n), ''))" "$SIM_NAME")"
[ -n "$udid" ] || udid="$(xcrun simctl create "$SIM_NAME" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
xcodegen generate >/dev/null
xcodebuild -project SpikeAudio.xcodeproj -scheme SpikeAudio \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build \
  -configuration "${CONFIG:-Debug}" build >"$OUT/xcodebuild.log" 2>&1 || { tail -30 "$OUT/xcodebuild.log"; exit 1; }
app="$(find build/Build/Products -maxdepth 2 -name SpikeAudio.app -path "*iphonesimulator*" | head -1)"
url="$(cd "$repo" && cargo run -q -p innertube --example resolve -- "$vid" 2>/dev/null | tail -1)"
[[ "$url" == https://*googlevideo.com/* ]] || { echo "could not resolve $vid"; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl terminate "$udid" app.encore.ios.spike 2>/dev/null || true
xcrun simctl install "$udid" "$app"
log="$OUT/console.log"
SIMCTL_CHILD_SPIKE_URL="$url" SIMCTL_CHILD_SPIKE_AO="$AO" SIMCTL_CHILD_SPIKE_VOLUME="${SPIKE_VOLUME:-0}" \
  xcrun simctl launch --console-pty --terminate-running-process "$udid" app.encore.ios.spike >"$log" 2>&1 &
launcher=$!
for _ in $(seq 120); do grep -q SPIKE_LIVE_START "$log" && break; sleep 1; done
sleep 6
echo "== background at $(date +%s)" >>"$OUT/marks.log"
xcrun simctl launch "$udid" com.apple.Preferences >/dev/null
sleep "${BG_SECONDS:-30}"
echo "== foreground at $(date +%s)" >>"$OUT/marks.log"
xcrun simctl launch "$udid" app.encore.ios.spike >/dev/null 2>&1 || true
sleep 3
kill "$launcher" 2>/dev/null || true
xcrun simctl terminate "$udid" app.encore.ios.spike 2>/dev/null || true
python3 - "$log" <<'PY'
import json, re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
st = next((l for l in lines if l.startswith("SPIKE_SELFTEST {")), None)
ok = True
if st:
    rep = json.loads(st[len("SPIKE_SELFTEST "):])
    for r in rep["results"]:
        print(f"{'PASS' if r['pass'] else 'FAIL'}  {r['name']:<20} {r.get('error','')}")
        ok &= r["pass"]
else:
    print("FAIL  no self-test report"); ok = False
pos = [(m.group(2), float(m.group(1))) for l in lines if (m := re.search(r"SPIKE_POS .*pos=([-\d.]+) state=(\w+)", l))]
bg = [p for s, p in pos if s == "background"]
fg = [p for s, p in pos if s == "active"]
adv = len(bg) >= 10 and bg[-1] - bg[0] > 0.8 * (len(bg) - 1)
print(f"{'PASS' if fg and fg[-1] > 0 else 'FAIL'}  live position          foreground samples={len(fg)} last={fg[-1] if fg else None}")
print(f"{'PASS' if adv else 'FAIL'}  background playback    samples={len(bg)} first={bg[0] if bg else None} last={bg[-1] if bg else None}")
ok &= adv
sys.exit(0 if ok else 1)
PY
