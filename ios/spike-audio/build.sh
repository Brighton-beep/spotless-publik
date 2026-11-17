#!/bin/bash
# Build the spike staticlib for the simulator or a device. Called by Xcode's pre-build phase
# (project.yml) with PLATFORM_NAME set; runnable by hand: ./build.sh iphonesimulator
set -euo pipefail
cd "$(dirname "$0")"
platform="${1:-${PLATFORM_NAME:-iphonesimulator}}"
case "$platform" in
  iphonesimulator) target=aarch64-apple-ios-sim ;;
  iphoneos) target=aarch64-apple-ios ;;
  *) echo "unknown platform $platform" >&2; exit 1 ;;
esac
# Xcode exports the iOS SDK for its own compile; host build scripts and proc macros must not
# see it (they would link against the iOS SDK and fail).
unset SDKROOT IPHONEOS_DEPLOYMENT_TARGET LD_RUNPATH_SEARCH_PATHS LIBRARY_PATH CPATH
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
cargo build --release --target "$target" --lib
mkdir -p out/"$platform"
cp target/"$target"/release/libspike_audio.a out/"$platform"/libspike_audio.a
