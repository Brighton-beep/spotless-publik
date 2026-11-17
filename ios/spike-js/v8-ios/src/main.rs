// S3 (b): rustypipe-botguard on iOS. Bootstraps the minter K times under the V8 flags in argv[1]
// (default --jitless, the only mode a device without a JIT entitlement allows), and per bootstrap
// prints init/mint timings, the integrity-token class (same arithmetic as the desktop's
// potoken/botguard.rs: pot bytes - ident - 14; <= 64 accepted) and one pot per video id.
use rustypipe_botguard::Botguard;
use std::time::Instant;

fn it_len(pot: &str, ident: &str) -> Option<usize> {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let s = pot.trim_end_matches('=');
    let mut bits = 0u32;
    let mut n = 0u32;
    let mut out = 0usize;
    for c in s.bytes() {
        let v = T.iter().position(|&x| x == c)? as u32;
        bits = (bits << 6) | v;
        n += 6;
        if n >= 8 {
            n -= 8;
            out += 1;
            bits &= (1 << n) - 1;
        }
    }
    out.checked_sub(ident.len() + 14)
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let flags = args.next().unwrap_or_else(|| "--jitless".into());
    let k: usize = args.next().and_then(|s| s.parse().ok()).unwrap_or(1);
    let vids: Vec<String> = args.collect();
    v8::V8::set_flags_from_string(&flags);
    let mut prev: Option<Botguard> = None;
    for i in 0..k {
        drop(prev.take());
        let t = Instant::now();
        let mut bg = Botguard::builder().init().await.expect("botguard init");
        let init = t.elapsed();
        let t = Instant::now();
        let probe = bg.mint_token("limusicprobe").await.expect("mint");
        let mint = t.elapsed();
        let it = it_len(&probe, "limusicprobe");
        let class = if it.is_some_and(|n| n <= 64) { "ACCEPTED" } else { "rejected" };
        let pots: Vec<String> = {
            let mut v = vec![];
            for id in &vids {
                v.push(format!("{id}={}", bg.mint_token(id).await.expect("mint")));
            }
            v
        };
        println!("boot {i} flags={flags} init={init:?} mint={mint:?} it={it:?} {class} {}", pots.join(" "));
        prev = Some(bg);
    }
}
