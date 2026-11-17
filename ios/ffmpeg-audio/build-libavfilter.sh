#!/bin/bash
# Rebuild MPVKit's libavfilter (FFmpeg n9.0.2) with the audio filters crates/player needs.
# MPVKit configures FFmpeg with --disable-filters and a short whitelist that lacks lowshelf,
# highshelf, alimiter, afir, apad, asplit, ... (docs/streams/ios-audio.md). Everything else in
# MPVKit stays as shipped: this is MPVKit's own configure line (read out of its binary) with the
# external-library switches dropped (their filters are video/subtitle ones mpv never uses through
# lavfi) and our audio filters added. Output: an xcframework replacing MPVKit's Libavfilter.
# STATUS: written in spike S1 but NOT YET RUN (building FFmpeg from source needed an approval
# the spike did not have). Treat as a starting point; see docs/streams/ios-audio.md.
# Usage: build-libavfilter.sh <ffmpeg n9.0.2 source dir> <work dir>
set -euo pipefail
src="$(cd "$1" && pwd)"; work="$(mkdir -p "$2" && cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
FILTERS="aformat amix anull aresample areverse asetrate atempo atrim equalizer firequalizer pan
  superequalizer volume format null scale setpts trim
  lowshelf highshelf bass treble biquad alimiter afir apad asplit asetpts adelay aeval amovie
  anullsrc anoisesrc arealtime loudnorm acompressor dynaudnorm"
common=(--disable-armv5te --disable-armv6 --disable-armv6t2 --disable-bzlib --disable-gray
  --disable-iconv --disable-linux-perf --disable-shared --disable-small --disable-symver
  --disable-xlib --enable-cross-compile --enable-pic --enable-runtime-cpudetect --enable-static
  --enable-version3 --disable-doc --enable-avcodec --enable-avformat --enable-avutil
  --enable-network --enable-swresample --enable-swscale --disable-devices --disable-outdevs
  --disable-indevs --disable-muxers --disable-encoders --enable-protocols --disable-demuxers
  --enable-demuxer=wav --enable-bsfs --disable-decoders --enable-decoder='pcm*'
  --disable-debug --enable-stripping --enable-optimizations --disable-programs
  --arch=aarch64 --target-os=darwin --enable-neon --enable-asm --disable-filters)
for f in $FILTERS; do common+=(--enable-filter="$f"); done
build() { # <platform dir name> <sdk> <min-version flag>
  local name=$1 sdk=$2 minflag=$3 b="$work/$1"
  mkdir -p "$b"; cd "$b"
  local sysroot; sysroot="$(xcrun -sdk "$sdk" --show-sdk-path)"
  local cc; cc="$(xcrun -sdk "$sdk" -f clang)"
  if [ ! -f config.h ]; then
    "$src/configure" "${common[@]}" --cc="$cc" --sysroot="$sysroot" \
      --extra-cflags="-arch arm64 $minflag" --extra-ldflags="-arch arm64 $minflag" >configure.log 2>&1 \
      || { tail -20 configure.log; ffbuild_log="$b/ffbuild/config.log"; tail -40 "$ffbuild_log"; exit 1; }
  fi
  make -j"$(sysctl -n hw.ncpu)" libavfilter/libavfilter.a >make.log 2>&1 || { tail -30 make.log; exit 1; }
}
build ios-arm64-simulator iphonesimulator -mios-simulator-version-min=15.0
build ios-arm64 iphoneos -miphoneos-version-min=15.0
# Package like MPVKit's (static framework per slice; headers are FFmpeg's public ones).
out="$work/Libavfilter.xcframework"; rm -rf "$out"
args=()
for slice in ios-arm64-simulator ios-arm64; do
  fw="$work/fw/$slice/Libavfilter.framework"; rm -rf "$fw"; mkdir -p "$fw/Headers"
  cp "$work/$slice/libavfilter/libavfilter.a" "$fw/Libavfilter"
  cp "$src"/libavfilter/{avfilter.h,buffersink.h,buffersrc.h} "$work/$slice/libavfilter/version.h" "$fw/Headers/" 2>/dev/null || \
    cp "$src"/libavfilter/{avfilter.h,buffersink.h,buffersrc.h,version.h,version_major.h} "$fw/Headers/"
  plat=iPhoneOS; [ "$slice" = ios-arm64-simulator ] && plat=iPhoneSimulator
  cat >"$fw/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Libavfilter</string>
<key>CFBundleIdentifier</key><string>app.encore.Libavfilter</string>
<key>CFBundleName</key><string>Libavfilter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>11.0</string>
<key>CFBundleVersion</key><string>11.0</string>
<key>MinimumOSVersion</key><string>100.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
</dict></plist>
PL
  args+=(-framework "$fw")
done
xcodebuild -create-xcframework "${args[@]}" -output "$out" >/dev/null
echo "$out"
