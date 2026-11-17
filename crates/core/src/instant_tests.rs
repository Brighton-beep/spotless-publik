//! ── stream: instant ── A play shows its track before the audio: `now-playing` with `loading`
//! first, the real one once mpv has the file, and the last of two quick plays wins. Runs the real
//! core (mpv included) on two local WAV files, so nothing touches the network.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use innertube::SongItem;

use crate::host::Host;

struct Recorder {
    dir: PathBuf,
    events: Mutex<Vec<(String, serde_json::Value)>>,
}

impl Host for Recorder {
    fn emit_json(&self, event: &str, json: String) {
        let v = serde_json::from_str(&json).unwrap_or(serde_json::Value::Null);
        self.events.lock().unwrap().push((event.to_owned(), v));
    }
    fn data_dir(&self) -> PathBuf {
        self.dir.clone()
    }
}

impl Recorder {
    /// `(videoId, loading)` of every `now-playing` since the last call.
    fn now_playing(&self) -> Vec<(String, bool)> {
        let mut ev = self.events.lock().unwrap();
        let out = ev
            .iter()
            .filter(|(n, _)| n == "now-playing")
            .map(|(_, v)| {
                (v["videoId"].as_str().unwrap_or("").to_owned(), v["loading"].as_bool().unwrap_or(false))
            })
            .collect();
        ev.clear();
        out
    }
}

/// One second of 8 kHz mono silence.
fn wav(path: &Path) {
    wav_secs(path, 1);
}

/// `secs` seconds of 8 kHz mono silence.
fn wav_secs(path: &Path, secs: u32) {
    let n: u32 = 8000 * secs;
    let mut b = Vec::new();
    b.extend_from_slice(b"RIFF");
    b.extend_from_slice(&(36 + n * 2).to_le_bytes());
    b.extend_from_slice(b"WAVEfmt ");
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes()); // PCM
    b.extend_from_slice(&1u16.to_le_bytes()); // mono
    b.extend_from_slice(&8000u32.to_le_bytes());
    b.extend_from_slice(&16000u32.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&16u16.to_le_bytes());
    b.extend_from_slice(b"data");
    b.extend_from_slice(&(n * 2).to_le_bytes());
    b.resize(b.len() + (n * 2) as usize, 0);
    std::fs::write(path, b).unwrap();
}

fn song(path: &Path) -> SongItem {
    let id = format!("{}{}", crate::local::SONG_PREFIX, path.display());
    SongItem { video_id: id.clone(), title: id, artists: "Test".into(), ..Default::default() }
}

#[test]
fn play_shows_the_track_before_its_audio_and_the_last_tap_wins() {
    let dir = std::env::temp_dir().join(format!("encore-instant-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (a, b) = (dir.join("a.wav"), dir.join("b.wav"));
    wav(&a);
    wav(&b);
    let (a, b, gone) = (song(&a), song(&b), song(&dir.join("gone.wav")));

    let rec = Arc::new(Recorder { dir: dir.clone(), events: Mutex::default() });
    let db = crate::boot::open_db(&dir).unwrap();
    let Ok(booted) = crate::boot::assemble(rec.clone(), db, None, None) else {
        eprintln!("no libmpv here; skipping");
        return;
    };
    let st = booted.state.clone();
    let _ = st.player.set_volume(0);

    crate::rt::handle().block_on(async {
        // One play: the track is announced as loading, then as playing.
        st.play_tracks(vec![a.clone()], Some(0), None, None, false, None).await;
        let np = rec.now_playing();
        assert_eq!(np.first(), Some(&(a.video_id.clone(), true)), "loading first: {np:?}");
        assert_eq!(np.last(), Some(&(a.video_id.clone(), false)), "then playing: {np:?}");

        // Two quick plays: b's load supersedes a's, and a never comes back after b showed.
        let (s1, s2) = (st.clone(), st.clone());
        let (a2, b2) = (a.clone(), b.clone());
        let first = crate::rt::spawn(async move {
            s1.play_tracks(vec![a2], Some(0), None, None, false, None).await
        });
        // b is tapped once a's tap has been taken (its track shows): b is the later tap.
        while !rec.events.lock().unwrap().iter().any(|(n, _)| n == "now-playing") {
            tokio::task::yield_now().await;
        }
        let second = crate::rt::spawn(async move {
            s2.play_tracks(vec![b2], Some(0), None, None, false, None).await
        });
        let _ = tokio::join!(first, second);
        let np = rec.now_playing();
        assert_eq!(np.last(), Some(&(b.video_id.clone(), false)), "the last tap plays: {np:?}");
        let b_at = np.iter().position(|(id, _)| *id == b.video_id).unwrap();
        assert!(np[b_at..].iter().all(|(id, _)| *id == b.video_id), "a came back over b: {np:?}");

        // A load that gives up takes its loading state down again.
        st.play_tracks(vec![a.clone(), gone.clone()], Some(1), None, None, false, None).await;
        let np = rec.now_playing();
        assert_eq!(np.first(), Some(&(gone.video_id.clone(), true)), "{np:?}");
        assert_eq!(np.last(), Some(&(a.video_id.clone(), false)), "loading cleared after a failure: {np:?}");
    });
    let _ = std::fs::remove_dir_all(&dir);
}

/// ── stream: pod-fixes ── A chapter tapped before its episode plays: `play_playlist` with
/// `start_secs` opens that row there in one call. The loading state already shows the chapter's
/// time (the stream isn't resolved yet), mpv starts there, and the next plain play starts at 0.
#[test]
fn play_playlist_opens_the_start_row_at_start_secs() {
    let dir = std::env::temp_dir().join(format!("encore-startat-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (a, long) = (dir.join("a.wav"), dir.join("long.wav"));
    wav(&a);
    wav_secs(&long, 20);
    let (a, long) = (song(&a), song(&long));

    let rec = Arc::new(Recorder { dir: dir.clone(), events: Mutex::default() });
    let db = crate::boot::open_db(&dir).unwrap();
    let Ok(booted) = crate::boot::assemble(rec.clone(), db, None, None) else {
        eprintln!("no libmpv here; skipping");
        return;
    };
    let st = booted.state.clone();
    let _ = st.player.set_volume(0);

    crate::rt::handle().block_on(async {
        let items = vec![a.clone(), long.clone()];
        crate::api::play_playlist(&st, items, Some(1), None, None, None, None, None, Some(12.0))
            .await
            .unwrap();
        let ev = rec.events.lock().unwrap().clone();
        let loading = ev
            .iter()
            .position(|(n, v)| n == "now-playing" && v["loading"].as_bool() == Some(true))
            .expect("a loading now-playing");
        let shown = ev[loading..].iter().find(|(n, _)| n == "position").map(|(_, v)| v["position"].as_f64());
        assert_eq!(shown, Some(Some(12.0)), "the loading clock shows the chapter: {ev:?}");
        // mpv opened the file there: its clock never reads below the chapter.
        let mut pos = 0.0;
        for _ in 0..60 {
            pos = st.player.clock().unwrap_or(0.0);
            if pos > 0.0 {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert!(pos >= 11.5, "mpv started at {pos}, not at the chapter"); // audio-pts runs a buffer behind

        // The offset was the tapped row's alone: the next plain play starts at the top.
        crate::api::play_playlist(&st, vec![long.clone()], Some(0), None, None, None, None, None, None)
            .await
            .unwrap();
        let mut top = false;
        for _ in 0..60 {
            if st.player.clock().is_some_and(|p| p < 5.0) {
                top = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert!(top, "a plain play inherited the offset: {:?}", st.player.clock());
    });
    let _ = std::fs::remove_dir_all(&dir);
}
