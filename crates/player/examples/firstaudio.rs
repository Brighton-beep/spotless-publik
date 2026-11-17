//! stream: firstaudio. Load → first audible tick through the real `Player`, N times:
//! `cargo run --release -p player --example firstaudio -- <url-or-path> [reps]`
//! Prints one line per play with the milliseconds from `load` to the first position past 50 ms,
//! which is mpv's share of time-to-first-audio (docs/streams/firstaudio.md).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use player::{Player, PlayerEvent};

#[tokio::main]
async fn main() {
    let url = std::env::args().nth(1).expect("url");
    let reps: usize = std::env::args().nth(2).and_then(|n| n.parse().ok()).unwrap_or(8);
    let cache = std::env::temp_dir().join("limusic-firstaudio-example");
    std::fs::create_dir_all(&cache).ok();
    let mut p = Player::new(cache.to_str().unwrap()).expect("player");
    let mut events = p.take_events().unwrap();
    p.set_volume(0).ok();
    let mut all = vec![];
    for i in 0..reps {
        // Alternate the start between a fresh queue and a replace of a playing track.
        let t0 = Instant::now();
        p.load(&url, &HashMap::new(), Some(-3.0), None, false).expect("load");
        p.play().expect("play");
        let mut got = None;
        let mut reset = false;
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            match tokio::time::timeout(Duration::from_millis(500), events.recv()).await {
                Ok(Some(PlayerEvent::Position(x))) if x < 0.05 => reset = true,
                Ok(Some(PlayerEvent::Position(x))) if x > 0.05 && reset => {
                    got = Some(t0.elapsed());
                    break;
                }
                Ok(Some(_)) | Err(_) => {}
                Ok(None) => break,
            }
        }
        let ms = got.map(|d| d.as_secs_f64() * 1000.0);
        println!("play {i}: {ms:?} ms");
        if let Some(ms) = ms {
            all.push(ms);
        }
        tokio::time::sleep(Duration::from_millis(700)).await;
        // FA_IDLE=1: every load starts from a stopped player, as the first play after launch does.
        if std::env::var_os("FA_IDLE").is_some() {
            p.stop().ok();
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        while events.try_recv().is_ok() {}
    }
    all.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if !all.is_empty() {
        println!("median {:.1} ms (min {:.1}, max {:.1})", all[all.len() / 2], all[0], all[all.len() - 1]);
    }
}
