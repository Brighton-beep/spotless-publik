//! Android: the app is full screen, there is no window frame to save or restore.

use tauri::{AppHandle, Runtime, Window, WindowEvent};

pub fn on_event<R: Runtime>(_w: &Window<R>, _e: &WindowEvent) {}

pub fn on_exit<R: Runtime>(_app: &AppHandle<R>) {}
