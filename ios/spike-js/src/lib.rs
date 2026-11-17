//! S3 spike: run YouTube's `player.js` sig/n cipher in an in-process JS engine.
//!
//! The desktop runs it in a hidden Tauri webview (`src-tauri/src/cipher`, `webview.rs`). On iOS a
//! WKWebView's JS lives in a separate WebContent process that the OS suspends in the background,
//! exactly when the orchestrator resolves the next track. So the cipher needs an engine that lives
//! in our own process. Two candidates:
//!
//! - [`jsc::Jsc`]: JavaScriptCore via its C API. System framework on iOS and macOS, zero size.
//! - [`quickjs::Quick`]: QuickJS via `rquickjs`. Portable (Linux/Windows/Android too), ~1 MB.
//!
//! Both sit behind [`JsEngine`], the trait the core's cipher would take instead of `Bridge`.
//! The injection and discovery code are copies of the desktop's (`cipher/extractor.rs`,
//! `cipher/mod.rs::DISCOVERY_JS`) so the spike validates exactly what ships.

#[cfg(feature = "jsc")]
pub mod jsc;
#[cfg(feature = "quickjs")]
pub mod quickjs;

/// The single capability the cipher needs from a JS engine: evaluate a script in one persistent
/// global scope and hand back the completion value as a string.
pub trait JsEngine {
    fn name(&self) -> &'static str;
    fn eval(&mut self, src: &str) -> Result<String, String>;
}

impl JsEngine for Box<dyn JsEngine> {
    fn name(&self) -> &'static str {
        (**self).name()
    }
    fn eval(&mut self, src: &str) -> Result<String, String> {
        (**self).eval(src)
    }
}

/// What the desktop harness document provides (`webview::HARNESS_HTML`) plus the browser globals
/// `player.js` touches while its IIFE runs. Only module-load-time accesses matter: the sig/n code
/// paths themselves are pure string work. Kept deliberately small; `prelude.js` says which stubs
/// were measured as required (docs/streams/ios-js.md).
pub const PRELUDE_JS: &str = include_str!("prelude.js");

/// Verbatim copy of `src-tauri/src/cipher/mod.rs::DISCOVERY_JS`.
pub const DISCOVERY_JS: &str = r#"(function(){
  var t="grut12Abc_-";
  function ok(s){return typeof s==='string'&&/^[A-Za-z0-9_-]+$/.test(s)&&s!==t;}
  window.__n_ok=false;
  window.__sig_ok=false;
  try{window.__n_ok=(typeof window._nTransformFunc==='function'&&ok(window._nTransformFunc(t)));}catch(e){}
  try{window.__sig_ok=(typeof window._cipherSigFunc==='function'&&typeof window._cipherSigFunc(t)==='string');}catch(e){}
  window.__cipher_loaded=true;
})();"#;

pub const IIFE_TAIL: &str = "})(_yt_player);";

/// One registry entry (see `src-tauri/src/cipher/config.rs`).
#[derive(Debug, Clone)]
pub struct PlayerConfig {
    pub sts: Option<i32>,
    pub sig_expr: String,
    pub n_class: String,
}

/// Verbatim logic of `src-tauri/src/cipher/extractor.rs::build_injection`.
pub fn build_injection(player_js: &str, cfg: Option<&PlayerConfig>) -> String {
    let mut exports = String::from(";");
    if let Some(cfg) = cfg {
        let sig_call = cfg.sig_expr.replace("INPUT", "s");
        exports.push_str(&format!(
            "try{{window._cipherSigFunc=function(s){{\
               try{{return {sig_call};}}catch(e){{return null;}}}};}}catch(e){{}}"
        ));
        let n_class = &cfg.n_class;
        exports.push_str(&format!(
            "try{{window._nTransformFunc=function(n){{try{{\
               var u=new g.{n_class}('https://x.googlevideo.com/videoplayback?n='+n,true);\
               var t=u.get('n');return(t&&t!==n)?t:n;\
             }}catch(e){{return n;}}}};}}catch(e){{}}"
        ));
    }
    exports.push_str(IIFE_TAIL);
    match player_js.rfind(IIFE_TAIL) {
        Some(idx) => {
            let mut out = String::with_capacity(player_js.len() + exports.len());
            out.push_str(&player_js[..idx]);
            out.push_str(&exports);
            out.push_str(&player_js[idx + IIFE_TAIL.len()..]);
            out
        }
        None => format!("{player_js}\n{exports}"),
    }
}

pub fn js_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

/// A loaded cipher: an engine that has evaluated prelude + injected player + discovery.
pub struct Cipher<E: JsEngine> {
    pub engine: E,
    pub sig_ok: bool,
    pub n_ok: bool,
}

impl<E: JsEngine> Cipher<E> {
    pub fn load(mut engine: E, injected: &str) -> Result<Self, String> {
        // SPIKE_PRELUDE=<file> swaps the prelude, to measure which stubs are actually needed.
        let prelude = std::env::var("SPIKE_PRELUDE")
            .ok()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_else(|| PRELUDE_JS.to_owned());
        engine.eval(&prelude).map_err(|e| format!("prelude: {e}"))?;
        engine.eval(injected).map_err(|e| format!("player.js: {e}"))?;
        engine.eval(DISCOVERY_JS).map_err(|e| format!("discovery: {e}"))?;
        let sig_ok = engine.eval("window.__sig_ok?'1':'0'")? == "1";
        let n_ok = engine.eval("window.__n_ok?'1':'0'")? == "1";
        Ok(Cipher { engine, sig_ok, n_ok })
    }

    /// Same JS the desktop sends through `Bridge::eval_json` (`try_deobfuscate`).
    pub fn sig(&mut self, s: &str) -> Option<String> {
        let js = format!(
            "(function(){{try{{return String(window._cipherSigFunc({}));}}catch(e){{return null;}}}})()",
            js_string(s)
        );
        self.engine.eval(&js).ok().filter(|v| !v.is_empty() && v != "null")
    }

    /// Same JS as the desktop's `try_transform_n`.
    pub fn n(&mut self, n: &str) -> Option<String> {
        let js = format!(
            "(function(){{try{{return String(window._nTransformFunc({}));}}catch(e){{return null;}}}})()",
            js_string(n)
        );
        self.engine.eval(&js).ok().filter(|v| !v.is_empty() && v != "null" && v != n)
    }
}
