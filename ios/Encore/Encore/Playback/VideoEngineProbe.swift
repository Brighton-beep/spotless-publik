// Engine comparison only (docs/streams/ios-video.md), never in the product path: option (b), an
// AVPlayer on the same loopback video stream, muted and slaved to mpv's audio clock the way the
// desktop slaves its <video> element (rate trim, hard seek past 1 s).
//
// `-avProbe <seconds>`: once mpv has the picture up, hide mpv's picture, start the AVPlayer and log
// AVPROBE lines (status, then drift against mpv's clock once a second, then a summary).
import AVFoundation
import UIKit

@MainActor enum VideoEngineProbe {
    static func startIfAsked(app: AppModel) {
        guard let secs = Int(UserDefaults.standard.string(forKey: "avProbe") ?? ""), secs > 0,
              let real = app.core as? RealCoreClient else { return }
        Task { await run(seconds: secs, app: app, core: real) }
    }

    private static func log(_ s: String) { print("AVPROBE \(s)"); fflush(stdout) }

    private static func run(seconds: Int, app: AppModel, core: RealCoreClient) async {
        // Wait for mpv's own picture: that is what resolves the stream and fills the proxy.
        var url: String?
        for _ in 0..<240 {
            if let id = app.player.current?.videoId, VideoStore.shared.frameUp, let u = core.core.videoProxyUrl(videoId: id) { url = u; break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // `-avProbeURL`: an H.264 stand-in (AVPlayer can't open YouTube's VP9 WebM), to measure
        // the sync loop and the decode cost all the same.
        if let o = UserDefaults.standard.string(forKey: "avProbeURL") { url = o }
        guard let url, let u = URL(string: url) else { log("no video url"); return }
        log("url \(u.absoluteString.prefix(60))…")
        core.setVideoVisible(false)

        let item = AVPlayerItem(url: u)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0, y: 120, width: 320, height: 180)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.layer.addSublayer(layer)
        defer { layer.removeFromSuperlayer() }

        let t0 = Date()
        while item.status == .unknown && Date().timeIntervalSince(t0) < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let err = item.error.map { ($0 as NSError).description } ?? "-"
        log(String(format: "status=%@ after %.2fs error=%@", item.status == .readyToPlay ? "ready" : item.status == .failed ? "failed" : "unknown",
                   Date().timeIntervalSince(t0), err))
        guard item.status == .readyToPlay else { return }

        // The desktop's sync loop: seek once, then trim the rate; seek again past 1 s of drift.
        await player.seek(to: CMTime(seconds: core.position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        var samples: [Double] = []
        var seeks = 0
        let end = Date().addingTimeInterval(Double(seconds))
        var tick = 0
        while Date() < end {
            try? await Task.sleep(nanoseconds: 250_000_000)
            tick += 1
            let drift = player.currentTime().seconds - core.position   // + = video ahead
            if abs(drift) > 1 {
                seeks += 1
                await player.seek(to: CMTime(seconds: core.position + 0.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                player.rate = 1
                continue
            }
            player.rate = abs(drift) < 0.02 ? 1 : Float(1 - max(-0.05, min(0.05, drift)))
            if tick % 4 == 0 {
                samples.append(drift)
                log(String(format: "t=%d drift=%.4f rate=%.3f", tick / 4, drift, player.rate))
            }
        }
        let abs = samples.map { Swift.abs($0) }
        let mean = abs.isEmpty ? 0 : abs.reduce(0, +) / Double(abs.count)
        log(String(format: "done samples=%d mean_abs_drift=%.4f worst_abs_drift=%.4f hard_seeks=%d", samples.count, mean, abs.max() ?? 0, seeks))
    }
}
