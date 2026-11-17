//! Debug tool (stream: search2): does a user channel (search "Profiles") parse as an artist page?
//!   cargo run -p innertube --example probe_profile -- UCuY9UGOYjCnZoaWvj7FAU-g
use innertube::{Clients, InnerTube, Session, METADATA_CLIENT};
#[tokio::main]
async fn main() {
    let id = std::env::args().nth(1).expect("channel id");
    let it = InnerTube::new(Session::default(), None).unwrap();
    let c = Clients::bundled();
    match it.artist(c.get(METADATA_CLIENT).unwrap(), &id).await {
        Ok(p) => println!("name {:?} top_songs {} carousels {:?}", p.name, p.top_songs.len(), p.sections.iter().map(|x| (&x.title, x.items.len())).collect::<Vec<_>>()),
        Err(e) => println!("error {e}"),
    }
}
