#!/usr/bin/env bash
# Build a self-contained, distributable Spotless.app + Spotless-<version>.dmg on this Mac.
#
#   scripts/release-mac.sh [--skip-build] [--out DIR] [--arch universal|arm64|x86_64]
#                          [--libmpv iina|homebrew|DIR] [--min-macos X.Y] [--notes FILE]
#
#   --skip-build      reuse the Spotless.app from a previous run (it must have been built with the
#                     same --arch / --libmpv / --min-macos, or the guards will say so)
#   --arch A          universal (default: one fat binary for Apple silicon and Intel, built with
#                     `tauri build --target universal-apple-darwin` against IINA's universal
#                     libmpv), arm64 or x86_64. Thin builds go through the same per-target path.
#   --notes FILE      release notes for latest.json (default: RELEASE_NOTES, or "Spotless <version>")
#   --out DIR         output directory (default: ../dist next to the repo, i.e. ~/music-app/dist)
#   --libmpv SRC      where libmpv + FFmpeg come from (default: iina):
#                       iina      the pinned, signature-checked IINA release frameworks, fetched and
#                                 cached by scripts/macos/fetch-libmpv.sh (minos 11.0; no Homebrew
#                                 needed at build time or at run time)
#                       homebrew  $(brew --prefix)/lib via dylibbundler (the old path; its minos is
#                                 the host macOS, 26.0 on this Mac)
#                       DIR       any directory of dylibs that use @rpath/<leaf> install names
#                                 (e.g. a self-built set); it needs libmpv.2.dylib in it
#   --min-macos X.Y   LSMinimumSystemVersion and MACOSX_DEPLOYMENT_TARGET (default 13.3, or the
#                     Homebrew libmpv's minos with --libmpv homebrew). 13.3 is the floor because it
#                     is the first macOS whose built-in WebKit is Safari 16.4, the baseline of
#                     Tailwind 4 and Vite 8's default build target. See docs/streams/macos15.md.
#
# What it does (docs/BUILD-PLATFORMS.md §macOS steps 4-8, scripted):
#   1. release build of the UI + `tauri build --bundles app` (thin LTO; the slow step)
#   2. copies the .app to $OUT, bundles libmpv and its whole Homebrew dylib graph into
#      Contents/Frameworks with dylibbundler, rewrites install names to @executable_path/../Frameworks
#   3. drops the duplicate LC_RPATHs dylibbundler leaves (dyld refuses those), and any rpath that
#      still points into Homebrew
#   4. guards: no Mach-O may reference /opt/homebrew or /usr/local, and no duplicate rpaths
#   5. signs (ad-hoc by default; Developer ID when SIGN_IDENTITY is set, see below)
#   6. builds the styled DMG (scripts/macos/make-dmg.sh: dark background with a drag arrow, app +
#      /Applications link laid out by Finder, volume icon), signs it, optionally notarizes
#
# Minimum macOS: the Rust binary is built with MACOSX_DEPLOYMENT_TARGET=--min-macos and tauri gets
# the same value as bundle.macOS.minimumSystemVersion (LSMinimumSystemVersion), so Finder refuses
# cleanly on older systems instead of the app dying in dyld. A guard fails the build if any
# bundled Mach-O has an LC_BUILD_VERSION minos above it. Homebrew bottles are built for the host
# macOS only, which is why the default is the IINA set and not Homebrew.
#
# ---- Developer ID signing + notarization (all from the environment) ------------------------------
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   enables real signing:
#       every dylib, then the app, with --options runtime --timestamp and the entitlements in
#       ENTITLEMENTS (default scripts/macos/entitlements.plist: JIT for WKWebView's JS and
#       LuaJIT inside libmpv, network client). Library validation passes because every bundled
#       dylib is re-signed with the same team identity.
#   NOTARY_PROFILE=<keychain profile>   after signing, submit the DMG with
#       `xcrun notarytool submit --keychain-profile $NOTARY_PROFILE --wait` and staple the ticket.
#       Create the profile once with:
#       xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER   instead of a profile (CI): an App Store
#       Connect API key (.p8 file, its Key ID, the Issuer ID), passed to notarytool as
#       --key/--key-id/--issuer. Used only when NOTARY_PROFILE is unset. (Not named APPLE_API_*
#       on purpose: `tauri build` reads those and would try to notarize on its own.)
#   Either way the submission must come back "Accepted"; otherwise its log is printed and the
#   script stops.
#   Neither set → ad-hoc signature: runs here and on other Macs after right-click → Open
#   (or `xattr -dr com.apple.quarantine /Applications/Spotless.app`).
#   Nothing private lives in this file: the identity, team and profile come from the environment.
#
# ---- Auto-update artifacts (tauri-plugin-updater) -----------------------------------------------
#   After signing/notarizing, the finished (stapled) app is packed as
#   Spotless_<version>_<arch>.app.tar.gz, signed with the updater key into <tarball>.sig, and
#   described by latest.json, which the app polls at
#   https://github.com/$SPOTLESS_REPO/releases/latest/download/latest.json
#   (plugins.updater.endpoints in src-tauri/tauri.conf.json). Tauri's own createUpdaterArtifacts is
#   switched off for the build step because it would tar the app before libmpv is bundled into it.
#   TAURI_SIGNING_PRIVATE_KEY_PATH       updater private key (default ~/.tauri/spotless-updater.key
#                                        if that exists); or TAURI_SIGNING_PRIVATE_KEY (the key text)
#   TAURI_SIGNING_PRIVATE_KEY_PASSWORD   its password (default empty)
#   SPOTLESS_REPO                        owner/repo the release lives in (default fjenn/spotless)
#   RELEASE_TAG                          the release's tag (default v<version>)
#   No key → the DMG is still made, the updater artifacts are skipped with a warning.
#   Upload everything listed under "release assets" at the end to the GitHub release RELEASE_TAG.
# -------------------------------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_BUILD=0
LIBMPV=iina
ARCH=universal
NOTES_FILE=""
MINOS=""
OUT="$(cd "$ROOT/.." && pwd)/dist"
# A git worktree lives at ~/music-app/wt/<name>; send its output to ~/music-app/dist as well.
[[ "$ROOT" == */wt/* ]] && OUT="${ROOT%%/wt/*}/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --out) OUT="$2"; shift ;;
    --libmpv) LIBMPV="$2"; shift ;;
    --min-macos) MINOS="$2"; shift ;;
    --arch) ARCH="$2"; shift ;;
    --notes) NOTES_FILE="$2"; shift ;;
    -h|--help) sed -n '2,78p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

machominos() { otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{g=1} g&&/minos/{print $2; exit}'; }
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

case "$ARCH" in
  universal) TARGET=universal-apple-darwin; UPD_ARCHS="aarch64 x86_64" ;;
  arm64|aarch64) ARCH=arm64; TARGET=aarch64-apple-darwin; UPD_ARCHS="aarch64" ;;
  x86_64) TARGET=x86_64-apple-darwin; UPD_ARCHS="x86_64" ;;
  *) die "--arch: universal, arm64 or x86_64, not $ARCH" ;;
esac
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || die "--notes: no file $NOTES_FILE"

case "$LIBMPV" in
  homebrew)
    [ "$ARCH" = "$(uname -m)" ] || die "--libmpv homebrew only has this Mac's arch ($(uname -m)); use --arch $(uname -m) or --libmpv iina"
    BREW="$(brew --prefix)"
    command -v dylibbundler >/dev/null || die "dylibbundler missing: brew install dylibbundler"
    [ -f "$BREW/lib/libmpv.2.dylib" ] || die "no libmpv at $BREW/lib: brew install mpv"
    LIBDIR="$BREW/lib"
    LIBMPV_DESC="Homebrew libmpv"
    [ -n "$MINOS" ] || MINOS="$(machominos "$(realpath "$LIBDIR/libmpv.2.dylib")")"
    ;;
  iina)
    # Fat for --arch universal, thinned otherwise.
    LIBDIR="$("$ROOT/scripts/macos/fetch-libmpv.sh" --arch "$ARCH" | tail -1)"
    LIBMPV_DESC="libmpv from IINA ($(sed -n 's/^libmpv: \([^ ]* [^ ]*\).*/\1/p' "$LIBDIR/SOURCE.txt"))"
    ;;
  *)
    LIBDIR="$(cd "$LIBMPV" && pwd)" || die "--libmpv: no directory $LIBMPV"
    LIBMPV_DESC="libmpv from $LIBDIR"
    ;;
esac
[ -f "$LIBDIR/libmpv.2.dylib" ] || die "no libmpv.2.dylib in $LIBDIR"
# -lmpv needs the unversioned name; a plain dylib dir (or the cache) may only have libmpv.2.dylib.
LINKDIR="$LIBDIR"
if [ ! -e "$LIBDIR/libmpv.dylib" ]; then
  LINKDIR="$(mktemp -d)"; ln -s "$LIBDIR/libmpv.2.dylib" "$LINKDIR/libmpv.dylib"
fi
MINOS="${MINOS:-13.3}"
export LIBRARY_PATH="$LINKDIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
export MACOSX_DEPLOYMENT_TARGET="$MINOS"

VERSION="$(plutil -extract version raw src-tauri/tauri.conf.json 2>/dev/null \
  || sed -n 's/^  "version": "\(.*\)",/\1/p' src-tauri/tauri.conf.json)"
PRODUCT="$(sed -n 's/^  "productName": "\(.*\)",/\1/p' src-tauri/tauri.conf.json)"
[ -n "$VERSION" ] && [ -n "$PRODUCT" ] || die "could not read productName/version from tauri.conf.json"
echo "$PRODUCT $VERSION $ARCH  (minimum macOS $MINOS, $LIBMPV_DESC)  →  $OUT"

SRC_APP="target/$TARGET/release/bundle/macos/$PRODUCT.app"
T0=$SECONDS
if [ "$SKIP_BUILD" = 0 ]; then
  step "release build"
  (cd ui && pnpm install --frozen-lockfile >/dev/null && pnpm build)
  ./ui/node_modules/.bin/tauri build --target "$TARGET" --bundles app --config \
    "{\"build\":{\"beforeBuildCommand\":\"\"},\"bundle\":{\"createUpdaterArtifacts\":false,\"macOS\":{\"minimumSystemVersion\":\"$MINOS\"}}}"
fi
BUILD_SECS=$((SECONDS - T0))
[ -d "$SRC_APP" ] || die "no bundle at $SRC_APP"

step "staging $OUT/$PRODUCT.app"
mkdir -p "$OUT"
APP="$OUT/$PRODUCT.app"
rm -rf "$APP"
ditto "$SRC_APP" "$APP"
BIN="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
[ -x "$BIN" ] || die "no executable at $BIN"

# Every Mach-O in the bundle (binary + dylibs).
machos() { find "$APP/Contents" -type f \( -perm -u+x -o -name '*.dylib' \) -print0; }
# One slice is enough: a universal binary would otherwise list every rpath once per architecture.
rpaths() { local a; a="$(lipo -archs "$1" 2>/dev/null | awk '{print $1}')"; otool ${a:+-arch "$a"} -l "$1" 2>/dev/null | awk '/LC_RPATH/{g=1} g&&/^[[:space:]]*path /{sub(/^[[:space:]]*path /,""); sub(/ \(offset [0-9]+\)$/,""); print; g=0}'; }

FW="$APP/Contents/Frameworks"
# Non-system dependencies of a Mach-O (skipping a dylib's own LC_ID_DYLIB line).
deps() {
  # Indented lines only: a universal binary prints one "<file> (architecture X):" header per slice.
  local id; id="$(otool -D "$1" | grep -v ':$' | sort -u)"
  otool -L "$1" | grep -E '^[[:space:]]' | awk '{print $1}' | sort -u | { grep -v -E '^(/System/|/usr/lib/)' || true; } \
    | { if [ -n "$id" ]; then grep -v -x -F "$id" || true; else cat; fi; }
}
if [ "$LIBMPV" = homebrew ]; then
  step "bundling libmpv + dependencies (dylibbundler)"
  dylibbundler -cd -of -b -x "$BIN" -d "$FW" -p "@executable_path/../Frameworks/" -s "$LIBDIR" </dev/null 2>&1 >/dev/null \
    | { grep -v -E 'will invalidate the code signature|replacing existing signature' || true; }
else
  step "bundling libmpv + dependencies from $LIBDIR"
  # Copy the closure of the executable's non-system dependencies, by leaf name, from LIBDIR.
  # Everything is addressed as @rpath/<leaf>, and the executable carries the one rpath that
  # resolves it; dyld searches the main executable's rpaths for every image in the load chain.
  ARCHS="$(lipo -archs "$BIN")"
  mkdir -p "$FW"
  queue=("$BIN")
  while [ ${#queue[@]} -gt 0 ]; do
    f="${queue[0]}"; queue=("${queue[@]:1}")
    for dep in $(deps "$f"); do
      leaf="${dep##*/}"
      if [ ! -f "$FW/$leaf" ]; then
        src="$LIBDIR/$leaf"
        [ -f "$src" ] || die "${f##*/} needs $dep, which is not in $LIBDIR"
        cp "$(realpath "$src")" "$FW/$leaf"; chmod u+w "$FW/$leaf"
        if [ "$(lipo -archs "$FW/$leaf")" != "$ARCHS" ] && [ "$(echo "$ARCHS" | wc -w)" -eq 1 ]; then
          lipo "$FW/$leaf" -thin "$ARCHS" -output "$FW/$leaf.thin" && mv "$FW/$leaf.thin" "$FW/$leaf"
        fi
        install_name_tool -id "@rpath/$leaf" "$FW/$leaf" 2>/dev/null
        queue+=("$FW/$leaf")
      fi
      [ "$dep" = "@rpath/$leaf" ] || install_name_tool -change "$dep" "@rpath/$leaf" "$f" 2>/dev/null
    done
  done
  rpaths "$BIN" | grep -q -x -F '@executable_path/../Frameworks' \
    || install_name_tool -add_rpath '@executable_path/../Frameworks' "$BIN"
  [ -f "$LIBDIR/SOURCE.txt" ] && cp "$LIBDIR/SOURCE.txt" "$APP/Contents/Resources/libmpv-SOURCE.txt"
fi
echo "bundled $(ls "$FW" | wc -l | tr -d ' ') libraries, $(du -sh "$FW" | cut -f1)"

step "cleaning rpaths"
machos | while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O || continue
  # dylibbundler rewrites every LC_RPATH to the -p prefix; libmpv ships two → duplicates dyld rejects.
  rpaths "$f" | sort | uniq -c | while read -r n rp; do
    i=1; while [ "$i" -lt "$n" ]; do install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null; i=$((i+1)); done
    if [ "$n" -gt 1 ]; then echo "${f#"$APP"/}: dropped $((n-1)) duplicate rpath $rp"; fi
  done
  { rpaths "$f" | grep -E '^/(opt/homebrew|usr/local)/' || true; } | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null
    echo "${f#"$APP"/}: dropped rpath $rp"
  done
done

step "guards"
LEAKS="$(machos | while IFS= read -r -d '' f; do
  otool -L "$f" 2>/dev/null | tail -n +2 | { grep -E '^[[:space:]]+/(opt/homebrew|usr/local)/' || true; } | sed "s|^|${f#"$APP"/}: |"
  rpaths "$f" | { grep -E '^/(opt/homebrew|usr/local)/' || true; } | sed "s|^|${f#"$APP"/}: rpath |"
done)"
[ -z "$LEAKS" ] || { echo "$LEAKS"; die "bundle still references Homebrew"; }
DUPES="$(machos | while IFS= read -r -d '' f; do rpaths "$f" | sort | uniq -d | sed "s|^|${f#"$APP"/}: |"; done)"
[ -z "$DUPES" ] || { echo "$DUPES"; die "duplicate LC_RPATH left (dyld will refuse to load)"; }
echo "no Homebrew references, no duplicate rpaths"
TOONEW="$(machos | while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O || continue
  m="$(machominos "$f")"
  [ -n "$m" ] && ! version_le "$m" "$MINOS" && echo "${f#"$APP"/}: minos $m"
done || true)"
[ -z "$TOONEW" ] || { echo "$TOONEW"; die "Mach-Os above the macOS $MINOS floor (rebuild without --skip-build, or raise --min-macos)"; }
PLIST_MIN="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist" 2>/dev/null || echo none)"
[ "$PLIST_MIN" = "$MINOS" ] || die "LSMinimumSystemVersion is $PLIST_MIN, expected $MINOS (rebuild without --skip-build)"
echo "every Mach-O has minos <= $MINOS; LSMinimumSystemVersion $PLIST_MIN"

step "signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  ENT="${ENTITLEMENTS:-$ROOT/scripts/macos/entitlements.plist}"
  [ -f "$ENT" ] || die "SIGN_IDENTITY set but no entitlements at $ENT"
  # Inside-out: dylibs first, then the bundle (no --deep, which Apple discourages for real signing).
  for f in "$FW"/*.dylib; do codesign --force --timestamp --options runtime -s "$SIGN_IDENTITY" "$f"; done
  codesign --force --timestamp --options runtime --entitlements "$ENT" -s "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict --verbose=1 "$APP"

step "dmg"
DMG="$OUT/$PRODUCT-$VERSION.dmg"
# Styled window (background with a drag arrow, fixed layout, volume icon); needs a GUI session.
"$ROOT/scripts/macos/make-dmg.sh" "$APP" "$DMG" "$PRODUCT"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
  NOTARY_AUTH=()
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "${NOTARY_KEY_PATH:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER:-}" ]; then
    [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ] && [ -f "${NOTARY_KEY_PATH:-}" ] \
      || die "notarization by API key needs NOTARY_KEY_PATH (an existing .p8), NOTARY_KEY_ID and NOTARY_ISSUER"
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  fi
  if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
    step "notarizing (usually 2-15 minutes)"
    # Not fatal by itself: a rejected submission still has an id whose log explains why.
    NOTARY_JSON="$(xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --output-format json)" || true
    jfield() { /usr/bin/python3 -I -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception: print("")' "$1" <<<"$NOTARY_JSON"; }
    NOTARY_STATUS="$(jfield status)"
    NOTARY_ID="$(jfield id)"
    [ -n "$NOTARY_STATUS" ] || { echo "$NOTARY_JSON"; die "notarytool submit failed (output above)"; }
    echo "notarization $NOTARY_ID: $NOTARY_STATUS"
    if [ "$NOTARY_STATUS" != Accepted ]; then
      [ -n "$NOTARY_ID" ] && xcrun notarytool log "$NOTARY_ID" "${NOTARY_AUTH[@]}" || true
      die "notarization was not accepted ($NOTARY_STATUS); the log above says why"
    fi
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
  fi
fi
hdiutil verify -quiet "$DMG"
# A stable name too, so https://github.com/<repo>/releases/latest/download/Spotless.dmg (the
# website's download button) always gets the newest one. APFS clone: no extra disk space.
DMG_LATEST="$OUT/$PRODUCT.dmg"
rm -f "$DMG_LATEST"; cp -c "$DMG" "$DMG_LATEST" 2>/dev/null || cp "$DMG" "$DMG_LATEST"

step "updater artifacts"
REPO="${SPOTLESS_REPO:-fjenn/spotless}"
TAG="${RELEASE_TAG:-v$VERSION}"
if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ] && [ -z "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ] \
  && [ -f "$HOME/.tauri/spotless-updater.key" ]; then
  TAURI_SIGNING_PRIVATE_KEY_PATH="$HOME/.tauri/spotless-updater.key"
fi
TARBALL="$OUT/${PRODUCT}_${VERSION}_${ARCH}.app.tar.gz"
LATEST_JSON="$OUT/latest.json"
rm -f "$TARBALL" "$TARBALL.sig" "$LATEST_JSON"
if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ] && [ -z "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ]; then
  echo "WARNING: no updater key (TAURI_SIGNING_PRIVATE_KEY_PATH / TAURI_SIGNING_PRIVATE_KEY);" \
    "skipping $TARBALL, its .sig and latest.json. Installed copies will not see this release."
else
  # The finished app: libmpv bundled, signed, and (with NOTARY_PROFILE) stapled. No AppleDouble
  # files (COPYFILE_DISABLE) so the archive holds exactly the bundle.
  COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$OUT" "$PRODUCT.app"
  KEYARG=()
  if [ -n "${TAURI_SIGNING_PRIVATE_KEY_PATH:-}" ]; then
    [ -f "$TAURI_SIGNING_PRIVATE_KEY_PATH" ] || die "no updater key at $TAURI_SIGNING_PRIVATE_KEY_PATH"
    KEYARG=(--private-key-path "$TAURI_SIGNING_PRIVATE_KEY_PATH")
  else
    KEYARG=(--private-key "$TAURI_SIGNING_PRIVATE_KEY")
  fi
  # `signer sign` reads the key from the flag only; keep the env copies away from it.
  env -u TAURI_SIGNING_PRIVATE_KEY -u TAURI_SIGNING_PRIVATE_KEY_PATH \
    "$ROOT/ui/node_modules/.bin/tauri" signer sign "${KEYARG[@]}" \
    --password "${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}" --app-version "$VERSION" "$TARBALL" >/dev/null
  [ -s "$TARBALL.sig" ] || die "tauri signer wrote no $TARBALL.sig"
  NOTES="${RELEASE_NOTES:-$PRODUCT $VERSION}"
  [ -n "$NOTES_FILE" ] && NOTES="$(cat "$NOTES_FILE")"
  URL="https://github.com/$REPO/releases/download/$TAG/$(basename "$TARBALL")"
  NOTES="$NOTES" URL="$URL" SIG="$(cat "$TARBALL.sig")" VERSION="$VERSION" UPD_ARCHS="$UPD_ARCHS" \
    /usr/bin/python3 -I -c '
import json, os, datetime
e = os.environ
entry = {"signature": e["SIG"], "url": e["URL"]}
print(json.dumps({
    "version": e["VERSION"],
    "notes": e["NOTES"],
    "pub_date": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "platforms": {"darwin-" + a: entry for a in e["UPD_ARCHS"].split()},
}, indent=2))' > "$LATEST_JSON"
  echo "latest.json → $URL  (platforms: $(echo "$UPD_ARCHS" | sed 's/[^ ]*/darwin-&/g'))"
fi

echo
echo "app:   $APP  ($(du -sh "$APP" | cut -f1), $(lipo -archs "$BIN"))"
echo "dmg:   $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "release assets for $REPO $TAG:"
for f in "$DMG" "$DMG_LATEST" "$TARBALL" "$TARBALL.sig" "$LATEST_JSON"; do
  [ -f "$f" ] && echo "  $f"
done
[ "$SKIP_BUILD" = 0 ] && echo "release build: ${BUILD_SECS}s"
echo "total: $((SECONDS - T0))s"
