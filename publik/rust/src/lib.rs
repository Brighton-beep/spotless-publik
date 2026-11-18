// SPDX-License-Identifier: GPL-3.0-or-later
//! publik's sign-in and usage counting for Spotless (publik/README.md).
//!
//! Only fjenn/spotless-publik has this crate; the app reaches it in three
//! places: [`start`] at launch, [`gate::spawn`] in setup and the gate's
//! commands. The sign-in screen itself is `ui/src/lib/publik/Gate.svelte`.
//!
//! - [`client`]: publik's app protocol (install, wallet, usage events, the
//!   release self test), the same requests, files and words as publik's own
//!   Rust module;
//! - [`gate`]: what the sign-in screen shows, until the person is signed in.

pub mod client;
#[cfg(test)]
mod fake;
pub mod gate;

/// This app on publik (its listing's slug). Defined in `client.rs`, the
/// file publik's scanner reads for the module's strings.
pub use client::APP_SLUG;
/// The app's version, given by [`start`] (this crate has its own version).
static APP_VERSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// The version publik is told about: the app's.
pub fn app_version() -> &'static str {
    APP_VERSION.get().map(String::as_str).unwrap_or("0.0.0")
}

/// First thing at launch: keeps the app's version and answers publik's
/// release self test (`PUBLIK_SELF_TEST=1`), which exits before anything
/// else starts.
pub fn start(app_version: &str) {
    let _ = APP_VERSION.set(app_version.to_string());
    client::self_test_if_requested();
}

/// Whether the app uses publik's AI models: no, so signed-in people never see
/// the plan screen.
pub const USES_AI: bool = false;
/// publik's model tiers, for if the app ever uses publik API.
pub const MODELS: [&str; 3] = ["publik-fast", "publik-balanced", "publik-smart"];
