package app.spotless.android

/** Android → Rust calls, implemented in src-tauri/src/mobile/. */
object Native {
  /** Media session press (media.rs): play, pause, next, previous or seek (`arg` = seconds). */
  @JvmStatic external fun onMediaCommand(cmd: String, arg: Double)

  /** The sign-in screen loaded a page or closed: check its cookies now (session.rs). */
  @JvmStatic external fun onLoginNudge()
}
