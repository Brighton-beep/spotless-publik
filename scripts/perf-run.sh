#!/usr/bin/env bash
# Dev-only performance run (stream: perf, docs/streams/perf.md).
#   scripts/perf-run.sh <Spotless.app> <startup|full> <profile dir> <out prefix>
# Launches the bundled binary with an isolated profile (LIMUSIC_MULTI=1 HOME=<profile dir>, so the
# owner's profile and any running Spotless are untouched) and ENCORE_PERF=<mode>, which makes the UI
# run ui/src/lib/perfprobe.ts and quit when done. Meanwhile it samples RSS and CPU time of the app
# and of the WebKit processes it is responsible for (perf-sample.py), once a second, into <out>.samples.tsv; the
# `perf:` lines of the log go to <out>.perf.log. scripts/perf-report.py turns both into numbers.
set -euo pipefail
app="$1"; mode="$2"; prof="$3"; out="$4"
mkdir -p "$prof" "$(dirname "$out")"
bin="$app/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")"
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

launch=$(now_ms)
LIMUSIC_MULTI=1 HOME="$prof" ENCORE_PERF="$mode" "$bin" >"$out.stdout.log" 2>&1 &
pid=$!
echo "launch $launch pid $pid" >"$out.meta"

python3 "$(dirname "$0")/perf-sample.py" "$pid" "$out.samples.tsv" "${PERF_TIMEOUT:-900}"
wait "$pid" 2>/dev/null || true
grep -h 'perf: ' "$out.stdout.log" | sed 's/.*perf: /perf: /' >"$out.perf.log" || true
echo "done: $(wc -l <"$out.perf.log") perf lines, $(wc -l <"$out.samples.tsv") samples"
