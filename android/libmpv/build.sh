#!/bin/bash
# Builds libmpv (+ its shared FFmpeg and libc++_shared) for Android arm64-v8a, for the Android
# app's jniLibs. Linux only (CI: .github/workflows/android-libmpv.yml).
#
# Based on mpv-android's buildscripts (pinned below): its FFmpeg keeps every audio filter
# crates/player uses (equalizer, firequalizer, superequalizer, atempo, asetrate, alimiter, afir,
# loudnorm, ...; the list iOS has to add back in ios/ffmpeg-audio). On top of that we add
# librubberband, so speed and pitch can be set independently (MPVKit on iOS has no rubberband).
#
# Usage: android/libmpv/build.sh <work dir> <output dir>
set -euo pipefail

MPV_ANDROID_COMMIT=ebf1b3f0cbe9d6154a43cf6ec1ad6fc32a1b2d47
MPV_VERSION=0.42.0
RUBBERBAND_VERSION=4.0.0
ARCH=arm64            # mpv-android's name
ABI=arm64-v8a         # Android's name

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mkdir -p "$1" && cd "$1" && pwd)"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
WGET="wget -q"

cd "$work"
if [ ! -d mpv-android ]; then
	git clone https://github.com/mpv-android/mpv-android.git
	git -C mpv-android checkout -q "$MPV_ANDROID_COMMIT"
fi
bs="$work/mpv-android/buildscripts"
cd "$bs"

# rubberband as one more dependency of mpv, and mpv required to use it.
cp "$here/rubberband.sh" scripts/rubberband.sh
chmod +x scripts/rubberband.sh
grep -q '^dep_rubberband=' include/depinfo.sh || {
	sed -i 's/^dep_mpv=(\(.*\))$/dep_mpv=(\1 rubberband)/' include/depinfo.sh
	echo 'dep_rubberband=()' >>include/depinfo.sh
}
grep -q 'Drubberband=enabled' scripts/mpv.sh || \
	sed -i 's/-Dlibmpv=true/-Dlibmpv=true -Drubberband=enabled/' scripts/mpv.sh
grep -n 'dep_mpv=' include/depinfo.sh

# SDK + NDK (reuses the runner's SDK when ANDROID_HOME is set, like mpv-android's CI).
if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME" && ! -e sdk/android-sdk-linux ]]; then
	mkdir -p sdk
	ln -s "$ANDROID_HOME" sdk/android-sdk-linux
fi
IN_CI=1 WGET="$WGET" ./include/download-sdk.sh
IN_CI=1 WGET="$WGET" ./include/download-deps.sh

if [ ! -d deps/mpv ]; then
	mkdir -p deps/mpv
	$WGET "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" -O - |
		tar -xz -C deps/mpv --strip-components=1
fi
if [ ! -d deps/rubberband ]; then
	mkdir -p deps/rubberband
	$WGET "https://github.com/breakfastquay/rubberband/archive/refs/tags/v$RUBBERBAND_VERSION.tar.gz" -O - |
		tar -xz -C deps/rubberband --strip-components=1
fi

./buildall.sh --arch "$ARCH" mpv || {
	log="deps/mpv/_build_$ARCH/meson-logs/meson-log.txt"
	[ -f "$log" ] && tail -80 "$log"
	exit 1
}

# Collect what the app ships: libmpv, FFmpeg's shared libs, and the NDK's libc++_shared.
. ./include/depinfo.sh
prefix="$bs/prefix/$ARCH"
ndk="$bs/sdk/android-ndk-$v_ndk"
toolchain="$(echo "$ndk"/toolchains/llvm/prebuilt/*)"
mkdir -p "$out/$ABI" "$out/include"
for f in "$prefix"/lib/lib*.so; do
	cp -L "$f" "$out/$ABI/"
done
cp -L "$toolchain/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$out/$ABI/"
cp -r "$prefix/include/mpv" "$out/include/"

# Every NEEDED entry must be either shipped here or part of Android itself.
system="libc.so libm.so libdl.so liblog.so libandroid.so libz.so libEGL.so libGLESv2.so libGLESv3.so libOpenSLES.so libaaudio.so libmediandk.so libvulkan.so libjnigraphics.so"
fail=0
for f in "$out/$ABI"/*.so; do
	for n in $("$toolchain/bin/llvm-readelf" -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
		if [ ! -f "$out/$ABI/$n" ] && ! grep -qw "$n" <<<"$system"; then
			echo "UNRESOLVED: $(basename "$f") needs $n"; fail=1
		fi
	done
done
"$toolchain/bin/llvm-nm" -D --defined-only "$out/$ABI/libmpv.so" | grep -q ' mpv_create$' || { echo "libmpv.so exports no mpv_create"; fail=1; }
"$toolchain/bin/llvm-readelf" -d "$out/$ABI/libmpv.so" | grep NEEDED
ls -la "$out/$ABI"
exit $fail
