//! Android: no menu bar. Its playback items are the player notification's buttons (M3, the
//! MediaSession in gen/android) and its UI items are the app's own screens. Only the hook the
//! downloads manager calls is kept.

use tauri::AppHandle;

pub fn sync_offline_mode(_app: &AppHandle, _on: bool) {}
