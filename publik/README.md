# The publik edition of Spotless

This repository, **fjenn/spotless-publik**, is exactly [fjenn/spotless](https://github.com/fjenn/spotless)
plus a small layer that publik ([publikhq.com](https://publikhq.com)) needs to list the app:

- **Sign in with publik.** At launch the app window shows "Sign in with publik" over the app
  (`ui/src/lib/publik/Gate.svelte`) until the person has signed in in the browser; there is no way
  past it, as publik's own module does it. The flow and publik's requests are in `publik/rust/`
  (`gate.rs`, `client.rs`).
- **Usage counting.** After sign-in, `app_opened`, then `active_session` every 30 minutes while
  the app runs (`POST /api/v1/telemetry`). `DO_NOT_TRACK`, `PUBLIK_TELEMETRY=0` or publik's
  `consent.json` turn it off.
- **publik's release self test.** `PUBLIK_SELF_TEST=1` on a built app prints
  `publik self-test: ok spotless <version>` (or why not) and exits.
- **Its own updates.** `src-tauri/tauri.conf.json` points the updater at this repository's
  releases, so a publik copy only ever updates to the publik edition.

The app uses no AI, so signed-in people never see a plan screen (`USES_AI = false`).
`src-tauri/publik-app-token.txt` is publik's app token, committed as publik's guide says: a `pat_`
token only mints capped keys for this app.

## The layer

Every file that differs from fjenn/spotless is listed in `publik/layer-files.txt`. Outside
`publik/` there are only small hooks, each marked "publik edition": `publik::start` at the top of
`run()`, `publik::gate::spawn` in `setup`, the gate's two commands in `src-tauri/src/lib.rs`; the
crate in the workspace (`Cargo.toml`) and in `src-tauri/Cargo.toml`; the screen in
`ui/src/routes/+layout.svelte`; the update feed; and the README banner.

## Keeping the two in step

`publik/sync.sh` (hourly in `.github/workflows/publik-sync.yml`, or by hand) merges
fjenn/spotless's `main` into this `main`. It refuses to push when the result differs from
fjenn/spotless anywhere outside the layer (version lines excepted, below), and a conflict stops it
with an issue opened here. When fjenn/spotless changes a workflow file, GitHub does not let the
Actions token push it: run `publik/sync.sh` from a clone then. Every other change is made in
fjenn/spotless and arrives by the sync. Workflows other than the Mac release and the sync are
disabled in this repository's Actions settings.

## Releasing

After fjenn/spotless releases vX (and the sync brought it in): `publik/release.sh vX`. GitHub then
builds, signs, notarizes and publishes the universal app with `release-mac.yml`, the workflow
fjenn/spotless uses, into this repository. publik reads each version once, so a fix that only the
publik edition needs ships as `vX.N` (`publik/release.sh v1.0.4-rc.5.1`): `publik/set-version.py`
commits that version on `main`, and `sync.sh` hands it back when fjenn/spotless releases its next
version.

Secrets (the same names as fjenn/spotless; `scripts/ci/setup-github-secrets.sh --repo
fjenn/spotless-publik` sets them): `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`,
`APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `TAURI_SIGNING_PRIVATE_KEY`.
