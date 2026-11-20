#!/bin/bash -e
# librubberband for the Android libmpv (crates/player: speed and pitch independently, the
# `rubberband` audio filter). Installed into mpv-android's buildscripts/scripts/ by build.sh and
# run by its buildall.sh like every other dependency (static, into the arch's prefix).

. ../../include/path.sh

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf $build
	exit 0
else
	exit 255
fi

unset CC CXX # meson wants these unset

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Dfft=builtin -Dresampler=builtin \
	-Djni=disabled -Dladspa=disabled -Dvamp=disabled -Dcmdline=disabled -Dtests=disabled

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install
