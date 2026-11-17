#!/usr/bin/env bash
# Build the styled installer DMG: dark background with a pink arrow from the app to Applications,
# fixed 640x400 icon-view window (no toolbar, sidebar or status bar), 128pt icons, custom volume
# icon, ULMO-compressed. Called by release-mac.sh; usable alone:
#
#   scripts/macos/make-dmg.sh <App.app> <out.dmg> [volume name]
#
# Steps: stage app + /Applications link + .background/background.tiff (drawn by
# dmg-background.swift, 1x + 2x merged by tiffutil) + .VolumeIcon.icns → read-write image →
# attach → lay out with Finder AppleScript (needs a GUI login session and Automation access to
# Finder) → detach → convert to ULMO. Every image it attaches is detached again, also on failure.
#
# In CI (GitHub's macOS runners have a GUI session and allow Finder automation, but Apple events
# there time out now and then) the Finder pass is retried 3 times. DMG_ALLOW_PLAIN=1 then lets a
# last failure through with a warning: the DMG keeps the app, the Applications link and the volume
# icon, only without the background and the fixed layout. Unset (local), a failure stops the build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:?usage: make-dmg.sh <App.app> <out.dmg> [volume name]}"
DMG="${2:?usage: make-dmg.sh <App.app> <out.dmg> [volume name]}"
APPNAME="$(basename "$APP")"
# "Spotless Installer", not "Spotless": the mounted disk on the desktop must not read as the app.
VOL="${3:-${APPNAME%.app} Installer}"
# Window geometry, shared with dmg-background.swift: icon centres in a 640x400 content area.
W=640 H=400 LEFT_X=160 RIGHT_X=480 ICON_Y=170 ICON=128

die() { echo "make-dmg: $*" >&2; exit 1; }
WORK="$(mktemp -d)"
DEV=""
cleanup() {
  if [ -n "$DEV" ]; then
    hdiutil detach "$DEV" -quiet 2>/dev/null || hdiutil detach "$DEV" -force -quiet 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# A volume of the same name already mounted would make Finder's `disk "$VOL"` ambiguous.
for m in "/Volumes/$VOL" "/Volumes/$VOL "[0-9]*; do
  [ -d "$m" ] || continue
  echo "make-dmg: ejecting an already mounted $m"
  hdiutil detach "$m" -quiet 2>/dev/null || hdiutil detach "$m" -force -quiet || die "cannot eject $m"
done

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APPNAME"
ln -s /Applications "$STAGE/Applications"
xcrun swift "$HERE/dmg-background.swift" "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
# The volume icon is the app icon with a download badge (scripts/brand/make-installer-icon.py), so
# the installer and the installed app never look the same. Falls back to the plain app icon.
ICNS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/installer-icon.icns"
if [ ! -f "$ICNS" ]; then
  ICNS="$APP/Contents/Resources/$(plutil -extract CFBundleIconFile raw "$APP/Contents/Info.plist" 2>/dev/null || echo icon)"
  [ -f "$ICNS" ] || ICNS="$ICNS.icns"
fi

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
# `hdiutil create` fails with "Resource busy" now and then on CI runners; a retry fixes it.
for attempt in 1 2 3; do
  hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$WORK/rw.dmg" && break
  [ "$attempt" = 3 ] && die "hdiutil create failed 3 times"
  sleep 5
done
ATTACH="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen)"
DEV="$(echo "$ATTACH" | awk 'NR==1{print $1}')"
MNT="$(echo "$ATTACH" | awk -F'\t' '/Apple_HFS/{print $NF}' | sed 's/^ *//')"
[ -d "$MNT" ] || die "no mount point in: $ATTACH"
[ "$(basename "$MNT")" = "$VOL" ] || die "mounted as $MNT, expected /Volumes/$VOL"

# Finder's titlebar is part of `bounds`; size the window so the content area is W x H.
TITLE=32
layout() {
  osascript <<EOF || return 1
with timeout of 120 seconds
tell application "Finder"
  tell disk "$VOL"
    open
    set w to container window
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set pathbar visible of w to false
    set the bounds of w to {200, 120, 200 + $W, 120 + $H + $TITLE}
    set o to the icon view options of w
    set arrangement of o to not arranged
    set icon size of o to $ICON
    set text size of o to 13
    set shows item info of o to false
    set shows icon preview of o to true
    set background color of o to {4000, 4000, 4500}
    set background picture of o to file ".background:background.tiff"
    set extension hidden of item "$APPNAME" to true
    set position of item "$APPNAME" of w to {$LEFT_X, $ICON_Y}
    set position of item "Applications" of w to {$RIGHT_X, $ICON_Y}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
end timeout
EOF
  # Finder writes .DS_Store lazily; wait for it.
  for _ in $(seq 1 30); do [ -f "$MNT/.DS_Store" ] && return 0; sleep 0.5; done
  echo "make-dmg: Finder did not save the window layout (.DS_Store)" >&2
  return 1
}
LAID_OUT=0
for attempt in 1 2 3; do
  if layout; then LAID_OUT=1; break; fi
  echo "make-dmg: Finder layout attempt $attempt failed" >&2
  sleep 5
done
if [ "$LAID_OUT" = 0 ]; then
  [ "${DMG_ALLOW_PLAIN:-0}" = 1 ] || die "Finder did not lay out the window; is Finder scriptable here (Automation access)?"
  echo "::warning::make-dmg: Finder layout failed 3 times; this DMG has no background or fixed layout"
fi

# Hide the scaffolding and drop what Finder and Spotlight left behind.
rm -rf "$MNT/.fseventsd" "$MNT/.Trashes" 2>/dev/null || true
# Custom volume icon: .VolumeIcon.icns plus the kHasCustomIcon Finder flag on the volume root.
# After the Finder pass, which drops both if they are already there.
if [ -f "$ICNS" ]; then
  cp "$ICNS" "$MNT/.VolumeIcon.icns"
  xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MNT"
fi
chflags hidden "$MNT/.background" "$MNT/.VolumeIcon.icns" 2>/dev/null || true
chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$DEV" -quiet || { sleep 2; hdiutil detach "$DEV" -force -quiet; }
DEV=""

rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -quiet -format ULMO -o "$DMG"
echo "make-dmg: $DMG"
