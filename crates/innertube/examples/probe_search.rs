//! Debug tool: dump what each search path returns for a query (live).
//!   cargo run -p innertube --example probe_search -- "daft punk" [raw-out.json]
use innertube::{Clients, InnerTube, Session, METADATA_CLIENT};

#[tokio::main]
async fn main() {
    let q = std::env::args().nth(1).expect("usage: probe_search <query>");
    let it = InnerTube::new(Session::default(), None).unwrap();
    let vd = it.fetch_visitor_data().await.ok();
    let it = InnerTube::new(Session { visitor_data: vd, ..Session::default() }, None).unwrap();
    let clients = Clients::bundled();
    let c = clients.get(METADATA_CLIENT).unwrap();
    #[cfg(feature = "integration-tests")]
    if let Some(out) = std::env::args().skip_while(|a| a != "--raw").nth(1) {
        let v = it.search_json(c, &q, None).await.unwrap();
        std::fs::write(out, serde_json::to_string_pretty(&v).unwrap()).unwrap();
        return;
    }
    if std::env::args().any(|a| a == "--artist") {
        let a = it.search_all(c, &q, false).await.unwrap();
        let id = a.top.iter().find(|t| t.kind == "artist").map(|t| t.id.clone()).unwrap();
        let page = it.artist(c, &id).await.unwrap();
        for s in &page.top_songs {
            println!("top {} {} {:?} {:?}", s.video_id, s.title, s.duration, s.play_count);
        }
        if let Some(pid) = &page.top_songs_id {
            let pl = it.playlist(c, pid, None).await.unwrap();
            for s in pl.items.iter().take(15) {
                println!("pl  {} {} {:?}", s.video_id, s.title, s.duration);
            }
        }
        return;
    }
    if std::env::args().any(|a| a == "--songs") {
        for round in 0..6 {
            let it = InnerTube::new(Session::default(), None).unwrap();
            let vd = if round % 2 == 0 { it.fetch_visitor_data().await.ok() } else { None };
            let it = InnerTube::new(Session { visitor_data: vd, ..Session::default() }, None).unwrap();
            let s = it.search_songs(c, &q, false).await.unwrap();
            let t: Vec<_> = s.items.iter().take(10).map(|i| i.title.chars().take(18).collect::<String>()).collect();
            println!("{round}: {t:?}");
        }
        return;
    }
    for round in 0..2 {
        let s = it.search_songs(c, &q, false).await.unwrap();
        println!("-- search_songs #{round}");
        for i in s.items.iter().take(8) {
            println!("  {} | {} | {:?} | {:?}", i.title, i.artists, i.duration, i.play_count);
        }
        let a = it.search_all(c, &q, false).await.unwrap();
        println!("-- search_all #{round} top={:?}", a.top.iter().map(|t| (&t.kind, &t.title)).collect::<Vec<_>>());
        for i in &a.songs {
            println!("  song {} | {:?}", i.title, i.subtitle);
        }
        for i in &a.artists {
            println!("  artist {} | {:?} | {}", i.title, i.subtitle, i.id);
        }
    }
}
