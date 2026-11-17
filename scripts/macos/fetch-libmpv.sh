#!/usr/bin/env bash
# Fetch a libmpv + FFmpeg dylib set that runs on older macOS, verify it, and cache it.
#
#   scripts/macos/fetch-libmpv.sh [--arch arm64|x86_64|universal]
#
# Prints the cache directory (last line of stdout). That directory holds every dylib of the set,
# thinned to --arch, plus a `libmpv.dylib` symlink so `-lmpv` links against it, and SOURCE.txt
# (where it came from, and a SHA-256 of each file).
#
# Source: the Frameworks folder of a pinned IINA release (https://github.com/iina/iina, GPL-3.0).
#   - IINA builds libmpv + FFmpeg (--enable-gpl --enable-librubberband, SecureTransport TLS) with a
#     low deployment target: every dylib in 1.5.1 has minos 11.0.
#   - Provenance is checked three ways before anything is copied: the DMG's SHA-256 is pinned here,
#     IINA.app must pass `codesign --verify --deep --strict`, and it must be signed by IINA's
#     Developer ID team (67CQ77V27R).
#   - All of its install names are @rpath/<leaf> and it has no LC_RPATHs, so the release script
#     only has to copy the closure and give the executable one rpath.
# Why not the others: Homebrew only bottles for the current macOS (26); mpv's own macOS release
# zips contain the mpv binary but no libmpv; MPVKit builds static frameworks with
# -Drubberband=disabled (tempo/pitch would break). See docs/streams/macos15.md.
#
# Updating: change IINA_VERSION, run once with IINA_SHA256= (empty) to print the new hash, check
# `strings libmpv.2.dylib | grep "^mpv v"` in the result, run the player tests against it
# (docs/streams/macos15.md), then pin the hash.
set -euo pipefail

IINA_VERSION="${IINA_VERSION:-1.5.1}"
IINA_SHA256="${IINA_SHA256-f414507ec60bcfeda3a9f539f74470253e31b619d031e7a9e9a71519da1598cd}"
IINA_TEAM="67CQ77V27R"
MAX_MINOS="${MAX_MINOS:-14.0}"   # refuse a set that would not start on this macOS
ARCH="$(uname -m)"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*" >&2; }
minos() { otool -l "$1" | awk '/LC_BUILD_VERSION/{g=1} g&&/minos/{print $2; exit}'; }
# version_le A B: true when A <= B (dotted versions)
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

CACHE="${ENCORE_CACHE:-$HOME/Library/Caches/encore-release}"
DIR="$CACHE/libmpv-iina-$IINA_VERSION-$ARCH"
if [ -f "$DIR/.complete" ]; then
  log "libmpv: cached at $DIR"
  echo "$DIR"
  exit 0
fi

mkdir -p "$CACHE"
DMG="$CACHE/IINA.v$IINA_VERSION.dmg"
if [ ! -f "$DMG" ]; then
  URL="https://github.com/iina/iina/releases/download/v$IINA_VERSION/IINA.v$IINA_VERSION.dmg"
  log "libmpv: downloading $URL"
  curl -fL --retry 3 -o "$DMG.part" "$URL" >&2
  mv "$DMG.part" "$DMG"
fi
SUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if [ -z "$IINA_SHA256" ]; then
  log "libmpv: IINA_SHA256 not pinned; this DMG is $SUM"
elif [ "$SUM" != "$IINA_SHA256" ]; then
  rm -f "$DMG"
  die "IINA.v$IINA_VERSION.dmg SHA-256 is $SUM, expected $IINA_SHA256 (deleted; re-run to retry)"
fi

MP="$(mktemp -d)"
STAGE="$(mktemp -d)"
cleanup() { hdiutil detach -quiet "$MP" 2>/dev/null || true; rm -rf "$MP" "$STAGE"; }
trap cleanup EXIT
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MP" "$DMG"
APPX="$MP/IINA.app"
[ -d "$APPX/Contents/Frameworks" ] || die "no IINA.app/Contents/Frameworks in the DMG"
codesign --verify --deep --strict "$APPX" || die "IINA.app signature does not verify"
TEAM="$(codesign -dv "$APPX" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$TEAM" = "$IINA_TEAM" ] || die "IINA.app is signed by team '$TEAM', expected $IINA_TEAM"
cp "$APPX"/Contents/Frameworks/*.dylib "$STAGE/"
hdiutil detach -quiet "$MP"

[ -f "$STAGE/libmpv.2.dylib" ] || die "the IINA $IINA_VERSION frameworks have no libmpv.2.dylib"
for f in "$STAGE"/*.dylib; do
  chmod u+w "$f"
  if [ "$ARCH" != universal ]; then
    lipo "$f" -verify_arch "$ARCH" || die "$(basename "$f") has no $ARCH slice"
    if [ "$(lipo -archs "$f")" != "$ARCH" ]; then lipo "$f" -thin "$ARCH" -output "$f.thin" && mv "$f.thin" "$f"; fi
  fi
  m="$(minos "$f")"
  version_le "$m" "$MAX_MINOS" || die "$(basename "$f") has minos $m > $MAX_MINOS"
done
# Thinning invalidated IINA's signatures; an ad-hoc one keeps the set loadable for `cargo test`.
# The release script re-signs everything it bundles anyway.
codesign --force -s - "$STAGE"/*.dylib 2>/dev/null
ln -s libmpv.2.dylib "$STAGE/libmpv.dylib"

MPV_VERSION="$(strings "$STAGE/libmpv.2.dylib" | grep -m1 -E '^mpv v[0-9]' || true)"  # SIGPIPE under pipefail
MPV_VERSION="${MPV_VERSION:-unknown}"
{
  echo "libmpv + dependencies from IINA $IINA_VERSION (GPL-3.0), IINA.app/Contents/Frameworks"
  echo "release: https://github.com/iina/iina/releases/tag/v$IINA_VERSION"
  echo "dmg sha256: $SUM   signed by Developer ID team $TEAM (verified)"
  echo "build scripts / sources: https://github.com/iina/iina (other/), https://mpv.io, https://ffmpeg.org"
  echo "libmpv: $MPV_VERSION   arch: $ARCH   max minos: $MAX_MINOS"
  echo
  (cd "$STAGE" && for f in *.dylib; do [ -L "$f" ] && continue; printf '%s  %s  minos %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f" "$(minos "$f")"; done)
} > "$STAGE/SOURCE.txt"

rm -rf "$DIR"
mkdir -p "$DIR"
ditto "$STAGE" "$DIR"
touch "$DIR/.complete"
log "libmpv: $MPV_VERSION from IINA $IINA_VERSION → $DIR"
echo "$DIR"
