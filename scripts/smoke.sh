#!/usr/bin/env bash
# Spotless smoke check (~1-2 min): live search + stream resolve via the innertube crate,
# then launch the built app with a song link and confirm it resolves and plays.
# Usage: scripts/smoke.sh [path-to-binary]
set -uo pipefail
# Never offer "Move to Applications" (src-tauri/src/install.rs) to a test launch.
export SPOTLESS_NO_MOVE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/target/release/limusic-app}"
[ -x "$BIN" ] || BIN="$ROOT/target/debug/limusic-app"
# The app's data folder: Spotless's, else the pre-rename Encore one (the app moves that to the
# Spotless one at its first launch, so look again after the launch below), else Limusic's.
data_dir() {
  local d
  for d in app.spotless.desktop app.encore.desktop com.limusic.desktop; do
    [ -d "$HOME/Library/Application Support/$d" ] && { echo "$HOME/Library/Application Support/$d"; return; }
  done
  echo "$HOME/Library/Application Support/app.spotless.desktop"
}
DATA="${ENCORE_DATA:-$(data_dir)}"
LOG=$(ls "$DATA"/*.log 2>/dev/null | head -1)
VID="${SMOKE_VIDEO:-dQw4w9WgXcQ}"
pass=0; fail=0
ok(){ echo "PASS  $1"; pass=$((pass+1)); }
ko(){ echo "FAIL  $1"; fail=$((fail+1)); }

echo "binary: $BIN"; echo "data:   $DATA"
pkill -f "$BIN" 2>/dev/null; sleep 1
START=$(date -u +%Y-%m-%dT%H:%M:%S)
"$BIN" "https://music.youtube.com/watch?v=$VID" >/dev/null 2>&1 &
APP=$!
for i in $(seq 1 45); do
  sleep 1
  [ -z "${ENCORE_DATA:-}" ] && DATA="$(data_dir)"
  LOG=$(ls "$DATA"/*.log 2>/dev/null | head -1)
  [ -n "$LOG" ] && cat "$DATA"/*.log 2>/dev/null | awk -v t="$START" 'substr($1,1,19) >= t' | grep -q -E "(resolved stream|stream url cache hit) video_id=" && break
done
if [ -n "$LOG" ] && cat "$DATA"/*.log 2>/dev/null | awk -v t="$START" 'substr($1,1,19) >= t' | grep -q -E "(resolved stream|stream url cache hit) video_id="; then ok "song link resolves to an audio stream (${i}s)"; else ko "song link did not resolve within 45s"; fi
sleep 4
if [ -n "$LOG" ] && cat "$DATA"/*.log 2>/dev/null | awk -v t="$START" 'substr($1,1,19) >= t' | grep -E "ERROR" | grep -v -i -E "ResizeObserver|favicon" | head -5 | grep -q .; then
  echo "WARN  errors in log:"; cat "$DATA"/*.log 2>/dev/null | awk -v t="$START" 'substr($1,1,19) >= t' | grep ERROR | grep -v ResizeObserver | head -5 | cut -c1-200
fi
kill $APP 2>/dev/null; sleep 1; pkill -f "$BIN" 2>/dev/null
echo "smoke: $pass passed, $fail failed"; [ $fail -eq 0 ]
