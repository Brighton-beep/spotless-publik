# Releasing Spotless for Mac

Mac releases are built, signed with the Developer ID certificate, notarized, stapled and published
by GitHub Actions ([`.github/workflows/release-mac.yml`](../.github/workflows/release-mac.yml))
whenever a `v*` tag is pushed. No Mac needs to be on. The workflow runs
[`scripts/release-mac.sh`](../scripts/release-mac.sh), the same script used for local releases,
and attaches to the GitHub Release:

| Asset | What it is for |
|---|---|
| `Spotless-<version>.dmg` | the installer for this version |
| `Spotless.dmg` | the same file under a fixed name; the website's download button points at `releases/latest/download/Spotless.dmg` |
| `Spotless_<version>_universal.app.tar.gz` + `.sig` | the signed update the in-app updater installs |
| `latest.json` | what installed copies poll (`releases/latest/download/latest.json`) to find an update |

The release is created as a draft, filled with every asset, and only then published, so
`latest.json` never points at a file that is not there yet. Tags with a suffix (`v1.1.0-beta.1`)
become pre-releases, which `releases/latest` (and so the updater) skips.

## One-time setup (owner)

1. **Have an App Store Connect API key** for notarization (the `AuthKey_<KEYID>.p8` file). If
   there is none yet (account holder or admin): App Store Connect › Users and Access ›
   Integrations › App Store Connect API › Team Keys › **+**, name it e.g. "Spotless
   notarization", access **Developer**, Generate, and download the `.p8` (Apple allows this
   once). Either way, copy the **Issuer ID** shown above the keys table.
2. **Run the secrets script** on the Mac whose login keychain has the "Developer ID Application"
   certificate, with `gh` logged in, giving it the key file:
   ```bash
   scripts/ci/setup-github-secrets.sh ~/Desktop/AuthKey_<KEYID>.p8   # --repo owner/name for another repo
   ```
   It asks which Developer ID identity to use, a password for the exported .p12 (Enter for a
   random one), confirms the Key ID it read from the file name, asks the Issuer ID (it checks the
   key with Apple), and the updater key (`~/.tauri/spotless-updater.key`, plus its password if it
   has one). macOS shows a
   keychain dialog to allow the private-key export: click **Allow**. Nothing is printed; it ends
   with the list of secret names it set. Re-run it any time (new certificate, rotated key).
3. **Push the tag** for the version that is in `src-tauri/tauri.conf.json` and `Cargo.toml`, in
   the public repo's checkout (the snapshot that `scripts/publish-snapshot.sh` writes and that is
   pushed to `fjenn/spotless`; the tag has to point at a commit there):
   ```bash
   cd ~/music-app/public-snapshot      # after publish-snapshot.sh and `git push origin main`
   git tag -a v1.0.0 -m "Spotless 1.0.0"
   git push origin v1.0.0
   ```
   Then watch Actions › Release macOS (about 30-60 minutes; notarization is usually a few of them).

## Every release after that

1. Bump `version` in `src-tauri/tauri.conf.json` and `[workspace.package]` in `Cargo.toml`
   (the workflow fails if either differs from the tag), commit, run `scripts/publish-snapshot.sh`
   and push the snapshot's `main`.
2. Release notes, first found wins: `RELEASE_NOTES.md` at the repo root if it mentions the new
   version; the annotated tag's message (`git tag -a v1.0.1 -m "Spotless 1.0.1" -m "- Fixed …"`;
   the lines after the first become the notes); otherwise GitHub's generated notes. The same text
   shows in the app's update prompt.
3. Push the tag `v<version>` from the snapshot checkout. Or, from Actions › Release macOS › Run workflow, enter the tag: an
   existing tag is rebuilt and its assets replaced; a new one is created on the chosen branch.

## Secrets

| Secret | Contents |
|---|---|
| `MACOS_CERTIFICATE` | base64 of the Developer ID Application identity (.p12, certificate + private key) |
| `MACOS_CERTIFICATE_PASSWORD` | that .p12's password |
| `APPLE_API_KEY` | base64 of the App Store Connect API key (`AuthKey_….p8`) |
| `APPLE_API_KEY_ID` | its Key ID |
| `APPLE_API_ISSUER_ID` | its Issuer ID |
| `TAURI_SIGNING_PRIVATE_KEY` | contents of the updater key file |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | optional, only if that key has a password |

The workflow stops at its first step if one of the required ones is missing. In the job the
certificate lives in a temporary keychain with a random password, the key files in the runner's
temp folder; both are deleted at the end, also when the run fails. The signing identity is found
in that keychain, so its hash is not a secret.

## Local release (still works)

`scripts/release-mac.sh` with `SIGN_IDENTITY` and `NOTARY_PROFILE` set, as before (the script
header has the details). It also accepts `NOTARY_KEY_PATH` / `NOTARY_KEY_ID` / `NOTARY_ISSUER`
(the API key) instead of a profile. Output goes to `../dist`; upload the files it lists by hand.

## If a run fails

- **Version mismatch**: bump both version fields, commit, move the tag (`git tag -f -a v…` and
  `git push -f origin v…`) or tag a new version.
- **Notarization not accepted**: the log Apple returns is printed right above the error.
- **No valid identity**: the certificate expired or the .p12 lacks the private key; re-run the
  secrets script.
- **DMG without background**: the runner's Finder did not answer three times; the DMG still works
  (app + Applications link). Re-run the job for the styled one.
