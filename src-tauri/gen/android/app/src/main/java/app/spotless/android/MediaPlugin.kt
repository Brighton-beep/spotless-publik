package app.spotless.android

import android.app.Activity
import android.content.Intent
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.Plugin

@InvokeArg
class MediaState {
  var title: String = ""
  var artist: String = ""
  var album: String? = null
  var cover: String? = null
  var durationMs: Long = -1
  var positionMs: Long = 0
  var playing: Boolean = false
}

/** Rust → Android half of the media controls (src-tauri/src/mobile/media.rs). */
@TauriPlugin
class MediaPlugin(private val activity: Activity) : Plugin(activity) {
  private var serviceStarted = false

  @Command
  fun update(invoke: Invoke) {
    val s = invoke.parseArgs(MediaState::class.java)
    activity.runOnUiThread {
      MediaSessionPlayer.shared.update(s.title, s.artist, s.album, s.cover, s.durationMs, s.positionMs, s.playing)
      // Started the first time something plays, while the app is in front (Android forbids
      // starting it from the background); Media3 makes it a foreground service while playing.
      if (s.playing && !serviceStarted) {
        activity.startService(Intent(activity, PlaybackService::class.java))
        serviceStarted = true
      }
    }
    invoke.resolve()
  }
}
