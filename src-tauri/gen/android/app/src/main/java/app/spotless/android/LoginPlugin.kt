package app.spotless.android

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin

@InvokeArg
class LoginArgs {
  var url: String = ""
  var clear: Boolean = false
}

/** Rust → Android half of the YouTube Music sign-in (src-tauri/src/mobile/session.rs). */
@TauriPlugin
class LoginPlugin(private val activity: Activity) : Plugin(activity) {
  private val main = Handler(Looper.getMainLooper())
  private var refresher: WebView? = null

  /** Open the sign-in screen; `clear` first signs the webview out of Google (Add account). */
  @Command
  fun open(invoke: Invoke) {
    val a = invoke.parseArgs(LoginArgs::class.java)
    main.post {
      val start = {
        LoginActivity.open = true
        activity.startActivity(Intent(activity, LoginActivity::class.java).putExtra(LoginActivity.EXTRA_URL, a.url))
        invoke.resolve()
      }
      if (a.clear) CookieManager.getInstance().removeAllCookies { start() } else start()
    }
  }

  @Command
  fun close(invoke: Invoke) {
    main.post {
      LoginActivity.current?.finish()
      invoke.resolve()
    }
  }

  /** `{ open, jar }`: whether the sign-in screen is up, and the youtube.com Cookie header. */
  @Command
  fun jar(invoke: Invoke) {
    val r = JSObject()
    r.put("open", LoginActivity.open)
    r.put("jar", CookieManager.getInstance().getCookie("https://music.youtube.com") ?: "")
    invoke.resolve(r)
  }

  /**
   * Load YouTube Music off screen, so Google rotates the session cookies the way opening the site
   * in a browser does (session.rs refresh_session). Resolves once the page has loaded.
   */
  @SuppressLint("SetJavaScriptEnabled")
  @Command
  fun refresh(invoke: Invoke) {
    val a = invoke.parseArgs(LoginArgs::class.java)
    main.post {
      refresher?.destroy()
      val w = WebView(activity)
      refresher = w
      w.settings.javaScriptEnabled = true
      w.settings.domStorageEnabled = true
      w.settings.userAgentString = w.settings.userAgentString.replace("; wv", "")
      var done = false
      w.webViewClient = object : WebViewClient() {
        override fun onPageFinished(view: WebView, url: String) {
          if (!done && url.startsWith("https://music.youtube.com")) {
            done = true
            CookieManager.getInstance().flush()
            invoke.resolve()
          }
        }
      }
      w.loadUrl(a.url)
    }
  }

  @Command
  fun endRefresh(invoke: Invoke) {
    main.post {
      refresher?.destroy()
      refresher = null
      invoke.resolve()
    }
  }
}
