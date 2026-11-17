//! Offline check of the plumbing: a player-shaped fixture (IIFE over `_yt_player`, `var
//! window=this`, a sig function and an `n` URL class reachable only inside the closure) goes
//! through the desktop's injection + discovery in each engine. The live check against today's
//! player.js is `cargo run --release --bin cipher_bench`.
use spike_js::{build_injection, Cipher, JsEngine, PlayerConfig};

const FIXTURE: &str = r#"var _yt_player={};(function(g){var window=this;
var lk=document,Ee=window;if(!navigator)throw 1;if(!window.location.hostname)throw 2;new XMLHttpRequest;
function Ii(a,b,s){return s.split("").reverse().join("")+a+b;}
g.as=function(u,f){this.n=u.split("n=")[1];};g.as.prototype.get=function(k){return k==="n"?this.n.toUpperCase():null;};
})(_yt_player);"#;

fn check<E: JsEngine>(e: E) {
    let cfg = PlayerConfig { sts: None, sig_expr: "Ii(25,558,INPUT)".into(), n_class: "as".into() };
    let mut c = Cipher::load(e, &build_injection(FIXTURE, Some(&cfg))).expect("load");
    assert!(c.sig_ok && c.n_ok, "discovery");
    assert_eq!(c.sig("abc").as_deref(), Some("cba25558"));
    assert_eq!(c.n("xyz").as_deref(), Some("XYZ"));
}

#[cfg(feature = "jsc")]
#[test]
fn jsc_runs_the_injected_fixture() {
    check(spike_js::jsc::Jsc::new());
}

#[cfg(feature = "quickjs")]
#[test]
fn quickjs_runs_the_injected_fixture() {
    check(spike_js::quickjs::Quick::new());
}
