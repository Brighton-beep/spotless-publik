import XCTest

/// Stream video-pods on the running app (mock core): a video podcast shows its video in Now Playing,
/// full screen on rotate, and live in the mini player once Now Playing is closed.
final class EpisodeVideoFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // The first episode of the first followed show (YouTube episodes: video podcasts).
        app.launchArguments = ["-mock", "-uitest", "-videoEpisode", "first"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func waitValue(_ e: XCUIElement, _ want: String, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if e.exists, e.value as? String == want { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func testVideoInNowPlayingAndMiniPlayer() {
        // The video replaces the cover, with "Switch to audio" under it.
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 10), "the episode's video replaces the cover")
        XCTAssertEqual(el("np-video").label, "Episode video")
        let pill = el("np-video-switch")
        XCTAssertTrue(waitValue(pill, "video"))
        XCTAssertEqual(pill.label, "Switch to audio")
        XCTAssertFalse(el("np-artwork").exists)

        // Turning the phone: full screen; back: Now Playing.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(el("np-video-fullscreen").waitForExistence(timeout: 4))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 4))

        // Elsewhere in the app: the mini player plays the video in the cover's place.
        el("np-close").tap()
        XCTAssertTrue(el("mini-video").waitForExistence(timeout: 4), "the mini player shows the video")
        XCTAssertEqual(el("mini-video").label, "Episode video")

        // "Switch to audio" in Now Playing: the cover comes back in both places.
        el("mini-player-text").tap()
        XCTAssertTrue(el("np-video-switch").waitForExistence(timeout: 4))
        el("np-video-switch").tap()
        XCTAssertTrue(waitValue(el("np-video-switch"), "audio"))
        XCTAssertTrue(el("np-artwork").waitForExistence(timeout: 3))
        el("np-close").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(el("mini-video").exists, "audio side: the cover in the mini player")
    }

    /// The expand arrows in the video's controls (one tap away).
    private func expand() {
        let video = el("np-video")
        video.tap()
        // The arrows sit at the bottom right of the 16:9 picture centred in the square slot. Tapped
        // by position: a slow accessibility snapshot can outlast their 3 s on screen.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5 + 9.0 / 32 - 0.05)).tap()
    }

    /// Spotify: a tap on the inline video shows its controls (not full screen); they hide by
    /// themselves after 3 s, or on a second tap.
    func testTapShowsVideoControls() {
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 10))
        el("np-video").tap()
        XCTAssertTrue(el("np-video-expand").waitForExistence(timeout: 2.5), "a tap shows the controls")
        XCTAssertFalse(el("np-video-fullscreen").exists, "and does not open full screen")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertFalse(el("np-video-expand").exists, "they hide after 3 s")
        el("np-video").tap()
        XCTAssertTrue(el("np-video-expand").waitForExistence(timeout: 2))
        el("np-video").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(el("np-video-expand").exists, "a second tap hides them")
        XCTAssertFalse(el("np-video-fullscreen").exists)
    }

    /// The chapter under the title opens Spotify's Chapters sheet; a row jumps there and closes it.
    func testChaptersSheet() {
        XCTAssertTrue(el("np-chapter").waitForExistence(timeout: 10))
        let first = el("np-chapter").label
        el("np-chapter").tap()
        XCTAssertTrue(el("chapters-sheet").waitForExistence(timeout: 3))
        XCTAssertTrue(el("chapters-auto").exists, "YouTube's own chapters say so")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Listener questions'")).firstMatch.tap()
        XCTAssertTrue(waitGone(el("chapters-sheet")), "a row closes the sheet")
        XCTAssertTrue(waitLabel(el("np-chapter"), "Listener questions"), "and plays from there (was \(first))")
    }

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if !e.exists { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return false
    }

    private func waitLabel(_ e: XCUIElement, _ want: String, timeout: TimeInterval = 4) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if e.exists, e.label == want { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return false
    }

    /// Spotify: the expand arrows open the video full screen (landscape), collapse brings Now Playing
    /// back in portrait, and a swipe down does the same. The mini player's video opens Now Playing.
    func testTapVideoFullscreenAndBack() {
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 10))
        expand()
        XCTAssertTrue(el("np-video-fullscreen").waitForExistence(timeout: 4), "expand opens full screen")
        XCTAssertTrue(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height, "landscape")
        // The overlay hides after 3 s of playing; a tap on the picture brings it back.
        RunLoop.current.run(until: Date().addingTimeInterval(4.5))
        XCTAssertFalse(el("np-video-play").exists, "playing: the overlay hides by itself")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(el("np-video-play").waitForExistence(timeout: 2), "a tap shows the overlay")
        // Paused from the overlay, it stays up.
        el("np-video-play").tap()
        XCTAssertTrue(el("np-video-collapse").waitForExistence(timeout: 2))
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))
        XCTAssertTrue(el("np-video-collapse").exists, "paused: the overlay stays")
        el("np-video-collapse").tap()
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 4), "collapse: Now Playing again")
        XCTAssertFalse(el("np-video-fullscreen").exists)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height, "portrait")

        // A swipe down on the full-screen video collapses it too.
        expand()
        XCTAssertTrue(el("np-video-fullscreen").waitForExistence(timeout: 4))
        el("np-video-fullscreen").swipeDown()
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 4), "swipe down: Now Playing again")

        // Now Playing closes as usual; the mini player's video opens Now Playing, not full screen.
        el("np-close").tap()
        XCTAssertTrue(el("mini-video").waitForExistence(timeout: 4))
        el("mini-video").tap()
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 4))
        XCTAssertFalse(el("np-video-fullscreen").exists)
    }
}

/// stream: chapters. Scripted drags on the Now Playing scrubber of a chaptered episode (the mock's
/// five chapters; the third starts at 31 % of the length): the thumb lands where the finger lifts,
/// and only a slow release a few points from a chapter start settles onto it.
final class ScrubberDetentFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-mock", "-uitest", "-e2e", "YES", "-videoEpisode", "first"]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private var probe: [String: Any] {
        let v = el("e2e-state").firstMatch.value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [String: Any] ?? [:]
    }
    private var pos: Double { probe["pos"] as? Double ?? -1 }

    /// Paused, the scrubber, the length, and the third chapter's start (seconds and points along
    /// the bar), with points per second.
    private func ready() -> (bar: XCUIElement, start: Double, startX: Double, ppS: Double) {
        let bar = el("np-scrubber")
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertTrue(el("np-chapter").waitForExistence(timeout: 10), "the episode's chapters loaded")
        let play = app.buttons["np-play"].firstMatch
        if play.label == "Pause" { play.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let dur = probe["dur"] as? Double ?? 0
        XCTAssertGreaterThan(dur, 60)
        let start = (0.31 * dur).rounded()
        let w = Double(bar.frame.width)
        return (bar, start, start / dur * w, w / dur)
    }

    /// Press at `from`, drag to `to` (points along the bar) at `speed` points / s, hold, lift.
    private func drag(_ bar: XCUIElement, from: Double, to: Double, speed: XCUIGestureVelocity, hold: TimeInterval) {
        let o = bar.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        o.withOffset(CGVector(dx: from, dy: 0))
            .press(forDuration: 0.05, thenDragTo: o.withOffset(CGVector(dx: to, dy: 0)), withVelocity: speed, thenHoldForDuration: hold)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    func testSlowReleaseNearAStartSettlesOntoIt() {
        let r = ready()
        drag(r.bar, from: r.startX - 60, to: r.startX + 4, speed: 80, hold: 0.4)
        XCTAssertEqual(pos, r.start, accuracy: 0.6, "4 pt past the start, held still: onto it (at \(pos), start \(r.start))")
        drag(r.bar, from: r.startX + 60, to: r.startX - 4, speed: 80, hold: 0.4)
        XCTAssertEqual(pos, r.start, accuracy: 0.6, "4 pt before it, from the right: onto it too (at \(pos))")
    }

    func testAReleaseFurtherAwayLandsWhereTheFingerLifts() {
        let r = ready()
        drag(r.bar, from: r.startX - 60, to: r.startX + 16, speed: 80, hold: 0.4)
        let want = r.start + 16 / r.ppS
        XCTAssertEqual(pos, want, accuracy: 2 / r.ppS, "16 pt past the start: there, not on it (at \(pos), want \(want))")
        drag(r.bar, from: r.startX + 60, to: r.startX - 12, speed: 80, hold: 0.4)
        XCTAssertEqual(pos, r.start - 12 / r.ppS, accuracy: 2 / r.ppS, "12 pt before a start: there (at \(pos))")
    }

    func testAFastFlickNeverSnaps() {
        let r = ready()
        drag(r.bar, from: r.startX - 75, to: r.startX + 5, speed: 1500, hold: 0)
        XCTAssertGreaterThan(abs(pos - r.start), 1 / r.ppS, "a flick lifted near a start stays where it lifted (at \(pos), start \(r.start))")
    }
}
