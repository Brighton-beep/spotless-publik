#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Lists Spotless on publik from this repository (once) and commits publik's
# app token to src-tauri/publik-app-token.txt, following publik's setup guide
# (publikhq.com/skills/setup.md, publish.md and api.md). The latest release
# here must already carry the DMG: publik lists only what a release offers.
#
#   publik/list.sh
#
# One browser approval (publik's device flow). The listing is the one publik
# derives from this repository, with our name and summary, signed and
# notarized declared, and exactly the release's versioned DMG as download.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="fjenn/spotless-publik"
API="https://publikhq.com"
SLUG_WANT="spotless"
TOKEN_FILE="src-tauri/publik-app-token.txt"
die() { echo "list.sh: $*" >&2; exit 1; }
say() { echo "== $*"; }
TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
field() { python3 -Ic 'import json,sys
try: j=json.load(open(sys.argv[1]))
except Exception: j={}
v=j
for k in sys.argv[2].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else (json.dumps(v) if isinstance(v,(dict,list)) else v))' "$1" "$2"; }
post() { # url out body [header-file]
  local args=(-sS -o "$2" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "$3")
  [[ -n "${4:-}" ]] && args+=(-H "@$4")
  curl "${args[@]}" "$1" || echo 000
}

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "uncommitted changes"
TAG="$(gh api "repos/${REPO}/releases/latest" --jq .tag_name)"
VERSION="${TAG#v}"
DMG="Spotless-${VERSION}.dmg"
gh api "repos/${REPO}/releases/tags/${TAG}" --jq '.assets[] | "\(.name) \(.size) \(.digest // "")"' > "${TMP}/assets.txt"
grep -q "^${DMG} " "${TMP}/assets.txt" || die "${TAG} has no ${DMG}"

say "publik: derive the listing from ${REPO}"
code="$(post "${API}/api/submit/derive" "${TMP}/derive.json" "{\"repo\":\"${REPO}\"}")"
[[ "$(field "${TMP}/derive.json" error)" != repo_already_listed ]] || die "already listed as $(field "${TMP}/derive.json" slug)"
[[ "$code" == 200 && -n "$(field "${TMP}/derive.json" manifest)" ]] || { cat "${TMP}/derive.json" >&2; die "publik could not derive the listing (HTTP ${code})"; }
python3 -I - "${TMP}/derive.json" "${TMP}/manifest.json" "${TMP}/assets.txt" "$DMG" "$SLUG_WANT" <<'PY'
import json, sys
derived, out, assets_txt, dmg, slug = sys.argv[1:]
m = json.load(open(derived))["manifest"]
if m.get("slug") != slug:
    sys.exit(f"publik would list this as {m.get('slug')!r}, not {slug!r}")
m["name"] = "Spotless"
m["summary"] = "Free music, podcasts and audiobooks for Mac. No ads."
m["alternativeTo"] = "Spotify"
m["license"] = "GPL-3.0-or-later"
m["declaredMacSignature"] = "notarized"
if isinstance(m.get("publikApi"), dict):
    m["publikApi"]["enabled"] = False
release = {}
for line in open(assets_txt):
    name, size, digest = (line.split() + ["", "", ""])[:3]
    release[name] = (int(size), digest.removeprefix("sha256:"))
arts = [a for a in m.get("artifacts", []) if (a.get("name") or a.get("file")) == dmg]
if len(arts) != 1:
    sys.exit(f"publik derived {[a.get('name') for a in m.get('artifacts', [])]}; want exactly {dmg}")
a = arts[0]
size, sha = release[dmg]
if a.get("sizeBytes") not in (None, size) or a.get("sha256") not in (None, sha):
    sys.exit(f"{dmg}: publik's size or sha256 differs from the release")
m["artifacts"] = arts
json.dump(m, open(out, "w"), indent=2)
print("   name:     ", m["name"]); print("   summary:  ", m["summary"])
print("   download: ", dmg, a.get("platform"), a.get("arch"))
PY

say "publik: sign in (approve in your browser)"
code="$(post "${API}/api/v1/device/code" "${TMP}/code.json" '{"client_name":"Spotless publik listing"}')"
[[ "$code" == 200 ]] || { cat "${TMP}/code.json" >&2; die "publik sign-in did not start (HTTP ${code})"; }
DEVICE_CODE="$(field "${TMP}/code.json" device_code)"; USER_CODE="$(field "${TMP}/code.json" user_code)"
VERIFY_URL="$(field "${TMP}/code.json" verification_uri_complete)"
[[ -n "$DEVICE_CODE" && "$VERIFY_URL" == https://publikhq.com/* ]] || die "unexpected sign-in answer"
echo "   Your browser opens publik. Check that it shows the code ${USER_CODE}, then click Approve."
echo "   If no browser opens, open: ${VERIFY_URL}"
open "$VERIFY_URL" || true
ACCESS=""; interval=5
for _ in $(seq 1 180); do
  sleep "$interval"
  post "${API}/api/v1/device/token" "${TMP}/token.json" "{\"device_code\":\"${DEVICE_CODE}\"}" >/dev/null
  ACCESS="$(field "${TMP}/token.json" access_token)"; [[ -n "$ACCESS" ]] && break
  case "$(field "${TMP}/token.json" error)" in
    authorization_pending|temporarily_unavailable|'') ;;
    slow_down) interval=$((interval + 5)) ;;
    *) die "publik sign-in: $(field "${TMP}/token.json" error)" ;;
  esac
done
[[ -n "$ACCESS" ]] || die "no approval after 15 minutes"
( umask 077; printf 'Authorization: Bearer %s\n' "$ACCESS" > "${TMP}/auth.hdr" ); unset ACCESS
echo "approved"

submit() {
  python3 -Ic 'import json,sys; print(json.dumps({"confirm": True, "manifest": json.load(open(sys.argv[1]))}))' "${TMP}/manifest.json" > "${TMP}/submit.json"
  post "${API}/api/submit" "${TMP}/submitted.json" "@${TMP}/submit.json" "${TMP}/auth.hdr"
}
say "publik: submit the listing"
code="$(submit)"
if [[ "$code" == 400 ]] && grep -qi 'signature' "${TMP}/submitted.json"; then
  echo "   publik refused 'notarized' for the Mac signature; trying 'signed'"
  python3 -Ic 'import json,sys; m=json.load(open(sys.argv[1])); m["declaredMacSignature"]="signed"; json.dump(m,open(sys.argv[1],"w"))' "${TMP}/manifest.json"
  code="$(submit)"
fi
case "$code" in
  200) SLUG="$(field "${TMP}/submitted.json" slug)"
       echo "listed: ${SLUG}, $(field "${TMP}/submitted.json" status), $(field "${TMP}/submitted.json" url)" ;;
  *) cat "${TMP}/submitted.json" >&2; echo >&2; die "publik did not accept the listing (HTTP ${code})" ;;
esac
[[ "$SLUG" == "$SLUG_WANT" ]] || die "publik listed it as ${SLUG}"

say "publik: the app token for ${SLUG}"
code="$(post "${API}/api/v1/apps/${SLUG}/token" "${TMP}/apptoken.json" '{}' "${TMP}/auth.hdr")"
TOKEN="$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\(pat_[^"]*\)".*/\1/p' "${TMP}/apptoken.json" | head -1)"
if [[ "$code" != 2?? || "$TOKEN" != pat_* ]]; then
  url="$(field "${TMP}/apptoken.json" claim_url)"
  [[ "$code" == 403 && "$url" == https://publikhq.com/* ]] && { open "$url"; die "claim the listing on that page (Your app? Claim it with GitHub), then mint the token again"; }
  die "publik did not give an app token (HTTP ${code})"
fi
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"; unset TOKEN
git add "$TOKEN_FILE"
git -c user.name=fjenn -c user.email=fjenn@users.noreply.github.com commit -q -m "publik: the app token for the ${SLUG} listing"
git push -q origin HEAD:main
echo "done: listed as ${SLUG}; app token committed. Next: publik/release.sh ${TAG}.1"
