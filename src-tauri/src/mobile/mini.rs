//! Android: no mini player. It is a floating desktop window; on a phone the player notification
//! and lock screen (M3) are where the music is controlled from outside the app.

use tauri::AppHandle;

pub const LABEL: &str = "mini";

pub fn open(_app: &AppHandle) -> Result<(), String> {
    Err("The mini player is a desktop window; Android uses the player notification".into())
}

pub fn dismiss(_app: &AppHandle) {}

pub fn set_compact(_app: &AppHandle, _compact: bool) -> Result<(), String> {
    Ok(())
}

pub fn save_position(_app: &AppHandle) {}

pub fn close(_app: &AppHandle) {}
