//! The main window's saved frame: what the window-state plugin reopens at.
//!
//! The plugin only writes its file on `RunEvent::Exit`, and it saves whatever the window is at
//! that moment. Two ways that went wrong (the window reopened at the old small size):
//!
//! - **No clean exit.** A crash, a force quit or a kill (every dev rebuild) never reaches `Exit`,
//!   so a size set after the last clean exit, including the large first-launch default, was lost.
//!   We now save shortly after the window settles from every resize/move.
//! - **Full screen.** macOS full screen is not "maximized" to the plugin, so it tracks and saves
//!   the full-screen size and position, and the next launch opens a window-sized copy of the
//!   screen, or a stale value. We remember the last *normal* frame (not full screen, minimized
//!   or maximized) and write that into the plugin's file on exit, after the plugin's own save.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use tauri::{AppHandle, Manager, Runtime, Window, WindowEvent};
use tauri_plugin_window_state::{AppHandleExt, StateFlags};

/// What the plugin restores for "main".
pub const FLAGS: StateFlags = StateFlags::SIZE.union(StateFlags::POSITION).union(StateFlags::MAXIMIZED);

/// How long the window has to sit still before its frame is written to disk.
const SETTLE: Duration = Duration::from_millis(800);

#[derive(Clone, Copy, Debug, PartialEq)]
struct Frame {
    width: u32,
    height: u32,
    x: i32,
    y: i32,
}

static NORMAL: Mutex<Option<Frame>> = Mutex::new(None);
static GENERATION: AtomicU64 = AtomicU64::new(0);

fn normal<R: Runtime>(w: &Window<R>) -> bool {
    !w.is_fullscreen().unwrap_or(false)
        && !w.is_minimized().unwrap_or(false)
        && !w.is_maximized().unwrap_or(false)
}

/// `on_window_event` hook (main window only).
pub fn on_event<R: Runtime>(w: &Window<R>, e: &WindowEvent) {
    if w.label() != "main" || !matches!(e, WindowEvent::Resized(_) | WindowEvent::Moved(_)) {
        return;
    }
    if !normal(w) {
        return;
    }
    let (Ok(size), Ok(pos)) = (w.inner_size(), w.outer_position()) else { return };
    if size.width == 0 || size.height == 0 {
        return;
    }
    *NORMAL.lock().unwrap() = Some(Frame { width: size.width, height: size.height, x: pos.x, y: pos.y });
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    let w = w.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(SETTLE).await;
        // Still the latest change, and still a normal window (not mid full-screen animation).
        if GENERATION.load(Ordering::SeqCst) == generation && normal(&w) {
            let _ = w.app_handle().save_window_state(FLAGS);
        }
    });
}

/// `RunEvent::Exit` hook, run after the plugin's own save: put the last normal frame back over
/// whatever it wrote (a full-screen size when the app quit in full screen).
pub fn on_exit<R: Runtime>(app: &AppHandle<R>) {
    let Some(frame) = *NORMAL.lock().unwrap() else { return };
    let Ok(dir) = app.path().app_config_dir() else { return };
    let path = dir.join(app.filename());
    let mut root: serde_json::Value = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    if patch(&mut root, frame) {
        if let Ok(bytes) = serde_json::to_vec_pretty(&root) {
            let _ = std::fs::write(&path, bytes);
        }
    }
}

/// Write `frame` into the plugin file's "main" entry. False when there is no entry to patch (the
/// plugin always writes one on exit; without it the file isn't ours to invent).
fn patch(root: &mut serde_json::Value, frame: Frame) -> bool {
    let Some(main) = root.get_mut("main").and_then(|m| m.as_object_mut()) else { return false };
    main.insert("width".into(), frame.width.into());
    main.insert("height".into(), frame.height.into());
    main.insert("x".into(), frame.x.into());
    main.insert("y".into(), frame.y.into());
    main.insert("fullscreen".into(), false.into());
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_in_full_screen_keeps_the_normal_frame() {
        // What the plugin wrote quitting in full screen on a 1728x1117 display at 2x.
        let mut root = serde_json::json!({ "main": {
            "width": 3456, "height": 2234, "x": 0, "y": 0, "prev_x": 0, "prev_y": 0,
            "maximized": false, "visible": true, "decorated": true, "fullscreen": true
        } });
        let frame = Frame { width: 3110, height: 1944, x: 172, y: 120 };
        assert!(patch(&mut root, frame));
        let m = &root["main"];
        assert_eq!((m["width"].as_u64(), m["height"].as_u64()), (Some(3110), Some(1944)));
        assert_eq!((m["x"].as_i64(), m["y"].as_i64()), (Some(172), Some(120)));
        assert_eq!(m["fullscreen"], false);
        assert_eq!(m["maximized"], false, "other fields untouched");
        assert!(!patch(&mut serde_json::json!({}), frame));
    }
}
