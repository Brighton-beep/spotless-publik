//! S3 spike driver: today's player.js + registry config → injected script → JSC and QuickJS.
//!
//!   cargo run --release --bin cipher_bench -- <out_dir> [videos]
//!
//! 1. Cold load (fresh context + prelude + 2.9 MB player.js + discovery) per engine, 5 runs each.
//! 2. ~20 real `/player` responses from a cipher client, sig + n solved in both engines; the two
//!    must agree, and the final URL must answer a Range GET with 200/206 (controls: the same URL
//!    without the n transform, and the raw URL without a signature).
//! 3. Writes `<out_dir>/injected.js` and `<out_dir>/results.json` for the WKWebView reference
//!    (`ios/spike-js/webview_ref/main.swift`), which reproduces the desktop webview path.
//!
//! Env: `SPIKE_ENGINES=jsc,quickjs` (default both), `SPIKE_CLIENTS=TVHTML5,WEB_REMIX,...`,
//! `SPIKE_LOADS=5` (cold loads per engine), `SPIKE_PRELUDE=<file>` (swap the DOM stubs).

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use innertube::{find_format, AudioQuality, Clients, InnerTube, Session};
use serde::Serialize;
use spike_js::{build_injection, Cipher, JsEngine, PlayerConfig};

const WEB_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const REGISTRY_URLS: [&str; 2] = [
    "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json",
    "https://raw.githubusercontent.com/MetrolistGroup/faraday/master/registry/player_configs.json",
];

/// Popular, long-lived music videos (official uploads), plus a few topic-channel tracks.
const VIDEOS: [&str; 24] = [
    "dQw4w9WgXcQ", "kJQP7kiw5Fk", "9bZkp7q19f0", "JGwWNGJdvx8", "RgKAFK5djSk", "OPf0YbXqDm0",
    "fJ9rUzIMcZQ", "hT_nvWreIhg", "CevxZvSJLk8", "YQHsXMglC9A", "60ItHLz5WEA", "pRpeEdMmmQ0",
    "nfWlot6h_JM", "2Vv-BfVoq4g", "uelHwf8o7_U", "09R8_2nJtjg", "lp-EO5I60KA", "e-ORhEE9VVg",
    "SlPhMPnQ58k", "ru0K8uYEZWw", "4NRXx6U8ABQ", "450p7goxZqg", "kXYiU_JCYtU", "hTWKbfoikeg",
];

#[derive(Serialize, Default, Clone)]
struct Row {
    video: String,
    client: String,
    itag: i32,
    ciphered: bool,
    s: Option<String>,
    n: Option<String>,
    jsc_sig: Option<String>,
    jsc_n: Option<String>,
    qjs_sig: Option<String>,
    qjs_n: Option<String>,
    engines_agree: bool,
    status_full: u16,
    status_no_n: u16,
    status_raw: u16,
    url: String,
}

#[derive(Serialize)]
struct Bench {
    engine: String,
    load_ms: Vec<f64>,
    sig_ok: bool,
    n_ok: bool,
    sig_call_us: Vec<f64>,
    n_call_us: Vec<f64>,
}

#[derive(Serialize)]
struct Out {
    player_hash: String,
    player_bytes: usize,
    sts: Option<i32>,
    sig_expr: String,
    n_class: String,
    benches: Vec<Bench>,
    rows: Vec<Row>,
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn engines() -> Vec<String> {
    std::env::var("SPIKE_ENGINES")
        .unwrap_or_else(|_| "jsc,quickjs".into())
        .split(',')
        .map(str::to_owned)
        .collect()
}

fn new_engine(name: &str) -> Box<dyn JsEngine> {
    match name {
        #[cfg(feature = "jsc")]
        "jsc" => Box::new(spike_js::jsc::Jsc::new()),
        #[cfg(feature = "quickjs")]
        "quickjs" => Box::new(spike_js::quickjs::Quick::new()),
        other => panic!("unknown engine {other}"),
    }
}

async fn get_text(http: &reqwest::Client, url: &str) -> String {
    http.get(url).header("User-Agent", WEB_UA).send().await.unwrap().error_for_status().unwrap().text().await.unwrap()
}

async fn load_config(http: &reqwest::Client, hash: &str) -> Option<PlayerConfig> {
    let mut found = None;
    for url in REGISTRY_URLS {
        let Ok(r) = http.get(url).send().await else { continue };
        let Ok(v) = r.json::<serde_json::Value>().await else { continue };
        let Some(players) = v.get("players").and_then(|p| p.as_object()) else { continue };
        for (h, e) in players {
            let aliases: Vec<&str> = e
                .get("aliases")
                .and_then(|a| a.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_str()).collect())
                .unwrap_or_default();
            if h == hash || aliases.contains(&hash) {
                found = Some(PlayerConfig {
                    sts: e.get("sts").and_then(|s| s.as_i64()).map(|s| s as i32),
                    sig_expr: e["sig"].as_str()?.to_owned(),
                    n_class: e["nClass"].as_str()?.to_owned(),
                });
            }
        }
    }
    found
}

fn parse_cipher(cipher: &str) -> Option<(String, String, String)> {
    let mut s = None;
    let mut sp = None;
    let mut url = None;
    for pair in cipher.split('&') {
        let (k, v) = pair.split_once('=')?;
        let v = urlencoding::decode(v).ok()?.into_owned();
        match k {
            "s" => s = Some(v),
            "sp" => sp = Some(v),
            "url" => url = Some(v),
            _ => {}
        }
    }
    Some((s?, sp.unwrap_or_else(|| "signature".into()), url?))
}

fn n_span(url: &str) -> Option<(usize, usize)> {
    let re = regex::Regex::new(r"[?&]n=([^&]+)|/n/([^/]+)/").ok()?;
    let c = re.captures(url)?;
    let m = c.get(1).or_else(|| c.get(2))?;
    Some((m.start(), m.end()))
}

async fn range_status(http: &reqwest::Client, url: &str, ua: &str) -> u16 {
    match http.get(url).header("Range", "bytes=0-4095").header("User-Agent", ua).send().await {
        Ok(r) => r.status().as_u16(),
        Err(_) => 0,
    }
}

#[tokio::main]
async fn main() {
    let out_dir = PathBuf::from(std::env::args().nth(1).expect("usage: cipher_bench <out_dir> [videos]"));
    let n_videos: usize = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(20);
    std::fs::create_dir_all(&out_dir).unwrap();
    let http = reqwest::Client::builder().timeout(Duration::from_secs(20)).build().unwrap();

    // --- player.js, exactly as fetcher.rs does it -------------------------------------------
    let iframe = get_text(&http, "https://www.youtube.com/iframe_api").await;
    let hash = regex::Regex::new(r"player\\?/([0-9A-Za-z_-]+)\\?/")
        .unwrap()
        .captures(&iframe)
        .unwrap()[1]
        .to_owned();
    let cache = out_dir.join(format!("player_{hash}.js"));
    let player_js = match std::fs::read_to_string(&cache) {
        Ok(js) => js,
        Err(_) => {
            let js = get_text(
                &http,
                &format!("https://www.youtube.com/s/player/{hash}/player_ias.vflset/en_GB/base.js"),
            )
            .await;
            std::fs::write(&cache, &js).unwrap();
            js
        }
    };
    let cfg = load_config(&http, &hash).await.expect("registries have no config for today's player");
    let sts = cfg.sts.or_else(|| {
        regex::Regex::new(r#"(?:signatureTimestamp|sts)"?\s*[:=]\s*(\d{4,})"#)
            .unwrap()
            .captures(&player_js)
            .and_then(|c| c[1].parse().ok())
    });
    eprintln!("player {hash} ({} bytes) sts={sts:?} sig={} nClass={}", player_js.len(), cfg.sig_expr, cfg.n_class);
    let injected = build_injection(&player_js, Some(&cfg));
    std::fs::write(out_dir.join("injected.js"), &injected).unwrap();

    // --- cold loads ----------------------------------------------------------------------------
    let mut benches = Vec::new();
    let mut ciphers: HashMap<String, Cipher<Box<dyn JsEngine>>> = HashMap::new();
    for name in engines() {
        let mut load_ms = Vec::new();
        let mut last = None;
        let loads: usize = std::env::var("SPIKE_LOADS").ok().and_then(|v| v.parse().ok()).unwrap_or(5);
        for _ in 0..loads {
            let t = Instant::now();
            match Cipher::load(new_engine(&name), &injected) {
                Ok(c) => {
                    load_ms.push(ms(t.elapsed()));
                    last = Some(c);
                }
                Err(e) => {
                    eprintln!("{name}: load failed: {}", &e[..e.len().min(600)]);
                    break;
                }
            }
        }
        let (sig_ok, n_ok) = last.as_ref().map(|c| (c.sig_ok, c.n_ok)).unwrap_or_default();
        eprintln!("{name}: load {load_ms:.1?} ms  sig_ok={sig_ok} n_ok={n_ok}");
        if let Some(c) = last {
            ciphers.insert(name.clone(), c);
        }
        benches.push(Bench { engine: name, load_ms, sig_ok, n_ok, sig_call_us: vec![], n_call_us: vec![] });
    }

    // --- real streams --------------------------------------------------------------------------
    let it = InnerTube::new(Session::default(), None).unwrap();
    let vd = it.fetch_visitor_data().await.ok();
    let it = InnerTube::new(Session { visitor_data: vd, ..Session::default() }, None).unwrap();
    let clients = Clients::bundled();
    let client_keys: Vec<String> = std::env::var("SPIKE_CLIENTS")
        .unwrap_or_else(|_| "TVHTML5,WEB_REMIX,TVHTML5_SIMPLY,WEB".into())
        .split(',')
        .map(str::to_owned)
        .collect();

    let mut rows = Vec::new();
    for vid in VIDEOS {
        if rows.len() >= n_videos {
            break;
        }
        let mut picked = None;
        for key in &client_keys {
            let client = clients.get(key).unwrap();
            let Ok(resp) = it.player(client, vid, None, sts, None).await else { continue };
            if !resp.playability_status.is_ok() {
                eprintln!("  {vid} {key}: {:?}", resp.playability_status.status);
                continue;
            }
            let Some(sd) = resp.streaming_data.as_ref() else { continue };
            let Some(f) = find_format(sd, AudioQuality::High) else { continue };
            picked = Some((key.clone(), client.user_agent.clone(), f.itag, f.cipher_string().map(str::to_owned), f.url.clone()));
            break;
        }
        let Some((key, ua, itag, cipher, url)) = picked else {
            eprintln!("  {vid}: no client answered");
            continue;
        };
        let mut row = Row { video: vid.into(), client: key, itag, ciphered: cipher.is_some(), ..Row::default() };
        let (base, s, sp) = match &cipher {
            Some(c) => {
                let (s, sp, base) = parse_cipher(c).unwrap();
                (base, Some(s), sp)
            }
            None => (url.clone().unwrap_or_default(), None, String::new()),
        };
        row.s = s.clone();
        row.n = n_span(&base).map(|(a, b)| urlencoding::decode(&base[a..b]).unwrap().into_owned());

        let mut finals: HashMap<String, String> = HashMap::new();
        for (name, c) in ciphers.iter_mut() {
            let bench = benches.iter_mut().find(|b| &b.engine == name).unwrap();
            let mut u = base.clone();
            let mut sig_out = None;
            if let Some(s) = &s {
                let t = Instant::now();
                sig_out = c.sig(s);
                bench.sig_call_us.push(t.elapsed().as_secs_f64() * 1e6);
                if let Some(sig) = &sig_out {
                    let sep = if u.contains('?') { '&' } else { '?' };
                    u = format!("{u}{sep}{sp}={}", urlencoding::encode(sig));
                }
            }
            let mut n_out = None;
            if let Some(n) = &row.n {
                let t = Instant::now();
                n_out = c.n(n);
                bench.n_call_us.push(t.elapsed().as_secs_f64() * 1e6);
                if let (Some(newn), Some((a, b))) = (&n_out, n_span(&u)) {
                    u = format!("{}{}{}", &u[..a], urlencoding::encode(newn), &u[b..]);
                }
            }
            match name.as_str() {
                "jsc" => (row.jsc_sig, row.jsc_n) = (sig_out, n_out),
                _ => (row.qjs_sig, row.qjs_n) = (sig_out, n_out),
            }
            finals.insert(name.clone(), u);
        }
        let mut vals = finals.values();
        let first = vals.next().cloned().unwrap_or_default();
        row.engines_agree = vals.all(|v| *v == first);
        row.url = first.clone();
        row.status_full = range_status(&http, &first, &ua).await;
        // Controls: sig applied but n left alone; and no signature at all.
        let mut no_n = base.clone();
        if let (Some(_), Some(sig)) = (&s, row.jsc_sig.as_ref().or(row.qjs_sig.as_ref())) {
            let sep = if no_n.contains('?') { '&' } else { '?' };
            no_n = format!("{no_n}{sep}{sp}={}", urlencoding::encode(sig));
        }
        row.status_no_n = range_status(&http, &no_n, &ua).await;
        row.status_raw = if s.is_some() { range_status(&http, &base, &ua).await } else { 0 };
        eprintln!(
            "  {vid} {} itag {} ciphered={} agree={} full={} no_n={} raw={}",
            row.client, row.itag, row.ciphered, row.engines_agree, row.status_full, row.status_no_n, row.status_raw
        );
        rows.push(row);
    }

    for b in &benches {
        let avg = |v: &Vec<f64>| if v.is_empty() { 0.0 } else { v.iter().sum::<f64>() / v.len() as f64 };
        eprintln!(
            "{}: load cold {:.0} ms / later {:.0} ms; sig call avg {:.0} µs (first {:.0}); n call avg {:.0} µs (first {:.0})",
            b.engine,
            b.load_ms.first().copied().unwrap_or(0.0),
            avg(&b.load_ms[1.min(b.load_ms.len())..].to_vec()),
            avg(&b.sig_call_us),
            b.sig_call_us.first().copied().unwrap_or(0.0),
            avg(&b.n_call_us),
            b.n_call_us.first().copied().unwrap_or(0.0),
        );
    }
    let ok = rows.iter().filter(|r| matches!(r.status_full, 200 | 206)).count();
    eprintln!("playable: {ok}/{} ; engines agree on {}/{}", rows.len(), rows.iter().filter(|r| r.engines_agree).count(), rows.len());

    let out = Out {
        player_hash: hash,
        player_bytes: player_js.len(),
        sts,
        sig_expr: cfg.sig_expr,
        n_class: cfg.n_class,
        benches,
        rows,
    };
    std::fs::write(out_dir.join("results.json"), serde_json::to_string_pretty(&out).unwrap()).unwrap();
}
