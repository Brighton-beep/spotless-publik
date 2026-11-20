fn main() {
    // Last.fm API credentials live in a gitignored `lastfm.keys` next to this file (the repo is
    // public — they must never be tracked). Format: `LIMUSIC_LASTFM_API_KEY=…` and
    // `LIMUSIC_LASTFM_API_SECRET=…`, one per line. Exported as compile-time env for `option_env!`
    // in lastfm.rs; missing file just means the scrobbler reports "not configured".
    println!("cargo:rerun-if-changed=lastfm.keys");
    if let Ok(keys) = std::fs::read_to_string("lastfm.keys") {
        for line in keys.lines() {
            if let Some((k, v)) = line.split_once('=') {
                let (k, v) = (k.trim(), v.trim());
                if k == "LIMUSIC_LASTFM_API_KEY" || k == "LIMUSIC_LASTFM_API_SECRET" {
                    println!("cargo:rustc-env={k}={v}");
                }
            }
        }
    }
    // tauri-build watches tauri.conf.json but not the icons it embeds, so editing a PNG here
    // leaves `generate_context!` emitting the old `default_window_icon` (window, tray, taskbar).
    println!("cargo:rerun-if-changed=icons");

    // Android: libmpv and the FFmpeg it needs are prebuilt by CI (android/libmpv, the
    // android-libmpv workflow) into the APK's jniLibs. Link against those same files.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        let abi = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
            Ok("aarch64") => "arm64-v8a",
            Ok("arm") => "armeabi-v7a",
            Ok("x86_64") => "x86_64",
            _ => "x86",
        };
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("gen/android/app/src/main/jniLibs")
            .join(abi);
        println!("cargo:rerun-if-changed={}", dir.display());
        println!("cargo:rustc-link-search=native={}", dir.display());
    }

    tauri_build::build()
}
