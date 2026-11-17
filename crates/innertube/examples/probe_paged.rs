//! Debug tool (stream: search2): page a filtered search live and count rows per page.
//!   cargo run -p innertube --example probe_paged -- "daft punk" songs 6 [dump-dir]
use innertube::search::{next_token, page_rows};
use innertube::{Clients, InnerTube, SearchFilter, Session, METADATA_CLIENT};

fn rows(v: &serde_json::Value) -> usize {
    fn walk(v: &serde_json::Value, n: &mut usize) {
        match v {
            serde_json::Value::Object(m) => {
                for (k, x) in m {
                    if k == "musicResponsiveListItemRenderer" { *n += 1 } else { walk(x, n) }
                }
            }
            serde_json::Value::Array(a) => a.iter().for_each(|x| walk(x, n)),
            _ => {}
        }
    }
    let mut n = 0;
    walk(page_rows(v), &mut n);
    n
}

#[tokio::main]
async fn main() {
    let mut a = std::env::args().skip(1);
    let q = a.next().expect("query");
    let f = SearchFilter::from_name(&a.next().unwrap_or("songs".into())).expect("filter");
    let pages: usize = a.next().and_then(|n| n.parse().ok()).unwrap_or(5);
    let dump = a.next();
    let it = InnerTube::new(Session::default(), None).unwrap();
    let vd = it.fetch_visitor_data().await.ok();
    let it = InnerTube::new(Session { visitor_data: vd, ..Session::default() }, None).unwrap();
    let clients = Clients::bundled();
    let c = clients.get(METADATA_CLIENT).unwrap();
    let mut tok: Option<String> = None;
    let mut total = 0;
    for p in 0..pages {
        let v = it.search_page_json(c, &q, f, tok.as_deref()).await.unwrap();
        if let Some(d) = &dump {
            std::fs::write(format!("{d}/{}_{p}.json", f.name()), serde_json::to_string(&v).unwrap()).unwrap();
        }
        let n = rows(&v);
        total += n;
        tok = next_token(&v);
        println!("page {p}: {n} rows (total {total}), next={}", tok.is_some());
        if tok.is_none() { break }
    }
}
