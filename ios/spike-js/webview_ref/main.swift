// Desktop-path reference for S3: the same injected player.js + DISCOVERY_JS in a hidden WKWebView
// over the desktop harness document (webview::HARNESS_HTML). On macOS this IS the engine Tauri's
// cipher webview uses (wry → WKWebView). Compares every sig/n the Rust engines produced.
//
//   swiftc -O main.swift -o webview_ref && ./webview_ref <out_dir>   (out_dir from cipher_bench)
import Foundation
import WebKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let injected = try! String(contentsOf: dir.appendingPathComponent("injected.js"), encoding: .utf8)
let results = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("results.json"))) as! [String: Any]
let rows = results["rows"] as! [[String: Any]]

let harness = "<!doctype html><html><head><meta charset=utf-8></head><body><script>window.__jserr=null;window.__slots={};window._yt_player=window._yt_player||{};window.__harness=1;</script></body></html>"
let discovery = """
(function(){
  var t="grut12Abc_-";
  function ok(s){return typeof s==='string'&&/^[A-Za-z0-9_-]+$/.test(s)&&s!==t;}
  window.__n_ok=false;
  window.__sig_ok=false;
  try{window.__n_ok=(typeof window._nTransformFunc==='function'&&ok(window._nTransformFunc(t)));}catch(e){}
  try{window.__sig_ok=(typeof window._cipherSigFunc==='function'&&typeof window._cipherSigFunc(t)==='string');}catch(e){}
  window.__cipher_loaded=true;
})();
"""

func jsString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
}

final class Nav: NSObject, WKNavigationDelegate {
    var done: (() -> Void)?
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?() }
}

@MainActor func run() async {
    let wv = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1))
    let nav = Nav()
    wv.navigationDelegate = nav
    await withCheckedContinuation { c in
        nav.done = { c.resume() }
        wv.loadHTMLString(harness, baseURL: URL(string: "https://localhost/"))
    }
    let t0 = Date()
    _ = try? await wv.evaluateJavaScript(injected + "\n;0")
    _ = try? await wv.evaluateJavaScript(discovery + "\n;0")
    let loadMs = Date().timeIntervalSince(t0) * 1000
    let sigOk = (try? await wv.evaluateJavaScript("window.__sig_ok===true")) as? Bool ?? false
    let nOk = (try? await wv.evaluateJavaScript("window.__n_ok===true")) as? Bool ?? false
    print(String(format: "webview: load %.0f ms sig_ok=\(sigOk) n_ok=\(nOk)", loadMs))
    var same = 0, total = 0
    for r in rows {
        total += 1
        var ok = true
        if let s = r["s"] as? String {
            let v = try? await wv.evaluateJavaScript("(function(){try{return String(window._cipherSigFunc(\(jsString(s))));}catch(e){return null;}})()") as? String
            if v != (r["jsc_sig"] as? String) || v != (r["qjs_sig"] as? String) { ok = false; print("  sig mismatch \(r["video"]!): webview=\(v ?? "nil")") }
        }
        if let n = r["n"] as? String {
            let v = try? await wv.evaluateJavaScript("(function(){try{return String(window._nTransformFunc(\(jsString(n))));}catch(e){return null;}})()") as? String
            if v != (r["jsc_n"] as? String) || v != (r["qjs_n"] as? String) { ok = false; print("  n mismatch \(r["video"]!): webview=\(v ?? "nil") jsc=\(r["jsc_n"] ?? "nil")") }
        }
        if ok { same += 1 }
    }
    print("webview agrees with jsc+quickjs on \(same)/\(total) rows")
    exit(same == total ? 0 : 1)
}

Task { @MainActor in await run() }
RunLoop.main.run()
