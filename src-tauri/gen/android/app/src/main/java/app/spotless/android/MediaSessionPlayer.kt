package app.spotless.android

import android.net.Uri
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * What the lock screen, the notification and Bluetooth/headset buttons see as "the player".
 *
 * The audio itself is libmpv in the Rust core; this only mirrors its state (pushed by
 * [MediaPlugin] from src-tauri/src/mobile/media.rs) and turns presses into commands for the core
 * ([Native.onMediaCommand]), the way souvlaki does for MPRIS / SMTC / NowPlaying on the desktop.
 *
 * The queue lives in the core, so the playlist shown here is the current track between two
 * stand-ins: that is what makes Media3 offer previous/next, and a seek to either one is turned
 * into "previous"/"next" instead of being carried out.
 */
class MediaSessionPlayer : SimpleBasePlayer(Looper.getMainLooper()) {
  private var metadata: MediaMetadata = MediaMetadata.EMPTY
  private var durationUs: Long = C.TIME_UNSET
  private var positionMs: Long = 0
  private var playing = false
  private var hasTrack = false

  fun update(title: String, artist: String, album: String?, cover: String?, durationMs: Long, positionMs: Long, playing: Boolean) {
    val art = cover?.takeIf { it.isNotEmpty() }?.let { if (it.startsWith("/")) Uri.parse("file://$it") else Uri.parse(it) }
    metadata = MediaMetadata.Builder()
      .setTitle(title)
      .setArtist(artist)
      .setAlbumTitle(album)
      .setArtworkUri(art)
      .build()
    durationUs = if (durationMs > 0) durationMs * 1000 else C.TIME_UNSET
    this.positionMs = positionMs.coerceAtLeast(0)
    this.playing = playing
    hasTrack = title.isNotEmpty()
    invalidateState()
  }

  val isActive: Boolean get() = playing

  override fun getState(): State {
    val commands = Player.Commands.Builder()
      .addAll(
        COMMAND_PLAY_PAUSE, COMMAND_STOP,
        COMMAND_SEEK_TO_NEXT, COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        COMMAND_SEEK_TO_PREVIOUS, COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
        COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
        COMMAND_GET_CURRENT_MEDIA_ITEM, COMMAND_GET_METADATA, COMMAND_GET_TIMELINE,
      )
      .build()
    val b = State.Builder()
      .setAvailableCommands(commands)
      .setPlayWhenReady(playing, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
    if (!hasTrack) return b.setPlaybackState(STATE_IDLE).build()
    val current = MediaItemData.Builder(CURRENT)
      .setMediaMetadata(metadata)
      .setDurationUs(durationUs)
      .setIsSeekable(true)
      .build()
    return b
      .setPlaybackState(STATE_READY)
      .setPlaylist(listOf(stub(PREVIOUS), current, stub(NEXT)))
      .setCurrentMediaItemIndex(1)
      .setContentPositionMs(
        if (playing) PositionSupplier.getExtrapolating(positionMs, 1f)
        else PositionSupplier.getConstant(positionMs)
      )
      .build()
  }

  override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
    Native.onMediaCommand(if (playWhenReady) "play" else "pause", 0.0)
    playing = playWhenReady
    return Futures.immediateVoidFuture()
  }

  override fun handleStop(): ListenableFuture<*> = handleSetPlayWhenReady(false)

  override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
    when {
      mediaItemIndex == 0 || seekCommand == COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> Native.onMediaCommand("previous", 0.0)
      mediaItemIndex == 2 || seekCommand == COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> Native.onMediaCommand("next", 0.0)
      else -> {
        val ms = if (positionMs == C.TIME_UNSET) 0 else positionMs
        Native.onMediaCommand("seek", ms / 1000.0)
        this.positionMs = ms
      }
    }
    return Futures.immediateVoidFuture()
  }

  private fun stub(id: String) = MediaItemData.Builder(id).setDurationUs(C.TIME_UNSET).build()

  companion object {
    private const val PREVIOUS = "previous"
    private const val CURRENT = "current"
    private const val NEXT = "next"

    /** One per process, created on the main thread (Media3 requires the player's looper). */
    val shared: MediaSessionPlayer by lazy { MediaSessionPlayer() }
  }
}
