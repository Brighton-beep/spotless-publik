//! YouTube Music sign-in on Android. Same flow as the desktop's session.rs, different windows:
//! the sign-in page runs in its own activity (LoginActivity.kt) instead of a second webview
//! window, and the cookies come from Android's per-app cookie store (LoginPlugin.kt `jar`). The
//! capture loop, the account checks and the session refresh are the desktop's, unchanged.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tauri::plugin::{Builder, PluginHandle, TauriPlugin};
use tauri::{AppHandle, Emitter, Manager, Wry};
use tokio::sync::mpsc::UnboundedSender;

use crate::state::AppState;

// The desktop's addresses (session.rs has the reasoning for each).
const LOGIN_URL: &str = "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F";
const ADD_ACCOUNT_URL: &str = "https://accounts.google.com/AddSession?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F";
const REFRESH_URL: &str = "https://music.youtube.com/";
const REFRESH_TIMEOUT: Duration = Duration::from_secs(45);
const REFRESH_COOLDOWN: Duration = Duration::from_secs(5 * 60);

/// The registered Kotlin plugin (LoginPlugin.kt).
struct LoginPlugin(PluginHandle<Wry>);

/// Registered in lib.rs on mobile.
pub fn init() -> TauriPlugin<Wry> {
    Builder::new("spotless-login")
        .setup(|app, api| {
            let handle = api.register_android_plugin("app.spotless.android", "LoginPlugin")?;
            app.manage(LoginPlugin(handle));
            Ok(())
        })
        .build()
}

#[derive(Serialize)]
struct Args<'a> {
    url: &'a str,
    clear: bool,
}

#[derive(Deserialize)]
struct Jar {
    open: bool,
    jar: String,
}

fn plugin(app: &AppHandle) -> Option<tauri::State<'_, LoginPlugin>> {
    app.try_state::<LoginPlugin>()
}

fn call<T: serde::de::DeserializeOwned>(app: &AppHandle, cmd: &str, args: impl Serialize) -> Option<T> {
    match plugin(app)?.0.run_mobile_plugin::<T>(cmd, args) {
        Ok(v) => Some(v),
        Err(e) => {
            tracing::warn!(cmd, error = %e, "sign-in plugin call failed");
            None
        }
    }
}

/// Page loads and the screen closing wake the capture loop (LoginActivity → Native.onLoginNudge).
static NUDGE: Mutex<Option<UnboundedSender<()>>> = Mutex::new(None);

#[no_mangle]
pub extern "system" fn Java_app_spotless_android_Native_onLoginNudge(
    _env: jni::JNIEnv,
    _class: jni::objects::JClass,
) {
    if let Some(tx) = NUDGE.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        let _ = tx.send(());
    }
}

/// The sign-in screen's youtube.com cookies, or `None` once it has been closed.
async fn read_login_jar(app: &AppHandle) -> Option<String> {
    let app = app.clone();
    let jar = tauri::async_runtime::spawn_blocking(move || call::<Jar>(&app, "jar", ())).await.ok()??;
    jar.open.then_some(jar.jar)
}

/// Open the sign-in screen and sign in once it holds a YouTube session (commands::login_webview).
pub fn open_login(app: AppHandle, state: Arc<AppState>, add_account: bool) {
    let (tx, mut nudge) = tokio::sync::mpsc::unbounded_channel::<()>();
    *NUDGE.lock().unwrap_or_else(|e| e.into_inner()) = Some(tx);
    tauri::async_runtime::spawn(async move {
        let url = if add_account { ADD_ACCOUNT_URL } else { LOGIN_URL };
        let opened = {
            let app = app.clone();
            tauri::async_runtime::spawn_blocking(move || {
                call::<serde_json::Value>(&app, "open", Args { url, clear: add_account }).is_some()
            })
            .await
            .unwrap_or(false)
        };
        if !opened {
            let _ = app.emit("login-error", "Couldn't open the sign-in screen");
            return;
        }
        let end = encore_core::login::capture(
            &state,
            || read_login_jar(&app),
            &mut nudge,
            encore_core::login::POLL,
            encore_core::login::TIMEOUT,
        )
        .await;
        tracing::info!(?end, "sign-in screen finished");
        cancel_login(&app);
    });
}

/// Close the sign-in screen (the main window's Cancel, or the capture finishing).
pub fn cancel_login(app: &AppHandle) {
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _ = call::<serde_json::Value>(&app, "close", ());
    });
}

/// Re-mint a session YouTube turned down, from the Google session still in the cookie store: load
/// YouTube Music off screen and sign in with the rotated cookies, as session.rs does on the desktop.
pub async fn refresh_session(app: AppHandle, state: Arc<AppState>) {
    if !state.it.is_logged_in() || !claim_refresh() {
        return;
    }
    let loaded = {
        let app = app.clone();
        let task = tauri::async_runtime::spawn_blocking(move || {
            call::<serde_json::Value>(&app, "refresh", Args { url: REFRESH_URL, clear: false }).is_some()
        });
        matches!(tokio::time::timeout(REFRESH_TIMEOUT, task).await, Ok(Ok(true)))
    };
    let end = |app: &AppHandle| {
        let app = app.clone();
        tauri::async_runtime::spawn_blocking(move || {
            let _ = call::<serde_json::Value>(&app, "endRefresh", ());
        });
    };
    if !loaded {
        tracing::debug!("session refresh: YouTube Music never loaded");
        end(&app);
        return;
    }
    for _ in 0..8 {
        let current = state.it.cookie().unwrap_or_default();
        let Some(account) = innertube::cookie_sapisid(&current) else { break };
        let cookie = {
            let app = app.clone();
            tauri::async_runtime::spawn_blocking(move || call::<Jar>(&app, "jar", ()))
                .await
                .ok()
                .flatten()
                .map(|j| j.jar)
                .unwrap_or_default()
        };
        if innertube::cookie_sapisid(&cookie) == Some(account) && !same_jar(&cookie, &current) {
            match state.sign_in(cookie, Some(account)).await {
                Ok(_) => tracing::info!("re-minted the login session from the cookie store"),
                Err(error) => tracing::warn!(%error, "could not re-mint the login session"),
            }
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    end(&app);
}

/// Same cookies, whatever order they came out in (session.rs).
fn same_jar(a: &str, b: &str) -> bool {
    let pairs = |s: &str| {
        let mut v: Vec<String> = s.split(';').map(|kv| kv.trim().to_owned()).filter(|kv| !kv.is_empty()).collect();
        v.sort();
        v
    };
    pairs(a) == pairs(b)
}

/// Not more than one refresh per cooldown: a stale session throws off a burst of 401s (session.rs).
fn claim_refresh() -> bool {
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
    if last.is_some_and(|t| t.elapsed() < REFRESH_COOLDOWN) {
        return false;
    }
    *last = Some(Instant::now());
    true
}
