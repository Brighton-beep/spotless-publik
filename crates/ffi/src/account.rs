//! Stream ios-p2: the optional YouTube account on iPhone (the desktop's `session.rs`, minus the
//! window). The app runs Google's own sign-in page in a `WKWebView`, reads the youtube.com cookies
//! out of `WKHTTPCookieStore` itself (the password never reaches the app), and hands the `Cookie`
//! header here. From then on it is the desktop's path exactly: `AppState::sign_in` validates it,
//! picks the channel, and seals the cookie into the Keychain (`secrets`, through `SecretStore`).
//!
//! The session upkeep the desktop runs from `src-tauri/src/lib.rs` runs here too: a rotated
//! `__Secure-*SIDTS` is persisted, a half-hourly keep-alive rolls the tokens, and a rejected
//! session is reported to the app (`session-rejected`) so it can re-mint the jar from its own
//! persistent web view (`refresh_session` on the desktop) and call `account_sign_in` again with
//! `expectAccount`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use encore_core::state::{AppState, SignInOutcome};
use encore_core::HostExt;
use serde_json::Value;

use crate::invoke::Args;

static WATCHING: AtomicBool = AtomicBool::new(false);

/// The account commands (`get_account`, `account_sign_in`, `sign_out`, the channel picker, and
/// `account_watch`). `None`: not one of them.
pub(crate) async fn dispatch(st: &Arc<AppState>, cmd: &str, a: &Args) -> Option<Result<Value, String>> {
    Some(match cmd {
        "get_account" => Ok(st.account_snapshot()),
        // The `Cookie` header from the sign-in web view. Answers the account (with
        // `selectionRequired` when a multi-channel login still needs its channel picked).
        "account_sign_in" => sign_in(st, a).await,
        "sign_out" => {
            st.sign_out().await;
            Ok(st.account_snapshot())
        }
        "get_account_identities" => st.account_identities().await.map(Value::from),
        "switch_account" => match a.get::<String>("selectionKey") {
            Ok(key) => st.switch_account(&key).await,
            Err(e) => Err(e),
        },
        // Once per process: start the session upkeep (idempotent).
        "account_watch" => {
            watch(st.clone());
            Ok(Value::Null)
        }
        _ => return None,
    })
}

async fn sign_in(st: &Arc<AppState>, a: &Args) -> Result<Value, String> {
    let cookie: String = a.get("cookie")?;
    let expect: Option<String> = a.get("expectAccount")?;
    let cookie = youtube_only(&cookie);
    match innertube::without_healing(st.sign_in(cookie, expect.as_deref())).await? {
        SignInOutcome::Complete | SignInOutcome::SelectionRequired => {}
    }
    watch(st.clone());
    Ok(st.account_snapshot())
}

/// The app already sends only youtube.com cookies (the desktop's `youtube_cookie_header`); this
/// drops anything that isn't `name=value` so a malformed pair can't poison the header.
fn youtube_only(header: &str) -> String {
    header
        .split(';')
        .map(str::trim)
        .filter(|p| p.split_once('=').is_some_and(|(k, _)| !k.is_empty() && !k.contains(' ')))
        .collect::<Vec<_>>()
        .join("; ")
}

/// The desktop's session loop (`lib.rs`, #165 / KI-2), with the re-mint handed to the app.
fn watch(st: Arc<AppState>) {
    if WATCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    let rejected = st.it.session_rejected();
    let rotated = st.it.cookie_changed();
    encore_core::rt::spawn(async move {
        let mut keepalive = tokio::time::interval(Duration::from_secs(30 * 60));
        keepalive.tick().await;
        loop {
            tokio::select! {
                _ = rejected.notified() => {
                    if st.it.is_logged_in() {
                        let _ = st.host.emit("session-rejected", &serde_json::json!({}));
                    }
                }
                _ = rotated.notified() => st.persist_rotated_cookie(),
                _ = keepalive.tick() => st.keep_session_alive().await,
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::youtube_only;

    #[test]
    fn keeps_pairs_and_drops_junk() {
        assert_eq!(youtube_only("SAPISID=a; SID=b;; junk ; =x"), "SAPISID=a; SID=b");
        assert_eq!(innertube::cookie_sapisid(&youtube_only(" SAPISID=abc ")), Some("abc"));
    }
}
