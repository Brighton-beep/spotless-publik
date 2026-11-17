//! Proves whether JSC honours `JSC_useJIT=false` in this process (hot loop: JIT vs LLInt).
use spike_js::JsEngine;
fn main() {
    let mut e = spike_js::jsc::Jsc::new();
    let t = std::time::Instant::now();
    let r = e.eval("(function(){var s=0;for(var i=0;i<3e7;i++){s=(s+i*7)%1000003};return s})()").unwrap();
    println!("hot loop {r} in {:?}", t.elapsed());
}
