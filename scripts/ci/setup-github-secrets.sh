#!/usr/bin/env bash
# Put the macOS release credentials into the GitHub repo's Actions secrets, so
# .github/workflows/release-mac.yml can sign, notarize and publish without this Mac.
# Run it yourself, on the Mac whose login keychain holds the Developer ID certificate:
#
#   scripts/ci/setup-github-secrets.sh [--repo owner/name] [/path/to/AuthKey_<KEYID>.p8]
#
#   --repo   default fjenn/spotless
#   .p8      the App Store Connect API key file (also --p8 PATH). Without it, the script asks
#            (offering the newest AuthKey_*.p8 on the Desktop or in Downloads). The Key ID is
#            read from the AuthKey_<KEYID>.p8 file name and only confirmed; the Issuer ID is asked.
#
# Interactive throughout, and safe to re-run (every secret is simply overwritten). It sets:
#   MACOS_CERTIFICATE, MACOS_CERTIFICATE_PASSWORD   the Developer ID Application identity
#       (certificate + private key) as a base64 .p12, protected by a password you choose here.
#       macOS asks once to allow the export of the private key from the login keychain.
#   APPLE_API_KEY, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID   an App Store Connect API key for
#       notarytool (base64 of the .p8, its Key ID, the Issuer ID).
#   TAURI_SIGNING_PRIVATE_KEY (+ _PASSWORD if the key has one)   the auto-updater signing key,
#       ~/.tauri/spotless-updater.key by default (TAURI_KEY_FILE overrides).
#
# Values go to `gh secret set` on stdin, never on a command line, and are never printed. The .p12
# lives only in a private temp folder (mode 700) that is overwritten and deleted on exit.
# Needs: gh (logged in with access to the repo), Xcode command line tools (swift, notarytool).
set +x
set -euo pipefail
umask 077

REPO="fjenn/spotless"
P8_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift ;;
    --p8) P8_ARG="$2"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$P8_ARG" ] || { echo "one .p8 path only" >&2; exit 2; }; P8_ARG="$1" ;;
  esac
  shift
done
TAURI_KEY_FILE="${TAURI_KEY_FILE:-$HOME/.tauri/spotless-updater.key}"

die() { echo; echo "ERROR: $*" >&2; exit 1; }
say() { echo; echo "==> $*"; }
ask() { local v; read -r -p "$1" v; printf '%s' "$v"; }
# ask_secret VAR PROMPT: read without echo into VAR.
ask_secret() { local v; read -r -s -p "$2" v; echo >&2; printf -v "$1" '%s' "$v"; }
yes_no() { local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }

SET=()
put_secret() {  # put_secret NAME  (value on stdin)
  gh secret set "$1" --repo "$REPO" >/dev/null || die "gh secret set $1 failed"
  SET+=("$1")
  echo "  set $1"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spotless-secrets.XXXXXX")"
chmod 700 "$WORK"
wipe() {
  local f n
  for f in "$WORK"/*; do
    [ -f "$f" ] || continue
    n="$(stat -f %z "$f" 2>/dev/null || echo 0)"
    [ "$n" -gt 0 ] && dd if=/dev/urandom of="$f" bs="$n" count=1 conv=notrunc 2>/dev/null || true
    rm -f "$f"
  done
  rm -rf "$WORK"
}
trap wipe EXIT
trap 'exit 130' INT TERM

# ---- preflight ------------------------------------------------------------------------------
command -v gh >/dev/null || die "gh is not installed: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"
gh repo view "$REPO" >/dev/null 2>&1 || die "cannot see $REPO with the current gh login (does it exist yet? use --repo)"
xcrun --find notarytool >/dev/null 2>&1 || die "Xcode command line tools missing: xcode-select --install"
# A mistyped .p8 path should fail now, not after the keychain export.
if [ -n "$P8_ARG" ]; then
  P8_ARG="${P8_ARG/#\~/$HOME}"
  [ -f "$P8_ARG" ] || die "no .p8 file at '$P8_ARG'"
fi
echo "Setting the macOS release secrets of $REPO."
echo "Nothing typed here is printed, and nothing is stored outside GitHub's encrypted secrets."

# ---- 1. Developer ID certificate --------------------------------------------------------------
say "1/3  Developer ID Application certificate"
IDS=()
while IFS= read -r line; do IDS+=("$line"); done < <(
  security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' \
    | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$/\1 \2/' || true)
[ ${#IDS[@]} -gt 0 ] || die "no valid 'Developer ID Application' identity in your keychains.
Create one at developer.apple.com > Certificates (type Developer ID Application), install it
by double-clicking, and re-run."
if [ ${#IDS[@]} -eq 1 ]; then
  PICK=0
  echo "Found: ${IDS[0]#* }"
else
  echo "Several Developer ID identities:"
  for i in "${!IDS[@]}"; do echo "  $((i+1))) ${IDS[$i]#* }"; done
  n="$(ask "Which one? [1-${#IDS[@]}] ")"
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#IDS[@]} ] || die "no such choice: $n"
  PICK=$((n-1))
fi
SHA1="${IDS[$PICK]%% *}"

echo "Choose a password for the exported .p12 (it becomes MACOS_CERTIFICATE_PASSWORD; you do not"
echo "need to remember it). Leave empty to generate a random one."
ask_secret P12_PASS "  .p12 password: "
if [ -z "$P12_PASS" ]; then
  P12_PASS="$(openssl rand -base64 24)"
  echo "  (random password generated)"
else
  ask_secret P12_PASS2 "  again: "
  # shellcheck disable=SC2153  # set by ask_secret via printf -v
  [ "$P12_PASS" = "$P12_PASS2" ] || die "the two passwords differ"
  unset P12_PASS2
fi

# `security export` can only export every identity of a keychain at once; this exports the one
# picked above (by certificate SHA-1) with SecItemExport. macOS shows its own dialog to allow
# access to the private key: click "Allow" and enter your login password there.
cat > "$WORK/export.swift" <<'SWIFT'
import Foundation
import Security
import CryptoKit

let want = CommandLine.arguments[1].uppercased()
let out = CommandLine.arguments[2]
let pass = readLine(strippingNewline: true) ?? ""
var query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                            kSecMatchLimit as String: kSecMatchLimitAll,
                            kSecReturnRef as String: true]
if CommandLine.arguments.count > 3 {  // a specific keychain (for testing with a throwaway one)
  var kc: SecKeychain?
  guard SecKeychainOpen(CommandLine.arguments[3], &kc) == errSecSuccess, let k = kc else { exit(3) }
  query[kSecMatchSearchList as String] = [k]
}
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let items = result as? [AnyObject] else {
  FileHandle.standardError.write("no identities found\n".data(using: .utf8)!); exit(1)
}
for item in items {
  let identity = item as! SecIdentity
  var cert: SecCertificate?
  guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let c = cert else { continue }
  let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(c) as Data)
    .map { String(format: "%02X", $0) }.joined()
  guard sha1 == want else { continue }
  var params = SecItemImportExportKeyParameters()
  params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
  params.passphrase = Unmanaged.passUnretained(pass as CFString)
  var data: CFData?
  let status = SecItemExport(identity, .formatPKCS12, [], &params, &data)
  guard status == errSecSuccess, let d = data else {
    let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "\(status)"
    FileHandle.standardError.write("export failed: \(msg)\n".data(using: .utf8)!); exit(2)
  }
  FileManager.default.createFile(atPath: out, contents: d as Data,
                                 attributes: [.posixPermissions: 0o600])
  exit(0)
}
FileHandle.standardError.write("identity \(want) not found\n".data(using: .utf8)!)
exit(1)
SWIFT
P12="$WORK/developer-id.p12"
echo "Exporting (allow the keychain prompt that appears)..."
printf '%s\n' "$P12_PASS" | xcrun swift "$WORK/export.swift" "$SHA1" "$P12" ${SPOTLESS_EXPORT_KEYCHAIN:+"$SPOTLESS_EXPORT_KEYCHAIN"} \
  || die "could not export the identity (was the keychain prompt denied?)"
[ -s "$P12" ] || die "the export wrote nothing"
# Check that the .p12 opens with the password and holds a key, before uploading it.
printf '%s\n' "$P12_PASS" | /usr/bin/openssl pkcs12 -in "$P12" -passin stdin -nocerts -nodes 2>/dev/null \
  | grep -q 'PRIVATE KEY' || die "the exported .p12 does not open with that password or has no private key"
base64 -i "$P12" | tr -d '\n' | put_secret MACOS_CERTIFICATE
printf '%s' "$P12_PASS" | put_secret MACOS_CERTIFICATE_PASSWORD
unset P12_PASS

# ---- 2. App Store Connect API key (notarization) ----------------------------------------------
say "2/3  App Store Connect API key (for notarization)"
if [ -n "$P8_ARG" ]; then
  P8="$P8_ARG"
  echo "Key file: $P8"
else
  cat <<'TXT'
If you have no key yet (account holder or admin):
  App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys > "+"
  Name: "Spotless notarization", Access: Developer > Generate.
  Download the AuthKey_XXXXXXXXXX.p8 (possible only once) and note, above the table, the
  Issuer ID.
TXT
  # shellcheck disable=SC2012  # newest first; the names are fixed AuthKey_*.p8
  DEFAULT_P8="$(ls -t "$HOME"/Desktop/AuthKey_*.p8 "$HOME"/Downloads/AuthKey_*.p8 \
    "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 "$HOME"/private_keys/AuthKey_*.p8 \
    2>/dev/null | head -1 || true)"
  P8="$(ask "Path to the .p8${DEFAULT_P8:+ [$DEFAULT_P8]}: ")"
  P8="${P8:-$DEFAULT_P8}"
fi
P8="${P8/#\~/$HOME}"
[ -f "$P8" ] || die "no file at '$P8'"
grep -q 'BEGIN PRIVATE KEY' "$P8" || die "$P8 is not an App Store Connect .p8 key"
DEFAULT_KID="$(basename "$P8" | sed -n -E 's/^AuthKey_([A-Z0-9]{10})\.p8$/\1/p')"
KEY_ID="$(ask "Key ID${DEFAULT_KID:+ [$DEFAULT_KID]}: ")"
KEY_ID="${KEY_ID:-$DEFAULT_KID}"
[[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || die "a Key ID is 10 letters/digits, like 2X9R4HXF34"
ISSUER="$(ask "Issuer ID (a UUID): ")"
ISSUER="$(echo "$ISSUER" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
[[ "$ISSUER" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die "the Issuer ID looks like 57246542-96fe-1a63-e053-0824d011072a"
echo "Checking the key with Apple (notarytool history)..."
if xcrun notarytool history --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER" >/dev/null 2>&1; then
  echo "  the key works"
else
  echo "  WARNING: Apple refused this key/Key ID/Issuer ID combination (or the network is down)."
  yes_no "  Store it anyway?" || die "stopped; nothing more was changed"
fi
base64 -i "$P8" | tr -d '\n' | put_secret APPLE_API_KEY
printf '%s' "$KEY_ID" | put_secret APPLE_API_KEY_ID
printf '%s' "$ISSUER" | put_secret APPLE_API_ISSUER_ID

# ---- 3. Updater signing key -------------------------------------------------------------------
say "3/3  Auto-updater signing key"
K="$(ask "Updater private key [$TAURI_KEY_FILE]: ")"
K="${K:-$TAURI_KEY_FILE}"
K="${K/#\~/$HOME}"
[ -f "$K" ] || die "no updater key at $K (the one whose public key is in src-tauri/tauri.conf.json)"
ask_secret KEY_PASS "Its password (Enter if it has none): "
put_secret TAURI_SIGNING_PRIVATE_KEY < "$K"
if [ -n "$KEY_PASS" ]; then
  printf '%s' "$KEY_PASS" | put_secret TAURI_SIGNING_PRIVATE_KEY_PASSWORD
else
  # A re-run without a password must not leave an old one behind.
  gh secret delete TAURI_SIGNING_PRIVATE_KEY_PASSWORD --repo "$REPO" >/dev/null 2>&1 || true
fi
unset KEY_PASS

say "Done. Secrets set in $REPO (names only):"
for s in "${SET[@]}"; do echo "  $s"; done
echo
echo "Next: in the public repo's checkout (~/music-app/public-snapshot) push a release tag, e.g."
echo "  git tag -a v1.0.0 -m 'Spotless 1.0.0' && git push origin v1.0.0"
echo "and watch it under Actions > Release macOS (docs/RELEASING.md)."
