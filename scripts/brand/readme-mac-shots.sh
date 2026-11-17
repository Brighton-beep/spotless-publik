#!/usr/bin/env bash
# Capture the Mac UI for the README (docs/readme/) with a fictional catalogue, then compose all
# README images (scripts/brand/readme_assets.py).
#
#   scripts/brand/readme-mac-shots.sh <fictional fixtures dir> <art dir> <iPhone shots dir>
#
# The dev mock (ui/src/lib/devmock) answers with real YouTube Music captures. For pictures we
# show the public, a throwaway copy of ui/ gets the fictional fixtures and generated cover art made
# by the App Store screenshot pipeline (renamed artists, albums, songs, playlists; original lyrics)
# instead, plus a few renames of names the mock spells out itself. Nothing in ui/ is changed.
# Needs: pnpm, Python with Pillow ($PYTHON, default python3), Google Chrome, 
# and network access once for playwright-core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="${1:?fictional fixtures dir}"; ART="${2:?art dir}"; PHONES="${3:?iPhone screenshots dir}"
PORT=5299
TMP="$(mktemp -d)"; trap 'lsof -ti tcp:$PORT | xargs kill 2>/dev/null || true; rm -rf "$TMP"' EXIT

rsync -a --exclude node_modules --exclude .svelte-kit "$ROOT/ui/" "$TMP/ui/"
M="$TMP/ui/src/lib/devmock"
rm -f "$M"/fixtures/*.json
for f in "$FIX"/*.json; do sed "s#$ART/#http://localhost:$PORT/shot-art/#g" "$f" > "$M/fixtures/$(basename "$f")"; done
mkdir -p "$TMP/ui/static/shot-art" && cp "$ART"/*.png "$TMP/ui/static/shot-art/"
sed -i '' "s/More like Daft Punk/More like Neon Harbor/; s/'Chris Williamson'/'Field Notes'/" "$M/index.ts"
sed -i '' "s/'Discovery Deep Cuts'/'Deep Cuts'/; s/'Robot Rock', 'Helmets on.'/'Synth Sundays', 'Slow mornings.'/" "$M/state.ts"

(cd "$TMP/ui" && pnpm install --frozen-lockfile --silent)
(cd "$TMP/ui" && exec pnpm exec vite dev --port "$PORT" --strictPort >/dev/null 2>&1) &
mkdir -p "$TMP/pw" "$TMP/mac" && (cd "$TMP/pw" && npm init -y >/dev/null && npm i --silent playwright-core@1.49.1)
cat > "$TMP/pw/shot.mjs" <<'EOF'
import { chromium } from 'playwright-core';
const [, , base, out] = process.argv;
const b = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' });
const p = await b.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, colorScheme: 'dark' });
for (const [path, name] of [['/', 'mac-home'], ['/album/MPREb_7ltM34kr0mH', 'mac-album']]) {
  await p.goto(base + path, { waitUntil: 'networkidle' });
  await p.waitForTimeout(7000);
  await p.screenshot({ path: `${out}/${name}.png` });
}
await b.close();
EOF
for _ in $(seq 60); do curl -sf "http://localhost:$PORT/" >/dev/null && break; sleep 1; done
node "$TMP/pw/shot.mjs" "http://localhost:$PORT" "$TMP/mac"
"${PYTHON:-python3}" "$ROOT/scripts/brand/readme_assets.py" "$TMP/mac" "$PHONES"
