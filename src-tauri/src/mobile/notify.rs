//! Android: the track-change toast is the player notification itself (MediaSession, M3), which
//! updates on every track change. Nothing extra to post here.

use tauri::AppHandle;

pub fn track_changed(_app: &AppHandle, _title: &str, _artists: &str, _even_focused: bool) {}
