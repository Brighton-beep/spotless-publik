package app.spotless.android

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Keeps playback alive with the app in the background or the screen off (a foreground service of
 * type mediaPlayback) and owns the MediaSession behind the lock screen, the notification and
 * Bluetooth/headset buttons. Media3 posts and updates the notification itself.
 */
class PlaybackService : MediaSessionService() {
  private var session: MediaSession? = null

  override fun onCreate() {
    super.onCreate()
    val open = PendingIntent.getActivity(
      this, 0,
      Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
      PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
    val s = MediaSession.Builder(this, MediaSessionPlayer.shared).setSessionActivity(open).build()
    session = s
    addSession(s)
  }

  override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

  /** Swiped away from recents: keep going while music plays, as every music app does. */
  override fun onTaskRemoved(rootIntent: Intent?) {
    if (!MediaSessionPlayer.shared.isActive) stopSelf()
  }

  override fun onDestroy() {
    session?.release()
    session = null
    super.onDestroy()
  }
}
