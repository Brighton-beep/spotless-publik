package app.spotless.android

/** Android → Rust half of the media controls: implemented in src-tauri/src/mobile/media.rs. */
object Native {
  /** `cmd` is play, pause, next, previous or seek (`arg` = seconds). */
  @JvmStatic external fun onMediaCommand(cmd: String, arg: Double)
}
