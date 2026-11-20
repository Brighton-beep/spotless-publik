//! Android media integration: lock screen, notification shade, Bluetooth and headset buttons.
//!
//! The desktop drives MPRIS / SMTC / NowPlaying through souvlaki; on Android the same calls go to
//! a Media3 MediaSession owned by a foreground service (gen/android). Filled in at milestone M3;
//! until then `spawn` returns `None`, which the core already treats as "no OS integration".

use tauri::AppHandle;

pub struct MediaHandle {}

impl MediaHandle {
    pub fn set_metadata(&self, _title: &str, _artist: &str, _album: Option<&str>, _cover: Option<&str>) {}
    pub fn set_album(&self, _album: &str) {}
    pub fn set_duration(&self, _secs: f64, _speed: f64) {}
    pub fn set_playback(&self, _playing: bool, _pos: f64, _speed: f64) {}
    pub fn set_volume(&self, _volume: i64) {}
}

pub fn spawn(_app: AppHandle) -> Option<MediaHandle> {
    None
}
