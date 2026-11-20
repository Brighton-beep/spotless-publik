//! Android media integration: lock screen, notification shade, Bluetooth and headset buttons.
//!
//! The desktop drives MPRIS / SMTC / NowPlaying through souvlaki (media.rs); here the same calls
//! go to a Media3 MediaSession in a foreground service (gen/android: PlaybackService,
//! MediaSessionPlayer), which also keeps the process alive while music plays in the background.
//!
//! Rust → Android: the `spotless-media` plugin's `update` command, with the whole state each time.
//! Android → Rust: `Native.onMediaCommand`, a JNI export below, routed exactly like the desktop's
//! media keys.

use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;

use serde::Serialize;
use tauri::plugin::{Builder, PluginHandle, TauriPlugin};
use tauri::{AppHandle, Manager, Wry};

use crate::state::AppState;

/// The registered Kotlin plugin (MediaPlugin.kt).
struct MediaPlugin(PluginHandle<Wry>);

/// Registered in lib.rs on mobile.
pub fn init() -> TauriPlugin<Wry> {
    Builder::new("spotless-media")
        .setup(|app, api| {
            let handle = api.register_android_plugin("app.spotless.android", "MediaPlugin")?;
            app.manage(MediaPlugin(handle));
            Ok(())
        })
        .build()
}

/// What the notification shows. Times are listening seconds (position / speed), like the desktop.
#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct MediaState {
    title: String,
    artist: String,
    album: Option<String>,
    cover: Option<String>,
    duration_ms: i64,
    position_ms: i64,
    playing: bool,
}

enum MediaUpdate {
    Metadata { title: String, artist: String, album: Option<String>, cover: Option<String> },
    Album(String),
    Duration(f64),
    Playback { playing: bool, pos: f64 },
}

pub struct MediaHandle {
    tx: Sender<MediaUpdate>,
}

impl MediaHandle {
    pub fn set_metadata(&self, title: &str, artist: &str, album: Option<&str>, cover: Option<&str>) {
        let _ = self.tx.send(MediaUpdate::Metadata {
            title: title.to_owned(),
            artist: artist.to_owned(),
            album: album.map(str::to_owned),
            cover: cover.map(str::to_owned),
        });
    }

    pub fn set_album(&self, album: &str) {
        let _ = self.tx.send(MediaUpdate::Album(album.to_owned()));
    }

    pub fn set_duration(&self, secs: f64, speed: f64) {
        let _ = self.tx.send(MediaUpdate::Duration(secs / speed));
    }

    pub fn set_playback(&self, playing: bool, pos: f64, speed: f64) {
        let _ = self.tx.send(MediaUpdate::Playback { playing, pos: pos / speed });
    }

    /// The system volume is the phone's own; the app's level isn't mirrored to the session.
    pub fn set_volume(&self, _volume: i64) {}
}

/// Start the thread that keeps the session in step with the core. Called in `setup`, after the
/// plugins are registered.
pub fn spawn(app: AppHandle) -> Option<MediaHandle> {
    let (tx, rx) = channel::<MediaUpdate>();
    let spawned = std::thread::Builder::new().name("media-session".into()).spawn(move || {
        let Some(plugin) = app.try_state::<MediaPlugin>() else {
            tracing::warn!("media session plugin missing; no lock-screen controls");
            return;
        };
        let mut s = MediaState::default();
        while let Ok(update) = rx.recv() {
            match update {
                MediaUpdate::Metadata { title, artist, album, cover } => {
                    s.title = title;
                    s.artist = artist;
                    s.album = album;
                    s.cover = cover;
                    s.duration_ms = -1; // new track: length unknown until mpv reports it
                    s.position_ms = 0;
                }
                MediaUpdate::Album(album) => s.album = Some(album),
                MediaUpdate::Duration(secs) => s.duration_ms = (secs * 1000.0) as i64,
                MediaUpdate::Playback { playing, pos } => {
                    s.playing = playing;
                    s.position_ms = (pos.max(0.0) * 1000.0) as i64;
                }
            }
            if let Err(e) = plugin.0.run_mobile_plugin::<serde_json::Value>("update", s.clone()) {
                tracing::warn!(error = %e, "media session update failed");
            }
        }
    });
    match spawned {
        Ok(_) => Some(MediaHandle { tx }),
        Err(e) => {
            tracing::warn!(error = %e, "media session thread spawn failed");
            None
        }
    }
}

/// `Native.onMediaCommand(cmd, arg)` from MediaSessionPlayer.kt: a press on the lock screen, the
/// notification, a headset or a Bluetooth device. Same routing as the desktop's media keys.
#[no_mangle]
pub extern "system" fn Java_app_spotless_android_Native_onMediaCommand(
    mut env: jni::JNIEnv,
    _class: jni::objects::JClass,
    cmd: jni::objects::JString,
    arg: jni::sys::jdouble,
) {
    let Ok(cmd) = env.get_string(&cmd).map(String::from) else { return };
    let Some(app) = crate::commands::APP.get().cloned() else { return };
    tauri::async_runtime::spawn(async move {
        let Some(state) = app.try_state::<Arc<AppState>>() else { return };
        let state = state.inner().clone();
        match cmd.as_str() {
            "play" => {
                if state.player.is_paused() {
                    state.resume_or_toggle().await
                }
            }
            "pause" => {
                let _ = state.player.pause();
            }
            "next" => state.next_in_queue().await,
            "previous" => state.prev_in_queue().await,
            "seek" => {
                let _ = state.player.seek(arg.max(0.0) * state.player.speed());
            }
            other => tracing::debug!(cmd = other, "unknown media command"),
        }
    });
}
