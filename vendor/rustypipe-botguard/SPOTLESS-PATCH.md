# Vendored rustypipe-botguard 0.1.2 (MIT, see LICENSE)

Unchanged from crates.io except one line in `Cargo.toml`: reqwest uses `rustls-tls` instead of its
default `native-tls`, like the rest of the workspace. On Android `native-tls` means OpenSSL, which
the NDK doesn't ship. Wired in through `[patch.crates-io]` in the workspace `Cargo.toml`.
