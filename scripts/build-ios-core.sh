#!/usr/bin/env bash
# Build the shared Rust core for iOS and regenerate its Swift bindings (docs/streams/ios-core.md).
#   scripts/build-ios-core.sh            simulator + device, debug
#   scripts/build-ios-core.sh --sim      simulator only (what the unit test needs)
#   scripts/build-ios-core.sh --release  optimized (thin LTO; slow)
#   scripts/build-ios-core.sh --device   device only (an App Store archive needs nothing else;
#                                        CI's release-ios.yml uses --release --device)
# Output: ios/EncoreCore/build/EncoreCoreFFI.xcframework (static lib + C header + module map) and
# ios/EncoreCore/Sources/EncoreCore/encore_ffi.swift (UniFFI bindings, committed).
set -euo pipefail
cd "$(dirname "$0")/.."
targets=(aarch64-apple-ios-sim aarch64-apple-ios)
profile=debug
cargo_profile=()
for a in "$@"; do
  case "$a" in
    --sim) targets=(aarch64-apple-ios-sim) ;;
    --device) targets=(aarch64-apple-ios) ;;
    --release) profile=release; cargo_profile=(--release) ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
export IPHONEOS_DEPLOYMENT_TARGET=17.0
# The iOS libraries build in their own target dir so they never invalidate the desktop's.
export CARGO_TARGET_DIR="$PWD/target/ios"
# Static library only: a dylib would have to resolve libmpv here, and MPVKit is linked by Xcode.
for t in "${targets[@]}"; do
  cargo rustc -p encore-ffi --lib --crate-type staticlib --target "$t" \
    ${cargo_profile[@]+"${cargo_profile[@]}"}
done

# Bindings come from the interface metadata in a host build of the same crate.
LIBRARY_PATH="$(brew --prefix)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}" \
  cargo build -p encore-ffi -p uniffi-bindgen
gen="$CARGO_TARGET_DIR/uniffi-swift"
rm -rf "$gen" && mkdir -p "$gen"
"$CARGO_TARGET_DIR/debug/uniffi-bindgen" generate --library "$CARGO_TARGET_DIR/debug/libencore_ffi.dylib" \
  --language swift --out-dir "$gen"

out=ios/EncoreCore/build
rm -rf "$out/EncoreCoreFFI.xcframework" "$out/include"
mkdir -p "$out/include"
cp "$gen/encore_ffiFFI.h" "$out/include/"
cp "$gen/encore_ffiFFI.modulemap" "$out/include/module.modulemap"
cp "$gen/encore_ffi.swift" ios/EncoreCore/Sources/EncoreCore/encore_ffi.swift
args=()
for t in "${targets[@]}"; do
  args+=(-library "$CARGO_TARGET_DIR/$t/$profile/libencore_ffi.a" -headers "$out/include")
done
xcodebuild -create-xcframework "${args[@]}" -output "$out/EncoreCoreFFI.xcframework" >/dev/null
echo "built $out/EncoreCoreFFI.xcframework (${targets[*]}, $profile)"
