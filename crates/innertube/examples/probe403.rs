//! Diagnostic A/B probe for the anonymous 403 ("Sorry... automated queries") bursts.
//! Conditions are interleaved request by request, so IP "heat" from earlier runs hits all equally.
//!   PROBE_CONC=16 PROBE_N=200 PROBE_EP=search|next|browse cargo run -p innertube --example probe403
//! Conditions: h1|h2 transport × bare (sw.js_data visitorData, bundled version, no cookie) |
//! page (music.youtube.com bootstrap: its cookies, its VISITOR_DATA, its client version).
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use futures_util::StreamExt;

const YTM: &str = "https://music.youtube.com/youtubei/v1/";
const GAPI: &str = "https://youtubei.googleapis.com/youtubei/v1/";
const WWW: &str = "https://www.youtube.com/youtubei/v1/";
const WEBR: (&str, &str, &str) = ("WEB_REMIX", "67", UA);
const IOSM: (&str, &str, &str) = (
    "IOS_MUSIC",
    "26",
    "com.google.ios.youtubemusic/8.44.2 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
);
const ANDM: (&str, &str, &str) = (
    "ANDROID_MUSIC",
    "21",
    "com.google.android.apps.youtube.music/8.44.54 (Linux; U; Android 14) gzip",
);
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0";

#[derive(Clone)]
struct Cond {
    name: &'static str,
    http: reqwest::Client,
    ver: String,
    vd: Option<String>,
    cookie: Option<String>,
    base: &'static str,
    client: (&'static str, &'static str, &'static str),
}

async fn page_bootstrap(http: &reqwest::Client) -> (String, String, String) {
    let r = http.get("https://music.youtube.com/").header("user-agent", UA).send().await.unwrap();
    let cookie = r
        .headers()
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok()?.split(';').next().map(str::to_owned))
        .filter(|kv| !kv.ends_with('='))
        .collect::<Vec<_>>()
        .join("; ");
    let html = r.text().await.unwrap();
    let grab = |k: &str| {
        let pat = format!("\"{k}\":\"");
        let i = html.find(&pat).unwrap() + pat.len();
        html[i..i + html[i..].find('"').unwrap()].to_owned()
    };
    (grab("VISITOR_DATA"), grab("INNERTUBE_CLIENT_VERSION"), cookie)
}

#[tokio::main]
async fn main() {
    let env = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_owned());
    let conc: usize = env("PROBE_CONC", "16").parse().unwrap();
    let n: usize = env("PROBE_N", "200").parse().unwrap();
    let ep = env("PROBE_EP", "search");
    let only = env("PROBE_ONLY", "");
    let h1 = reqwest::Client::builder().http1_only().build().unwrap();
    let h2 = reqwest::Client::builder().build().unwrap();
    let it = innertube::InnerTube::new(Default::default(), None).unwrap();
    let short_vd = it.fetch_visitor_data().await.ok();
    let (page_vd, page_ver, cookie) = page_bootstrap(&h1).await;
    eprintln!(
        "page ver {page_ver}, vd len {}, cookies {}",
        page_vd.len(),
        cookie.split("; ").filter_map(|c| c.split('=').next()).collect::<Vec<_>>().join(",")
    );
    let old = "1.20260213.01.00".to_owned();
    let mut conds = vec![
        Cond {
            name: "h1-bare",
            http: h1.clone(),
            ver: old.clone(),
            vd: short_vd.clone(),
            cookie: None,
            base: YTM,
            client: WEBR,
        },
        Cond {
            name: "h2-bare",
            http: h2.clone(),
            ver: old.clone(),
            vd: short_vd.clone(),
            cookie: None,
            base: YTM,
            client: WEBR,
        },
        Cond {
            name: "h1-page",
            http: h1.clone(),
            ver: page_ver.clone(),
            vd: Some(page_vd.clone()),
            cookie: Some(cookie.clone()),
            base: YTM,
            client: WEBR,
        },
        Cond {
            name: "h2-page",
            http: h2.clone(),
            ver: page_ver.clone(),
            vd: Some(page_vd.clone()),
            cookie: Some(cookie.clone()),
            base: YTM,
            client: WEBR,
        },
        Cond {
            name: "h2-pagevd-nocookie",
            http: h2.clone(),
            ver: page_ver.clone(),
            vd: Some(page_vd.clone()),
            cookie: None,
            base: YTM,
            client: WEBR,
        },
        Cond {
            name: "h2-bare@gapi",
            http: h2.clone(),
            ver: old.clone(),
            vd: short_vd.clone(),
            cookie: None,
            base: GAPI,
            client: WEBR,
        },
        Cond {
            name: "h2-bare@www",
            http: h2.clone(),
            ver: old.clone(),
            vd: short_vd.clone(),
            cookie: None,
            base: WWW,
            client: WEBR,
        },
        Cond {
            name: "ios_music",
            http: h2.clone(),
            ver: "8.44.2".into(),
            vd: short_vd.clone(),
            cookie: None,
            base: YTM,
            client: IOSM,
        },
        Cond {
            name: "android_music",
            http: h2.clone(),
            ver: "8.44.54".into(),
            vd: short_vd.clone(),
            cookie: None,
            base: YTM,
            client: ANDM,
        },
    ];
    if !only.is_empty() {
        conds.retain(|c| only.split(',').any(|o| o == c.name));
    }
    let conds = Arc::new(conds);
    let hist = Arc::new(Mutex::new(BTreeMap::<(&'static str, u16), u32>::new()));
    let lat = Arc::new(Mutex::new(BTreeMap::<u16, Vec<f64>>::new()));
    let t0 = std::time::Instant::now();
    futures_util::stream::iter(0..n)
        .for_each_concurrent(conc, |i| {
            let (conds, hist, ep, lat) = (conds.clone(), hist.clone(), ep.clone(), lat.clone());
            async move {
                let c = &conds[i % conds.len()];
                let mut ctx = serde_json::json!({"client": {"clientName": c.client.0, "clientVersion": c.ver, "hl": "en", "gl": "US"}});
                if let Some(v) = &c.vd {
                    ctx["client"]["visitorData"] = v.clone().into();
                }
                let q = ["daft punk", "radiohead", "adele", "drake", "abba", "queen", "sza"][i % 7];
                let (path, body) = match ep.as_str() {
                    "next" => ("next", serde_json::json!({"context": ctx, "videoId": "fJ9rUzIMcZQ", "playlistId": "RDAMVMfJ9rUzIMcZQ", "isAudioOnly": true})),
                    "browse" => ("browse", serde_json::json!({"context": ctx, "browseId": "UCiMhD4jzUqG-IgPzUmmytRQ"})),
                    _ => ("search", serde_json::json!({"context": ctx, "query": format!("{q} {i}")})),
                };
                let mut req = c
                    .http
                    .post(format!("{}{path}?prettyPrint=false", c.base))
                    .header("content-type", "application/json")
                    .header("x-youtube-client-name", c.client.1)
                    .header("x-youtube-client-version", &c.ver)
                    .header("x-origin", "https://music.youtube.com")
                    .header("origin", "https://music.youtube.com")
                    .header("referer", "https://music.youtube.com/")
                    .header("user-agent", c.client.2)
                    .json(&body);
                if let Some(v) = &c.vd {
                    req = req.header("x-goog-visitor-id", v);
                }
                if let Some(k) = &c.cookie {
                    req = req.header("cookie", k);
                }
                let t = std::time::Instant::now();
                let s = match req.send().await {
                    Ok(r) => r.status().as_u16(),
                    Err(_) => 0,
                };
                *hist.lock().unwrap().entry((c.name, s)).or_default() += 1;
                lat.lock().unwrap().entry(s).or_default().push(t.elapsed().as_secs_f64());
            }
        })
        .await;
    eprintln!("conc={conc} ep={ep} n={n} {:.1}s", t0.elapsed().as_secs_f32());
    for c in conds.iter() {
        let h = hist.lock().unwrap();
        let ok = h.get(&(c.name, 200)).copied().unwrap_or(0);
        let all: u32 = h.iter().filter(|((n, _), _)| *n == c.name).map(|(_, v)| v).sum();
        let other: Vec<_> = h
            .iter()
            .filter(|((n, s), _)| *n == c.name && *s != 200)
            .map(|((_, s), v)| (*s, *v))
            .collect();
        eprintln!("  {:<20} {ok}/{all} ok  {other:?}", c.name);
    }
    for (s, v) in lat.lock().unwrap().iter_mut() {
        v.sort_by(f64::total_cmp);
        let q = |p: f64| v[((v.len() - 1) as f64 * p) as usize];
        eprintln!(
            "  status {s}: n {} min {:.2}s p50 {:.2}s p95 {:.2}s max {:.2}s",
            v.len(),
            q(0.0),
            q(0.5),
            q(0.95),
            q(1.0)
        );
    }
}
