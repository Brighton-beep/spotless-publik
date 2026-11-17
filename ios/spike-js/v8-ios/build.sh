#!/bin/sh
# Build rusty_v8 130.0.7 (rustypipe-botguard's V8) from source for iOS, then the bgios probe.
#   ./build.sh [aarch64-apple-ios-sim|aarch64-apple-ios]
# Cold build ~20 min on this Mac (3k ninja steps), ~25 MB stripped per binary.
# Run in the simulator: xcrun simctl spawn <udid> target/<triple>/release/bgios --jitless 3 <videoId>...
set -eu
TRIPLE=${1:-aarch64-apple-ios-sim}
cd "$(dirname "$0")"
SRC=target/v8-src/v8-130.0.7
if [ ! -d "$SRC" ]; then
  mkdir -p target/v8-src
  cp -R "$(ls -d ~/.cargo/registry/src/*/v8-130.0.7 | head -1)" target/v8-src/ \
    || { cargo fetch && cp -R "$(ls -d ~/.cargo/registry/src/*/v8-130.0.7 | head -1)" target/v8-src/; }
  (cd "$SRC" && patch -p1 < ../../../v8-130.0.7-ios.patch)
  # rusty_v8 embeds ICU data itself; GN only wants the iOS bundle file to exist.
  mkdir -p "$SRC/third_party/icu/ios" && : > "$SRC/third_party/icu/ios/icudtl.dat"
fi
case "$TRIPLE" in
  *-sim) SDK=$(xcrun --sdk iphonesimulator --show-sdk-path); CT="arm64-apple-ios17.4-simulator" ;;
  *)     SDK=$(xcrun --sdk iphoneos --show-sdk-path);        CT="arm64-apple-ios17.4" ;;
esac
VAR=$(echo "$TRIPLE" | tr - _)
export "BINDGEN_EXTRA_CLANG_ARGS_$VAR=--target=$CT -isysroot $SDK"
export LIBCLANG_PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib
export IPHONEOS_DEPLOYMENT_TARGET=17.4
# BrowserEngineCore: V8 >= 17.4 targets call the be_memory_inline_jit_restrict_* W^X helpers.
export RUSTFLAGS="-C link-arg=-framework -C link-arg=BrowserEngineCore"
export V8_FROM_SOURCE=1
# 17.4 turns off V8 lite mode (lite mode fails in torque: "cannot find WasmFuncRef"); jitless is
# then a runtime flag. use_lld=false: Chromium's bundled lld cannot read the Xcode 27 SDK .tbd files.
export GN_ARGS='use_lld=false ios_deployment_target="17.4"'
cargo build --release --target "$TRIPLE"
