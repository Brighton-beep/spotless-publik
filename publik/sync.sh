#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Brings this repository (fjenn/spotless-publik) up to date with
# fjenn/spotless: merges its main into ours and pushes. fjenn/spotless is only
# read, never written. Afterwards the two differ only by the publik layer (the
# files in publik/layer-files.txt) and, after a publik-only release, the
# version lines; anything else stops the sync before the push. A merge
# conflict also stops it (nothing is pushed).
#
# Runs hourly in .github/workflows/publik-sync.yml and by hand:
#   publik/sync.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
MAIN_URL="${PUBLIK_SYNC_MAIN_URL:-https://github.com/fjenn/spotless.git}"
die() { echo "sync: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "uncommitted changes"
git fetch -q origin main
git checkout -q main
git merge -q --ff-only origin/main
git fetch -q "$MAIN_URL" main
UPSTREAM="$(git rev-parse FETCH_HEAD)"

# A publik-only version (release.sh: 1.0.4-rc.5.1 while fjenn/spotless is at
# 1.0.4-rc.5) gives way when fjenn/spotless releases a new version: main goes
# back to the version both had, then the merge brings the new one in.
version_at() { git show "$1:src-tauri/tauri.conf.json" | python3 -Ic 'import json,sys; print(json.load(sys.stdin)["version"])'; }
BASE="$(git merge-base HEAD "$UPSTREAM")"
V_OURS="$(version_at HEAD)"; V_BASE="$(version_at "$BASE")"; V_UP="$(version_at "$UPSTREAM")"
if [[ "$V_OURS" != "$V_BASE" && "$V_UP" != "$V_BASE" ]]; then
  python3 -I publik/set-version.py "$V_OURS" "$V_BASE"
  git commit -q -am "sync: back to ${V_BASE} before fjenn/spotless ${V_UP}"
  echo "sync: publik version ${V_OURS} gives way to fjenn/spotless ${V_UP}"
fi

if git merge-base --is-ancestor "$UPSTREAM" HEAD; then
  echo "sync: already has fjenn/spotless ${UPSTREAM:0:8}"
else
  git merge -q --no-edit -m "sync: fjenn/spotless ${UPSTREAM:0:8}" "$UPSTREAM" \
    || { git merge --abort; die "fjenn/spotless ${UPSTREAM:0:8} conflicts with the publik layer; merge it by hand"; }
fi

# The only differences from fjenn/spotless: the publik layer, and version lines.
VERSION_FILES="Cargo.toml src-tauri/tauri.conf.json Cargo.lock"
version_only() {
  git diff -U0 "$UPSTREAM" HEAD -- "$1" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' \
    | grep -vE '^[+-][[:space:]]*("version": "[^"]*",?|version = "[^"]*")$' | grep -q . && return 1
  return 0
}
extra=""
for f in $(git diff --name-only "$UPSTREAM" HEAD | grep -vxF -f publik/layer-files.txt || true); do
  if [[ " $VERSION_FILES " == *" $f "* ]] && version_only "$f"; then continue; fi
  extra+="${f}"$'\n'
done
[[ -z "$extra" ]] || die "differs from fjenn/spotless outside the publik layer:
${extra}"

git push -q origin HEAD:main
echo "sync: main has fjenn/spotless ${UPSTREAM:0:8} plus the publik layer"
