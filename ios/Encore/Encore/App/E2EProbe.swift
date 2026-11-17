// End-to-end test support (EncoreE2ETests, docs/streams/ios-e2e.md). Only active with launch arguments:
//   -e2eReset YES   wipe the core's database and downloads before the core starts (a fresh user;
//                   the cipher cache stays, it is not user state)
//   -e2e YES        an invisible element `e2e-state` whose accessibility value is the live player /
//                   library state as JSON: the oracle the XCUITests read alongside the visible UI.
import SwiftUI

enum E2E {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "e2e") }

    /// Before `RealCoreClient.start()`.
    static func resetIfAsked() {
        guard UserDefaults.standard.bool(forKey: "e2eReset") else { return }
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Encore") else { return }
        for name in ["encore.sqlite", "encore.sqlite-shm", "encore.sqlite-wal", "Downloads"] {
            try? fm.removeItem(at: support.appendingPathComponent(name))
        }
        print("ENCORE_E2E reset")
    }

    /// The probe lives in its own 1 pt window above everything, so presented sheets and covers
    /// (which hide the views under them from accessibility) never hide it.
    @MainActor private static var window: UIWindow?
    @MainActor static func installProbe(_ app: AppModel) {
        guard enabled, window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        w.windowLevel = .alert + 10
        w.isUserInteractionEnabled = false
        let host = UIHostingController(rootView: E2EProbe().environment(app))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }
}

/// The state oracle. Re-renders on every observed change (position events included).
struct E2EProbe: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Text(" ")
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("e2e-state")
            .accessibilityValue(json)
            .allowsHitTesting(false)
    }

    private var json: String {
        let p = app.player
        let q = p.queue
        let lib = app.library.snapshot
        let s = app.settings
        var d: [String: Any] = [
            "id": p.now?.videoId ?? "",
            "title": p.now?.title ?? "",
            "pos": (p.position * 10).rounded() / 10,
            "dur": (p.duration * 10).rounded() / 10,
            "paused": p.paused,
            // stream: instant: the last tap's timing (-1 until it happened).
            "loading": p.loading,
            "tapUiMs": p.tapUiMs ?? -1,
            "tapAudioMs": p.tapAudioMs ?? -1,
            "taps": p.taps,
            "tapId": p.tapId ?? "",
            "hangs": HangWatch.shared.summary.count,
            "worstHangMs": HangWatch.shared.summary.worstMs,
            "shuffle": p.shuffle,
            "repeat": p.repeatMode.rawValue,
            "qi": q.currentIndex,
            "q": q.items.map(\.videoId),
            "auto": q.items.enumerated().filter { $0.offset > q.currentIndex && $0.element.autoplay == true }.count,
            "qt": q.items.map(\.title),
            "src": q.sourceName ?? "",
            "srcId": q.sourceId ?? "",
            "smart": s.smartShuffle.on,
            "recs": s.smartShuffle.recIds.count,
            "speed": s.speed,
            "sleep": s.sleep.mode.map { "\($0)" } ?? "",
            "liked": lib.likedIds,
            "playlists": lib.playlists.map { ["id": $0.id, "name": $0.name, "count": $0.count] },
            "saved": lib.saved.map(\.id),
            "follows": app.podcasts.follows.map(\.id),
            "mfy": s.madeForYou.count,
            "explicitFilter": s.smart.explicitFilter,
            "normalize": s.audio?.normalize ?? false,
            "crossfade": s.audio?.crossfadeSecs ?? -1,
            "eq": s.audio?.eq.preset ?? "",
            "eqOn": s.audio?.eq.enabled ?? false,
            "import": app.importOpen,
            "hidden": app.library.snapshot.hiddenIds ?? [],
            "dlDone": app.downloads.done.count,
            "dlActive": app.downloads.active.count,
            "offline": app.downloads.offline,
            "nowPlayingOpen": app.router.nowPlayingOpen,
        ]
        if let e = p.now?.videoId, let pr = app.podcasts.progress[e] { d["epPos"] = pr.positionSecs }
        for (k, v) in d { if let x = v as? Double, !x.isFinite { d[k] = 0 } }
        guard JSONSerialization.isValidJSONObject(d),
              let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
