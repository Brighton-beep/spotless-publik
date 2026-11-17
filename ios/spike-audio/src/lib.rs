//! iOS spike S1 (audio). The checks `crates/player/src/audio_tests.rs` runs on the desktop, run
//! again inside the iOS app against MPVKit's libmpv: output to mpv's `pcm` writer (no speakers),
//! sample counts asserted. Plus a live mode for the background test (a real AudioUnit output).
//!
//! C surface: `include/spike_audio.h`.

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use libmpv2::mpv_node::MpvNode;
use libmpv2::Mpv;
use player::{dsp, EqSettings, Player, PlayerEvent};
use serde_json::{json, Value};

const RATE: usize = 48_000;
const TONE_DB: f64 = -12.04;

type Check = Result<Value, String>;

fn wait_for(label: &str, timeout: f64, mut ready: impl FnMut() -> bool) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs_f64(timeout);
    while !ready() {
        if Instant::now() >= deadline {
            return Err(format!("timed out: {label}"));
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    Ok(())
}

fn ensure(cond: bool, msg: impl Into<String>) -> Result<(), String> {
    if cond {
        Ok(())
    } else {
        Err(msg.into())
    }
}

fn e2s(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Frames in a 16-bit stereo PCM WAV with a 44-byte header (the bundled fixtures).
fn wav_frames(path: &Path) -> Result<usize, String> {
    let len = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?.len();
    Ok((len as usize - 44) / 4)
}

/// A 16-bit stereo WAV of a 997 Hz tone at -12 dBFS, as `audio_tests.rs` writes it.
fn tone_wav(path: &Path, seconds: f64) -> Result<usize, String> {
    let frames = (seconds * RATE as f64).round() as u32;
    let bytes = frames * 4;
    let mut data = Vec::with_capacity(bytes as usize + 44);
    data.extend_from_slice(b"RIFF");
    data.extend_from_slice(&(bytes + 36).to_le_bytes());
    data.extend_from_slice(b"WAVEfmt \x10\0\0\0\x01\0\x02\0");
    data.extend_from_slice(&(RATE as u32).to_le_bytes());
    data.extend_from_slice(&(RATE as u32 * 4).to_le_bytes());
    data.extend_from_slice(b"\x04\0\x10\0data");
    data.extend_from_slice(&bytes.to_le_bytes());
    for frame in 0..frames {
        let t = frame as f64 / RATE as f64;
        let v = ((std::f64::consts::TAU * 997.0 * t).sin() * 0.25 * 32767.0) as i16;
        data.extend_from_slice(&v.to_le_bytes());
        data.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, data).map_err(e2s)?;
    Ok(frames as usize)
}

fn pcm(mpv: &Mpv, output: &Path) -> Result<(), String> {
    // A previous run's file would otherwise be read before mpv truncates it.
    let _ = std::fs::remove_file(output);
    mpv.set_property("ao", "pcm").map_err(e2s)?;
    mpv.set_property("ao-pcm-file", output.to_str().unwrap()).map_err(e2s)?;
    mpv.set_property("ao-pcm-waveheader", false).map_err(e2s)?;
    mpv.set_property("audio-format", "s16").map_err(e2s)?;
    mpv.set_property("audio-samplerate", RATE as i64).map_err(e2s)?;
    mpv.set_property("audio-channels", "stereo").map_err(e2s)?;
    mpv.set_property("pause", true).map_err(e2s)?;
    Ok(())
}

/// Left channel, as floats.
fn samples(path: &Path) -> Result<Vec<f64>, String> {
    Ok(std::fs::read(path)
        .map_err(e2s)?
        .chunks_exact(4)
        .map(|s| i16::from_le_bytes([s[0], s[1]]) as f64 / 32768.0)
        .collect())
}

fn level(s: &[f64], at: usize, n: usize) -> f64 {
    let peak = s[at.min(s.len())..(at + n).min(s.len())].iter().fold(0.0f64, |m, v| m.max(v.abs()));
    20.0 * peak.max(1e-9).log10()
}

/// Wait for the end, then unload so the pcm writer flushes. Returns `time-pos` at the end.
fn wait_eof(p: &Player) -> Result<f64, String> {
    wait_for("EOF", 20.0, || p.raw_mpv().get_property::<bool>("eof-reached").unwrap_or(false))?;
    let at = p.raw_mpv().get_property::<f64>("time-pos").unwrap_or(-1.0);
    p.stop().map_err(e2s)?;
    wait_for("unload", 5.0, || p.raw_mpv().get_property::<String>("path").is_err())?;
    Ok(at)
}

fn new_player(work: &Path) -> Result<Player, String> {
    let cache = work.join("cache");
    std::fs::create_dir_all(&cache).map_err(e2s)?;
    Player::new(cache.to_str().unwrap()).map_err(e2s)
}

/// A bundled WAV plays to the end through the player: every frame written, position advanced.
fn wav_plays(fx: &Path, work: &Path) -> Check {
    let a = fx.join("a.wav");
    let frames = wav_frames(&a)?;
    let mut p = new_player(work)?;
    let mut events = p.take_events().unwrap();
    let out = work.join("wav.pcm");
    pcm(p.raw_mpv(), &out)?;
    p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
    p.load(a.to_str().unwrap(), &HashMap::new(), None, None, false).map_err(e2s)?;
    p.play().map_err(e2s)?;
    let end_pos = wait_eof(&p)?;
    let mut max_pos = 0.0f64;
    let mut ended = 0;
    while let Ok(e) = events.try_recv() {
        match e {
            PlayerEvent::Position(t) => max_pos = max_pos.max(t),
            PlayerEvent::TrackEnded => ended += 1,
            _ => {}
        }
    }
    let got = std::fs::metadata(&out).map_err(e2s)?.len() as usize / 4;
    ensure(got == frames, format!("wrote {got} frames, fixture has {frames}"))?;
    ensure(end_pos > 0.95, format!("time-pos at the end was {end_pos}"))?;
    Ok(json!({
        "frames": got, "expected": frames, "end_position": end_pos,
        "position_events_max": max_pos, "track_ended_events": ended,
    }))
}

/// Same as the desktop `gapless_boundary_is_sample_exact_and_switches_gain_on_the_sample`.
fn gapless(fx: &Path, work: &Path) -> Check {
    let (a, b) = (fx.join("a.wav"), fx.join("b.wav"));
    let (frames_a, frames_b) = (wav_frames(&a)?, wav_frames(&b)?);
    let mut p = new_player(work)?;
    let mut events = p.take_events().unwrap();
    let out = work.join("gapless.pcm");
    pcm(p.raw_mpv(), &out)?;
    p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
    p.load(a.to_str().unwrap(), &HashMap::new(), None, None, false).map_err(e2s)?;
    p.enqueue_with_gain(b.to_str().unwrap(), Some(-12.0)).map_err(e2s)?;
    p.play().map_err(e2s)?;
    wait_for("first track end", 20.0, || matches!(events.try_recv(), Ok(PlayerEvent::TrackEnded)))?;
    let before = p.filter_chain();
    p.set_gain(Some(-12.0)).map_err(e2s)?;
    ensure(p.filter_chain() == before, "the advance rebuilt the chain")?;
    wait_eof(&p)?;
    let s = samples(&out)?;
    ensure(
        s.len() == frames_a + frames_b,
        format!("gap or overlap: {} frames, want {} + {}", s.len(), frames_a, frames_b),
    )?;
    let pre = level(&s, frames_a - 480, 480);
    let post = level(&s, frames_a, 480);
    ensure((pre - TONE_DB).abs() < 0.1, format!("track 1 at {pre}"))?;
    ensure((post - (TONE_DB - 12.0)).abs() < 0.1, format!("track 2's first 10 ms at {post}"))?;
    Ok(json!({"frames": s.len(), "expected": frames_a + frames_b, "pre_db": pre, "post_db": post}))
}

/// The player's own EQ path (`set_eq` before load), as on the desktop. Since stream ios-eq the
/// player detects MPVKit's FFmpeg and builds the portable chain, so this passes on iOS.
fn eq_player(fx: &Path, work: &Path) -> Check {
    let p = new_player(work)?;
    let out = work.join("eq-player.pcm");
    pcm(p.raw_mpv(), &out)?;
    p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
    p.set_eq(EqSettings { enabled: true, gains: [0.0, 0.0, 0.0, -1.0, 0.0, 0.0] }, true)
        .map_err(e2s)?;
    let a = fx.join("a.wav");
    p.load(a.to_str().unwrap(), &HashMap::new(), Some(-3.0), None, false).map_err(e2s)?;
    p.play().map_err(e2s)?;
    wait_eof(&p)?;
    let frames = std::fs::metadata(&out).map_err(e2s)?.len() as usize / 4;
    ensure(
        frames == wav_frames(&a)?,
        format!("player EQ chain wrote {frames} frames: the graph did not build"),
    )?;
    Ok(json!({"chain": p.filter_chain(), "frames": frames}))
}

/// `af-command` retunes a running lavfi graph on this libmpv: the desktop test's mechanism
/// (labelled `@enc` graph, `af-command enc g <dB> equalizer@b3`, commands from `dsp::Stage`),
/// on the filters MPVKit has (`volume`, `equalizer`).
///
/// Pacing: the pcm writer is untimed and MPVKit has neither the lavfi input device nor
/// `arealtime`, so the desktop's real-time sine source is out. Instead a 60 s tone (rendered in
/// well under a second, but not instantly): the command lands once 1 MB of output exists, and
/// the tail must show the new level, with mpv's `af` string unchanged (no rebuild). Not a looped
/// short file: a loop seeks, and a seek resets the graph to what `af` says.
fn eq_live(work: &Path) -> Check {
    let p = new_player(work)?;
    let mpv = p.raw_mpv();
    let out = work.join("eq.pcm");
    pcm(mpv, &out)?;
    let stage = |b3: f64| {
        let eq = EqSettings { enabled: true, gains: [0.0, 0.0, 0.0, b3, 0.0, 0.0] };
        let mut st = dsp::Stage::new(Some(-3.0), &eq);
        st.limiter = false;
        st
    };
    let (from, to) = (stage(-1.0), stage(-9.0));
    // Same graph the player builds, shelves swapped for unity `equalizer`s MPVKit can make.
    let graph = from.graph().replace("lowshelf@", "equalizer@").replace("highshelf@", "equalizer@");
    let af = format!("@{}:lavfi=graph=%{}%{graph}", dsp::LABEL, graph.len());
    mpv.set_property("af", af.as_str()).map_err(e2s)?;
    mpv.set_property("keep-open", true).map_err(e2s)?;
    let tone = work.join("tone-60s.wav");
    tone_wav(&tone, 60.0)?;
    mpv.command("loadfile", &[tone.to_str().unwrap(), "replace"]).map_err(e2s)?;
    p.play().map_err(e2s)?;
    let size = || std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
    wait_for("1 MB of output", 10.0, || size() > 1_000_000)?;
    let built: String = mpv.get_property("af").map_err(e2s)?;
    let cmds = from.commands_to(&to);
    ensure(!cmds.is_empty(), "no af-command to send")?;
    for c in &cmds {
        let args: Vec<&str> = c.iter().map(String::as_str).collect();
        mpv.command("af-command", &args).map_err(|e| format!("af-command {args:?}: {e}"))?;
    }
    let at = size();
    let after_af: String = mpv.get_property("af").map_err(e2s)?;
    wait_eof(&p)?;
    ensure(after_af == built, "af changed: the graph was rebuilt")?;
    let s = samples(&out)?;
    let before = level(&s, 4800, 4800);
    let after = level(&s, s.len().saturating_sub(9600), 4800);
    ensure(
        ((before - after) - 8.0).abs() < 0.3,
        format!("-1 dB to -9 dB moved {before} -> {after}"),
    )?;
    Ok(json!({
        "af": built, "commands": cmds, "before_db": before, "after_db": after,
        "output_frames": s.len(), "command_at_frame": at / 4,
    }))
}

// ── stream: ios-eq. The player's own chain on MPVKit (the portable flavor, auto-detected) ──

fn float_peak_db(path: &Path) -> Result<f64, String> {
    let peak = std::fs::read(path)
        .map_err(e2s)?
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]).abs())
        .fold(0.0f32, f32::max);
    Ok(20.0 * (peak as f64).max(1e-9).log10())
}

/// A 16-bit stereo 48 kHz WAV of `signal(t)`.
fn wav_of(path: &Path, seconds: f64, signal: impl Fn(f64) -> f64) -> Result<usize, String> {
    let frames = (seconds * RATE as f64).round() as u32;
    let bytes = frames * 4;
    let mut data = Vec::with_capacity(bytes as usize + 44);
    data.extend_from_slice(b"RIFF");
    data.extend_from_slice(&(bytes + 36).to_le_bytes());
    data.extend_from_slice(b"WAVEfmt \x10\0\0\0\x01\0\x02\0");
    data.extend_from_slice(&(RATE as u32).to_le_bytes());
    data.extend_from_slice(&(RATE as u32 * 4).to_le_bytes());
    data.extend_from_slice(b"\x04\0\x10\0data");
    data.extend_from_slice(&bytes.to_le_bytes());
    for frame in 0..frames {
        let v = (signal(frame as f64 / RATE as f64).clamp(-1.0, 1.0) * 32767.0) as i16;
        data.extend_from_slice(&v.to_le_bytes());
        data.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, data).map_err(e2s)?;
    Ok(frames as usize)
}

fn rock() -> EqSettings {
    EqSettings { enabled: true, gains: dsp::preset("Rock").unwrap() }
}

/// Gapless with the EQ on (Rock, both shelves up) and levelling, through `Player`: sample-exact
/// join, each side at the level the portable curve and preamp predict.
fn eq_gapless(fx: &Path, work: &Path) -> Check {
    let (a, b) = (fx.join("a.wav"), fx.join("b.wav"));
    let (fa, fb) = (wav_frames(&a)?, wav_frames(&b)?);
    let mut p = new_player(work)?;
    let flavor = p.dsp_flavor();
    ensure(flavor == dsp::Flavor::Portable, format!("flavor {flavor:?}, MPVKit has no shelves"))?;
    let mut events = p.take_events().unwrap();
    let out = work.join("eq-gapless.pcm");
    pcm(p.raw_mpv(), &out)?;
    p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
    p.set_eq(rock(), true).map_err(e2s)?;
    p.load(a.to_str().unwrap(), &HashMap::new(), Some(-3.0), None, false).map_err(e2s)?;
    p.enqueue_with_gain(b.to_str().unwrap(), Some(-9.0)).map_err(e2s)?;
    p.play().map_err(e2s)?;
    wait_for("first track end", 20.0, || matches!(events.try_recv(), Ok(PlayerEvent::TrackEnded)))?;
    let chain = p.filter_chain();
    p.set_gain(Some(-9.0)).map_err(e2s)?;
    ensure(p.filter_chain() == chain, "the advance rebuilt the chain")?;
    wait_eof(&p)?;
    let s = samples(&out)?;
    ensure(s.len() == fa + fb, format!("{} frames, want {} + {}", s.len(), fa, fb))?;
    let curve = dsp::flavor_response_db(&rock().gains, dsp::Flavor::Portable, 997.0, 48_000.0);
    let mut levels = vec![];
    for (at, g) in [(fa / 2, -3.0), (fa + fb / 2, -9.0)] {
        let st = dsp::Stage::with_flavor(Some(g), &rock(), dsp::Flavor::Portable);
        let want = TONE_DB + g + st.eq.unwrap().0 + curve;
        let got = level(&s, at, 4800);
        ensure((got - want).abs() < 0.3, format!("at {at}: {got} dB, curve says {want}"))?;
        levels.push(json!({"at": at, "got_db": got, "want_db": want}));
    }
    Ok(
        json!({"flavor": format!("{flavor:?}"), "chain": chain, "frames": s.len(), "levels": levels}),
    )
}

/// An EQ drag through `Player::set_eq(.., false)` on MPVKit: `af-command`s into the running
/// portable graph (both halves of the low shelf move), `af` unchanged, level moved as predicted.
fn eq_player_live(work: &Path) -> Check {
    let p = new_player(work)?;
    let out = work.join("eq-player-live.pcm");
    pcm(p.raw_mpv(), &out)?;
    p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
    let from = EqSettings { enabled: true, gains: [0.0, 0.0, 0.0, -1.0, 0.0, 0.0] };
    let to = EqSettings { enabled: true, gains: [6.0, 0.0, 0.0, -9.0, 0.0, 3.0] };
    p.set_eq(from, true).map_err(e2s)?;
    let tone = work.join("tone-60s.wav");
    tone_wav(&tone, 60.0)?;
    p.load(tone.to_str().unwrap(), &HashMap::new(), Some(-12.0), None, false).map_err(e2s)?;
    p.play().map_err(e2s)?;
    let size = || std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
    wait_for("1 MB of output", 10.0, || size() > 1_000_000)?;
    let built = p.filter_chain();
    let t0 = Instant::now();
    p.set_eq(to, false).map_err(e2s)?;
    let drag_us = t0.elapsed().as_micros() as u64;
    let at = size() / 4;
    ensure(p.filter_chain() == built, "a drag rebuilt the graph")?;
    wait_eof(&p)?;
    let s = samples(&out)?;
    let moved = |e: EqSettings| {
        let st = dsp::Stage::with_flavor(Some(-12.0), &e, dsp::Flavor::Portable);
        st.eq.unwrap().0 + dsp::flavor_response_db(&e.gains, dsp::Flavor::Portable, 997.0, 48_000.0)
    };
    let want = moved(from) - moved(to);
    let before = level(&s, 4800, 4800);
    let after = level(&s, s.len().saturating_sub(9600), 4800);
    ensure(((before - after) - want).abs() < 0.3, format!("{before} -> {after}, want {want} dB"))?;
    Ok(json!({"af": built, "before_db": before, "after_db": after, "want_drop_db": want,
              "command_at_frame": at, "set_eq_drag_us": drag_us}))
}

/// Loud input, no limiter on MPVKit: a full-scale 50 Hz square through boosted presets with a
/// +3 dB levelling gain comes out at or under full scale (float output, so overs are visible).
fn no_clip(work: &Path) -> Check {
    let sq = work.join("square.wav");
    wav_of(&sq, 1.0, |t| if (t * 100.0).floor() as i64 % 2 == 0 { 1.0 } else { -1.0 })?;
    let mut peaks = serde_json::Map::new();
    for name in ["Bass Booster", "Rock", "Electronic", "Loudness", "Treble Booster"] {
        let p = new_player(work)?;
        let out = work.join("loud.pcm");
        pcm(p.raw_mpv(), &out)?;
        p.raw_mpv().set_property("audio-format", "float").map_err(e2s)?;
        p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
        p.set_eq(EqSettings { enabled: true, gains: dsp::preset(name).unwrap() }, true)
            .map_err(e2s)?;
        p.load(sq.to_str().unwrap(), &HashMap::new(), Some(3.0), None, false).map_err(e2s)?;
        p.play().map_err(e2s)?;
        wait_eof(&p)?;
        let db = float_peak_db(&out)?;
        ensure(db <= 0.0 && db > -30.0, format!("{name}: peak {db:.2} dBFS"))?;
        peaks.insert(name.to_owned(), json!(db));
    }
    Ok(json!({"peak_dbfs": peaks}))
}

/// Speed on MPVKit: `Player::set_speed` falls back to mpv's scaletempo2 (no Rubber Band), and
/// a gapless join at 1.25x is (a + b) / 1.25 long with no dip at the boundary. Pitch is refused
/// and reported as unavailable, so the UI hides it.
fn speed_gapless(fx: &Path, work: &Path) -> Check {
    let (a, b) = (fx.join("a.wav"), fx.join("b.wav"));
    let (fa, fb) = (wav_frames(&a)?, wav_frames(&b)?);
    let mut p = new_player(work)?;
    let mut events = p.take_events().unwrap();
    ensure(!p.can_shift_pitch(), "MPVKit grew Rubber Band: show pitch")?;
    let pitch = p.set_pitch(2).map_err(e2s);
    ensure(pitch.is_err(), "set_pitch worked without Rubber Band")?;
    let out = work.join("speed-gapless.pcm");
    pcm(p.raw_mpv(), &out)?;
    p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
    p.set_speed(1.25).map_err(e2s)?;
    p.load(a.to_str().unwrap(), &HashMap::new(), None, None, false).map_err(e2s)?;
    p.enqueue(b.to_str().unwrap()).map_err(e2s)?;
    p.play().map_err(e2s)?;
    wait_for("first track end", 20.0, || matches!(events.try_recv(), Ok(PlayerEvent::TrackEnded)))?;
    wait_eof(&p)?;
    let s = samples(&out)?;
    let want = ((fa + fb) as f64 / 1.25).round() as usize;
    ensure(s.len().abs_diff(want) <= 2, format!("{} frames, want {want}", s.len()))?;
    let dip = (960..s.len() - 1200)
        .step_by(240)
        .map(|at| level(&s, at, 240))
        .fold(f64::INFINITY, f64::min);
    ensure(dip > TONE_DB - 1.0, format!("dip to {dip} dB"))?;
    Ok(json!({"frames": s.len(), "expected": want, "min_5ms_level_db": dip,
              "pitch": pitch.err().unwrap_or_default()}))
}

/// Which filters this libmpv/FFmpeg build has. lavfi ones through `lavfi=[...]`, mpv's own by
/// name, each on a warm probe (an `af set` on a cold player only stores the string).
fn filters(fx: &Path) -> Check {
    let probe = Mpv::new().map_err(e2s)?;
    probe.set_property("ao", "null").map_err(e2s)?;
    probe.set_property("vid", "no").map_err(e2s)?;
    probe.set_property("loop-file", "inf").map_err(e2s)?;
    probe.set_property("pause", true).map_err(e2s)?;
    // Warm on the bundled WAV: `av://lavfi:` sources need libavdevice's lavfi input, which a
    // build may lack (checked separately below).
    let a = fx.join("a.wav");
    probe.command("loadfile", &[a.to_str().unwrap(), "replace"]).map_err(e2s)?;
    wait_for("probe warm", 5.0, || probe.get_property::<MpvNode>("audio-out-params").is_ok())?;
    let mut have = serde_json::Map::new();
    // Every lavfi audio filter the Encore chain could use, plus the usual suspects for EQ,
    // dynamics and tempo (stream ios-eq). `nm` on MPVKit's Libavfilter lists the same set.
    let mut specs: Vec<(String, String)> = [
        "equalizer=f=1000:t=q:w=1:g=0",
        "lowshelf=f=60",
        "highshelf=f=15000",
        "bass",
        "treble",
        "tiltshelf",
        "biquad=b0=1:b1=0:b2=0:a0=1:a1=0:a2=0",
        "lowpass",
        "highpass",
        "allpass",
        "bandpass",
        "bandreject",
        "aiir",
        "anequalizer",
        "firequalizer",
        "superequalizer",
        "afftfilt",
        "alimiter",
        "acompressor",
        "dynaudnorm",
        "speechnorm",
        "loudnorm",
        "asoftclip",
        "compand",
        "mcompand",
        "agate",
        "acrusher",
        "volume=1",
        "atempo=1.1",
        "rubberband=tempo=1.1",
        "asetrate=48000",
        "aresample=48000",
        "apad=pad_len=16",
        "arealtime",
        "aeval=exprs=val(ch)",
        "adelay=1",
        "aformat=sample_fmts=flt",
        "pan=stereo|c0=c0|c1=c1",
        "atrim=end=100",
        "areverse",
        "anull",
        "asetpts=PTS",
        "asplit",
        "amix",
        "crystalizer",
        "extrastereo",
        "stereotools",
        "headphone",
        "afir",
        "astats",
        "ebur128",
        "replaygain",
        "silenceremove",
        "afade",
        "acrossfade",
        "aecho",
        "chorus",
        "flanger",
    ]
    .iter()
    .map(|f| (format!("lavfi {}", f.split('=').next().unwrap()), format!("lavfi=[{f}]")))
    .collect();
    for f in ["scaletempo2", "scaletempo", "rubberband"] {
        specs.push((format!("mpv {f}"), f.to_owned()));
    }
    for (name, spec) in specs.iter().map(|(n, s)| (n.as_str(), s.as_str())) {
        let ok = probe.command("af", &["set", spec]).is_ok();
        have.insert(name.to_owned(), json!(ok));
    }
    // Two-input filters (the reverb room and the stretch's length reference), as graphs.
    for (name, graph) in [
        ("lavfi afir", "[in]asplit[a][b];[a][b]afir[out]"),
        ("lavfi amix", "[in]asplit[a][b];[a][b]amix=inputs=2:duration=shortest[out]"),
    ] {
        // libmpv2 joins a command into one string, so the value goes in quotes (as player.rs does).
        let spec = format!("\"lavfi=graph=%{}%{graph}\"", graph.len());
        let r = probe.command("af", &["set", &spec]);
        have.insert(name.to_owned(), json!(r.is_ok()));
        if let Err(e) = r {
            have.insert(format!("{name} error"), json!(e.to_string()));
        }
    }
    let _ = probe.command("af", &["set", ""]);
    // The lavfi *input* (`av://lavfi:sine=...`), used by the desktop EQ test as a real-time source.
    let src = Mpv::new().map_err(e2s)?;
    src.set_property("ao", "null").map_err(e2s)?;
    src.set_property("keep-open", "yes").map_err(e2s)?;
    src.command("loadfile", &["av://lavfi:sine=f=997:d=0.2", "replace"]).map_err(e2s)?;
    let lavfi_input =
        wait_for("lavfi input", 3.0, || src.get_property::<MpvNode>("audio-out-params").is_ok())
            .is_ok();
    have.insert("lavfi input device (av://lavfi:)".to_owned(), json!(lavfi_input));
    let version = probe.get_property::<String>("mpv-version").unwrap_or_default();
    let ffmpeg = probe.get_property::<String>("ffmpeg-version").unwrap_or_default();
    let missing: Vec<&str> = ["lavfi equalizer", "lavfi volume", "mpv scaletempo2"]
        .into_iter()
        .filter(|need| have[*need] != json!(true))
        .collect();
    let report =
        json!({"mpv": version, "ffmpeg": ffmpeg, "filters": have, "missing_required": missing});
    ensure(missing.is_empty(), report.to_string())?;
    Ok(report)
}

/// Every option `crates/player`'s `new_mpv` sets, on a bare mpv: which ones this build refuses.
fn options() -> Check {
    let mpv = Mpv::new().map_err(e2s)?;
    let mut refused = serde_json::Map::new();
    for (k, v) in [
        ("vid", "no"),
        ("vo", "libmpv"),
        ("hwdec", "auto-safe"),
        ("video-timing-offset", "0"),
        ("osd-level", "0"),
        ("osd-bar", "no"),
        ("ytdl", "no"),
        ("audio-client-name", "Limusic"),
        ("title", "Limusic"),
        ("gapless-audio", "yes"),
        ("demuxer", "lavf"),
        ("hls-bitrate", "min"),
        ("prefetch-playlist", "yes"),
        ("cache", "yes"),
        ("cache-on-disk", "yes"),
        ("demuxer-max-bytes", "64MiB"),
        ("demuxer-max-back-bytes", "64MiB"),
        ("cache-pause-wait", "0.3"),
        ("stream-lavf-o", "reconnect=1"),
        ("keep-open", "yes"),
        ("ao-pcm-file", "/dev/null"),
        ("ao-null-untimed", "no"),
        ("volume-gain", "0"),
    ] {
        if let Err(e) = mpv.set_property(k, v) {
            refused.insert(k.to_owned(), json!(e.to_string()));
        }
    }
    let ao = mpv.get_property::<String>("ao").unwrap_or_default();
    Ok(json!({"refused": refused, "ao_default": ao}))
}

/// Speed and pitch. The player's path (Rubber Band) is recorded as found, not asserted: MPVKit
/// ships without librubberband. What is asserted is the fallback a later player change would
/// use for speed alone: mpv's `scaletempo2` at 1.25x, length input / speed.
fn speed_pitch(fx: &Path, work: &Path) -> Check {
    let a = fx.join("a.wav");
    let frames = wav_frames(&a)?;
    let p = new_player(work)?;
    let player_speed = p.set_speed(1.25).map_err(e2s);
    let player_pitch = p.set_pitch(2).map_err(e2s);
    drop(p);
    let p = new_player(work)?;
    let out = work.join("speed.pcm");
    pcm(p.raw_mpv(), &out)?;
    p.raw_mpv().set_property("keep-open", true).map_err(e2s)?;
    p.raw_mpv().set_property("af", "scaletempo2").map_err(e2s)?;
    p.raw_mpv().set_property("speed", 1.25).map_err(e2s)?;
    p.raw_mpv().command("loadfile", &[a.to_str().unwrap(), "replace"]).map_err(e2s)?;
    p.play().map_err(e2s)?;
    wait_eof(&p)?;
    let got = std::fs::metadata(&out).map_err(e2s)?.len() as usize / 4;
    let want = (frames as f64 / 1.25).round() as usize;
    let s = samples(&out)?;
    let mid = level(&s, s.len() / 2, 4800);
    ensure(
        got.abs_diff(want) < 2400,
        format!("scaletempo2 1.25x wrote {got} frames, want ~{want}"),
    )?;
    ensure((mid - TONE_DB).abs() < 1.0, format!("scaletempo2 output level {mid}"))?;
    let show = |r: Result<(), String>| match r {
        Ok(()) => "ok".to_owned(),
        Err(e) => format!("error: {e}"),
    };
    Ok(json!({
        "player_set_speed_1_25": show(player_speed), "player_set_pitch_2": show(player_pitch),
        "scaletempo2_frames": got, "scaletempo2_expected": want, "scaletempo2_level_db": mid,
    }))
}

/// A real googlevideo stream (Opus/WebM 251 from the VISIONOS client), decoded untimed to a
/// file until 20 s of audio is out.
fn url_stream(url: &str, work: &Path) -> Check {
    let mut p = new_player(work)?;
    let mut events = p.take_events().unwrap();
    let out = work.join("url.pcm");
    pcm(p.raw_mpv(), &out)?;
    let t0 = Instant::now();
    p.load(url, &HashMap::new(), None, None, false).map_err(e2s)?;
    p.play().map_err(e2s)?;
    let mut failed = None;
    let res = wait_for("20 s of stream audio", 60.0, || {
        while let Ok(e) = events.try_recv() {
            if let PlayerEvent::TrackFailed(m) | PlayerEvent::Error(m) = e {
                failed = Some(m);
            }
        }
        failed.is_some() || p.raw_mpv().get_property::<f64>("time-pos").unwrap_or(0.0) > 20.0
    });
    if let Some(m) = failed {
        return Err(format!("track failed: {m}"));
    }
    res?;
    let elapsed = t0.elapsed().as_secs_f64();
    let mpv = p.raw_mpv();
    let codec = mpv.get_property::<String>("audio-codec-name").unwrap_or_default();
    let format = mpv.get_property::<String>("file-format").unwrap_or_default();
    let duration = mpv.get_property::<f64>("duration").unwrap_or(0.0);
    let pos = mpv.get_property::<f64>("time-pos").unwrap_or(0.0);
    p.stop().map_err(e2s)?;
    wait_for("unload", 5.0, || p.raw_mpv().get_property::<String>("path").is_err())?;
    let frames = std::fs::metadata(&out).map_err(e2s)?.len() as usize / 4;
    ensure(frames as f64 >= 19.0 * RATE as f64, format!("only {frames} frames written"))?;
    Ok(json!({
        "codec": codec, "format": format, "duration": duration, "position": pos,
        "frames": frames, "seconds_to_decode_20s": elapsed,
    }))
}

fn run(name: &str, f: impl FnOnce() -> Check) -> Value {
    let t0 = Instant::now();
    let r = catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|p| {
        Err(format!(
            "panic: {}",
            p.downcast_ref::<String>()
                .cloned()
                .or(p.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default()
        ))
    });
    let ms = t0.elapsed().as_millis() as u64;
    match r {
        Ok(detail) => json!({"name": name, "pass": true, "ms": ms, "detail": detail}),
        Err(e) => json!({"name": name, "pass": false, "ms": ms, "error": e}),
    }
}

unsafe fn opt_str(p: *const c_char) -> Option<String> {
    if p.is_null() {
        None
    } else {
        Some(CStr::from_ptr(p).to_string_lossy().into_owned()).filter(|s| !s.is_empty())
    }
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// # Safety
/// Pointers are NUL-terminated strings or null (`url`).
#[no_mangle]
pub unsafe extern "C" fn spike_selftest(
    fixtures: *const c_char,
    work: *const c_char,
    url: *const c_char,
) -> *mut c_char {
    let fx = PathBuf::from(opt_str(fixtures).unwrap_or_default());
    let work = PathBuf::from(opt_str(work).unwrap_or_default());
    let url = opt_str(url);
    let _ = std::fs::create_dir_all(&work);
    let mut results = vec![
        run("options", options),
        run("wav_plays", || wav_plays(&fx, &work)),
        run("gapless", || gapless(&fx, &work)),
        run("eq_live_af_command", || eq_live(&work)),
        run("eq_player_chain", || eq_player(&fx, &work)),
        run("eq_gapless_portable", || eq_gapless(&fx, &work)),
        run("eq_player_live_drag", || eq_player_live(&work)),
        run("no_clip_loud", || no_clip(&work)),
        run("speed_scaletempo2_gapless", || speed_gapless(&fx, &work)),
        run("filters", || filters(&fx)),
        run("speed_pitch", || speed_pitch(&fx, &work)),
    ];
    results.push(match &url {
        Some(u) => run("url_stream", || url_stream(u, &work)),
        None => json!({"name": "url_stream", "pass": false, "error": "no URL given"}),
    });
    let all = results.iter().all(|r| r["pass"] == json!(true));
    into_c(json!({"all_pass": all, "results": results}).to_string())
}

static LIVE: Mutex<Option<Player>> = Mutex::new(None);

/// # Safety
/// Pointers are NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn spike_live_start(
    src: *const c_char,
    ao: *const c_char,
    cache: *const c_char,
    volume: i64,
) -> bool {
    let (Some(src), Some(ao), Some(cache)) = (opt_str(src), opt_str(ao), opt_str(cache)) else {
        return false;
    };
    let start = || -> Result<Player, String> {
        let _ = std::fs::create_dir_all(&cache);
        let p = Player::new(&cache).map_err(e2s)?;
        let mpv = p.raw_mpv();
        mpv.set_property("ao", ao.as_str()).map_err(e2s)?;
        if ao == "null" {
            mpv.set_property("ao-null-untimed", false).map_err(e2s)?;
        }
        mpv.set_property("volume", volume as f64).map_err(e2s)?;
        let local = !src.contains("://");
        p.set_loop_file(local).map_err(e2s)?;
        p.load(&src, &HashMap::new(), None, None, false).map_err(e2s)?;
        p.play().map_err(e2s)?;
        Ok(p)
    };
    match start() {
        Ok(p) => {
            *LIVE.lock().unwrap() = Some(p);
            true
        }
        Err(e) => {
            eprintln!("spike_live_start: {e}");
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn spike_live_position() -> f64 {
    LIVE.lock().unwrap().as_ref().and_then(|p| p.clock()).unwrap_or(-1.0)
}

#[no_mangle]
pub extern "C" fn spike_live_ao() -> *mut c_char {
    let ao = LIVE
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|p| p.raw_mpv().get_property::<String>("current-ao").ok())
        .unwrap_or_default();
    into_c(ao)
}

#[no_mangle]
pub extern "C" fn spike_live_stop() {
    if let Some(p) = LIVE.lock().unwrap().take() {
        let _ = p.stop();
    }
}

/// # Safety
/// `s` came from this library, once.
#[no_mangle]
pub unsafe extern "C" fn spike_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
