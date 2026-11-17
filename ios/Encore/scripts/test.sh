#!/bin/zsh
# Unit + snapshot tests (and optionally UI tests) on a dedicated simulator.
#   SIM=<udid> scripts/test.sh            build-for-testing + EncoreTests (snapshots record when missing)
#   SIM=<udid> scripts/test.sh all        + EncoreUITests
#   SIM=<udid> scripts/test.sh only <Class>[/<testMethod>]
set -e
cd "$(dirname "$0")/.."
SIM=${SIM:?set SIM=<udid>}
xcodegen generate -q
xcodebuild -scheme Encore -destination "id=$SIM" -derivedDataPath build/dd build-for-testing -quiet
case "$1" in
  all) ONLY=() ;;
  only) ONLY=(-only-testing:EncoreTests/$2) ;;
  *) ONLY=(-only-testing:EncoreTests) ;;
esac
xcodebuild test-without-building -scheme Encore -destination "id=$SIM" -derivedDataPath build/dd "${ONLY[@]}" 2>&1 \
  | grep -v CHHaptic | grep -E "error:|Executed|\*\* TEST" | sed -E 's/Automatically recorded snapshot: .*/(recorded)/'
