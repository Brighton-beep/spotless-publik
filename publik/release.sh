#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Releases the publik edition: puts the tag on main and GitHub builds, signs,
# notarizes and publishes the universal app (.github/workflows/release-mac.yml,
# the same workflow fjenn/spotless releases with; it publishes to this repo).
#
#   publik/release.sh v1.0.5         after fjenn/spotless released it (and
#                                    the sync brought it in)
#   publik/release.sh v1.0.4-rc.5.1  a publik-only version of fjenn/spotless's
#                                    v1.0.4-rc.5 (publik reads each version once)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TAG="${1:-}"
die() { echo "release.sh: $*" >&2; exit 1; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?(\.[0-9]+)?$ ]] || die "usage: publik/release.sh v<version>"
VERSION="${TAG#v}"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "check out main first"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "uncommitted changes"
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not origin/main; pull or push first"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && die "${TAG} exists already"
grep -q '^MACOS_CERTIFICATE' <<<"$(gh secret list -R fjenn/spotless-publik)" || die "the signing secrets are not set (publik/README.md)"

HERE="$(python3 -Ic 'import json; print(json.load(open("src-tauri/tauri.conf.json"))["version"])')"
if [[ "$HERE" != "$VERSION" ]]; then
  # Only a publik-only version (.N on the version main is on) is set here.
  [[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?)\.[0-9]+$ ]] \
    || die "main is at ${HERE}, not ${VERSION}"
  BASE="${BASH_REMATCH[1]}"
  [[ "$HERE" == "$BASE" || "$HERE" == "${BASE}."* ]] || die "main is at ${HERE}; ${TAG} is not a publik-only version of it"
  python3 -I publik/set-version.py "$HERE" "$VERSION"
  git commit -q -am "release: publik edition ${VERSION}"
  git push -q origin HEAD:main
fi
git tag -a "$TAG" -m "Spotless ${VERSION} (publik edition)"
git push -q origin "refs/tags/${TAG}"
echo "release.sh: ${TAG} pushed; GitHub builds it: https://github.com/fjenn/spotless-publik/actions/workflows/release-mac.yml"
