#!/bin/zsh
# stream: firstaudio. Repeatable latency numbers for tap -> audio and search (docs/bench/firstaudio.md).
#   scripts/bench/tap-to-audio.sh                 core bench: stream resolve (iPhone chain), search, screens
#   SIM=<udid> scripts/bench/tap-to-audio.sh ios  + the iOS e2e tap timings on the real core (simulator;
#                                                 run scripts/build-ios-core.sh --sim first)
# Both talk to YouTube; numbers swing with the network, so compare medians of a few runs.
set -eu
cd "$(dirname "$0")/../.."
export LIBRARY_PATH=/opt/homebrew/lib
# --no-default-features: no BotGuard, as on iOS. ENCORE_IOS_CHAIN: VISIONOS first, as on iOS.
ENCORE_IOS_CHAIN=1 cargo test -q -p encore-core --no-default-features --lib firstaudio_bench \
  -- --ignored --nocapture 2>&1 | grep -E ' ms|clients|failed|^--'
if [[ "${1:-}" == ios ]]; then
  SIM=${SIM:?set SIM=<udid>}
  cd ios/Encore
  xcodegen generate -q
  xcodebuild -scheme EncoreE2E -destination "id=$SIM" -derivedDataPath build/dd build-for-testing -quiet
  xcodebuild test-without-building -scheme EncoreE2E -destination "id=$SIM" -derivedDataPath build/dd \
    -only-testing:EncoreE2ETests/InstantTests/test90_TapTimings 2>&1 | grep -E 'INSTANT|error:|\*\* TEST'
  git checkout -- Encore.xcodeproj/project.pbxproj 2>/dev/null || true
fi
