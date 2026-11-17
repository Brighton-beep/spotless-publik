#!/usr/bin/env bash
# Build Spotless.app on this Mac. Usage: scripts/build-mac.sh [--release]
#   default  → target/debug/bundle/macos/Spotless.app   (~1 min incremental, runs on this machine)
#   --release→ target/release/bundle/macos/Spotless.app (thin LTO, slow)
# The result links Homebrew's libmpv by absolute path, so it runs on machines with `brew install
# mpv`. For a distributable build use scripts/release-mac.sh (bundles the dylibs, signs, makes the DMG).
set -euo pipefail
cd "$(dirname "$0")/.."
export LIBRARY_PATH="$(brew --prefix)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
profile=(--debug)
[[ "${1:-}" == "--release" ]] && profile=()
(cd ui && pnpm install --frozen-lockfile >/dev/null && pnpm build)
./ui/node_modules/.bin/tauri build ${profile[@]+"${profile[@]}"} --bundles app \
  --config '{"build":{"beforeBuildCommand":""},"bundle":{"createUpdaterArtifacts":false}}'
