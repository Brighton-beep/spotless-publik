# Contributing

Thanks for wanting to help. Spotless is a small project, so this is short.

## Before you start

- **Bugs:** open an issue with the bug form. Settings > About can copy your system details for you.
- **Bigger changes** (a new page, a new integration, anything that changes playback or
  extraction): open an issue first and describe what you want to build, so we can agree on the
  scope before you write code. Bug fixes can go straight to a pull request.

## Getting set up

Prerequisites and the build steps are in the [README](README.md#building-from-source). macOS
specifics live in [docs/BUILD-PLATFORMS.md](docs/BUILD-PLATFORMS.md).

Run the Mac app with hot reload:

```bash
export LIBRARY_PATH="$(brew --prefix)/lib:$LIBRARY_PATH"   # libmpv
cargo tauri dev
```

## Layout

- `crates/core`: the shared Rust core (search, library, recommendations, downloads, podcasts,
  lyrics). Both apps call into it; logic belongs here, not in a UI.
- `crates/innertube`: the YouTube Music API client.
- `crates/player`: audio decoding and playback for the Mac app (libmpv).
- `crates/ffi`: the UniFFI bindings the iPhone app uses.
- `src-tauri` + `ui`: the Mac app (Tauri 2, Svelte 5).
- `ios/Encore`: the iPhone app (SwiftUI), generated with XcodeGen from `project.yml`.

## Formatting

```bash
cargo fmt --all
```

`rustfmt.toml` is committed, so `cargo fmt` should only touch the code you changed. The frontend
has no Prettier config: match the style of the file you are in.

## Tests

```bash
export LIBRARY_PATH="$(brew --prefix)/lib:$LIBRARY_PATH"
cargo test -p limusic-app --lib                          # Mac app + core, no network
cargo test -p limusic-app --lib -- --ignored --nocapture # also the live checks (network)
cd ui && pnpm check                                      # svelte-check + types
ios/Encore/scripts/test.sh                               # iPhone unit + snapshot tests
```

Tests that talk to the network are `#[ignore]`d so the default run works offline. A lyrics
provider whose endpoint has changed returns "no lyrics" rather than an error, so run the ignored
tests if you touch one.

Live YouTube extraction checks are behind a feature flag:

```bash
cargo test -p innertube --features integration-tests -- --nocapture
```

A failure there usually means YouTube changed something, not that your patch is wrong.

## Pull requests

- One change per pull request, opened from a branch.
- Say why: what problem the change fixes, not only what the code does.
- Say what you tested ("played five tracks, checked the queue after a restart").
- Used AI to write the code? Name the model in the description.

## A note on scope

Spotless talks to YouTube's private API and breaks whenever YouTube changes something. Anything
extraction-related has to stay updatable (client versions in config, not hard-coded) and degrade
gracefully when a step fails.
