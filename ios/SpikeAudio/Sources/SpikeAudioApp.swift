import AVFoundation
import SwiftUI
import UIKit
import os

/// iOS spike S1 (audio). On launch: self-tests (ao=pcm to files), then continuous playback on a
/// real output for the background check. Driven by environment variables so the simulator run
/// needs no taps (pass them as SIMCTL_CHILD_<name> to `xcrun simctl launch`):
///   SPIKE_URL     googlevideo URL for the stream test and live playback (else the WAV loops)
///   SPIKE_AO      live output, default "audiounit"; "null" for a timed null output
///   SPIKE_VOLUME  live mpv volume 0-100, default 0 (silent: no speakers needed)
///   SPIKE_SKIP_SELFTEST=1
let log = Logger(subsystem: "app.encore.ios.spike", category: "audio")

func emit(_ line: String) {
    print(line)
    fflush(stdout)
    log.notice("\(line, privacy: .public)")
}

final class Spike: ObservableObject {
    @Published var status = "starting"
    @Published var position = -1.0
    @Published var report = ""
    private var timer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var _state = "active"
    var state: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _state }
        set { stateLock.lock(); _state = newValue; stateLock.unlock() }
    }

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.state = "background"; emit("SPIKE_STATE background")
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.state = "active"; emit("SPIKE_STATE foreground")
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            emit("SPIKE_INTERRUPTION \(n.userInfo ?? [:])")
        }
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let env = ProcessInfo.processInfo.environment
        let url = env["SPIKE_URL"].flatMap { $0.isEmpty ? nil : $0 }
        let ao = env["SPIKE_AO"] ?? "audiounit"
        let volume = Int64(env["SPIKE_VOLUME"] ?? "0") ?? 0
        let skip = env["SPIKE_SKIP_SELFTEST"] == "1"
        // Session before mpv opens its AO (plan 2.3).
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try s.setActive(true)
            emit("SPIKE_SESSION ok category=\(s.category.rawValue)")
        } catch {
            emit("SPIKE_SESSION error \(error)")
        }
        let fixtures = Bundle.main.resourceURL!.appendingPathComponent("fixtures").path
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let work = caches.appendingPathComponent("selftest").path
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if !skip {
                DispatchQueue.main.async { self.status = "self-tests running" }
                let t0 = Date()
                let raw = spike_selftest(fixtures, work, url)!
                let json = String(cString: raw)
                spike_string_free(raw)
                try? json.write(to: docs.appendingPathComponent("selftest.json"), atomically: true, encoding: .utf8)
                emit("SPIKE_SELFTEST \(json)")
                emit(String(format: "SPIKE_SELFTEST_DONE seconds=%.2f", Date().timeIntervalSince(t0)))
                DispatchQueue.main.async { self.report = json }
            }
            let src = url ?? (fixtures + "/a.wav")
            let ok = spike_live_start(src, ao, caches.appendingPathComponent("live").path, volume)
            emit("SPIKE_LIVE_START ok=\(ok) ao=\(ao) volume=\(volume) src=\(url == nil ? "a.wav (loop)" : "url")")
            DispatchQueue.main.async { self.status = ok ? "live (\(ao))" : "live start failed" }
            self.tick()
        }
    }

    private func tick() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let pos = spike_live_position()
            let raw = spike_live_ao()!
            let ao = String(cString: raw)
            spike_string_free(raw)
            emit(String(format: "SPIKE_POS wall=%.1f pos=%.3f state=%@ ao=%@",
                        Date().timeIntervalSince1970, pos, self.state, ao))
            DispatchQueue.main.async { self.position = pos }
        }
        t.resume()
        timer = t
    }
}

@main
struct SpikeAudioApp: App {
    @StateObject private var spike = Spike()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Encore audio spike").font(.title2.bold())
                Text(spike.status)
                Text(String(format: "position %.2f s", spike.position)).monospacedDigit()
                ScrollView { Text(spike.report).font(.caption2.monospaced()) }
            }
            .padding()
            .onAppear { spike.start() }
        }
    }
}
