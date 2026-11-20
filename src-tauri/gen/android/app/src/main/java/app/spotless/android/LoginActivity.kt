package app.spotless.android

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * Google / YouTube Music sign-in. The desktop opens a second webview window for this
 * (src-tauri/src/session.rs); an Android app has one webview per activity, so it gets an activity
 * of its own. Android keeps one cookie store per app, so the Rust side reads the YouTube cookies
 * straight from [CookieManager] (LoginPlugin.jar) while this is open, and signs in once they hold
 * a session, exactly like the desktop's capture loop.
 */
class LoginActivity : Activity() {
  private lateinit var web: WebView
  private var handedOff = false

  @SuppressLint("SetJavaScriptEnabled")
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    current = this
    open = true
    web = WebView(this)
    setContentView(web)
    CookieManager.getInstance().setAcceptCookie(true)
    CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
    web.settings.javaScriptEnabled = true
    web.settings.domStorageEnabled = true
    // Google refuses sign-in from anything that calls itself an embedded WebView ("; wv").
    web.settings.userAgentString = web.settings.userAgentString.replace("; wv", "")
    web.webViewClient = object : WebViewClient() {
      override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) = Native.onLoginNudge()
      override fun onPageFinished(view: WebView, url: String) {
        CookieManager.getInstance().flush()
        handOffIfNeeded(view, url)
        Native.onLoginNudge()
      }
    }
    web.loadUrl(intent.getStringExtra(EXTRA_URL) ?: return finish())
  }

  /**
   * Signed in to Google but landed on YouTube Music signed out: go through YouTube's own hand-off
   * once, so the user never has to press YTM's "Sign in" as well (session.rs, needs_youtube_handoff).
   */
  private fun handOffIfNeeded(view: WebView, url: String) {
    if (handedOff || !url.startsWith("https://music.youtube.com")) return
    val cm = CookieManager.getInstance()
    val youtube = cm.getCookie("https://music.youtube.com") ?: ""
    val google = cm.getCookie("https://accounts.google.com") ?: ""
    if (!youtube.contains("SAPISID=") && Regex("(^|; )SID=").containsMatchIn(google)) {
      handedOff = true
      view.loadUrl(HANDOFF_URL)
    }
  }

  override fun onDestroy() {
    if (current === this) {
      current = null
      open = false
      Native.onLoginNudge()
    }
    web.destroy()
    super.onDestroy()
  }

  companion object {
    const val EXTRA_URL = "url"
    private const val HANDOFF_URL =
      "https://www.youtube.com/signin?action_handle_signin=true&app=desktop&next=https%3A%2F%2Fmusic.youtube.com%2F"

    @Volatile var open = false
    @Volatile var current: LoginActivity? = null
  }
}
