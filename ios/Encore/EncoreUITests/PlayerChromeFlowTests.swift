import XCTest

/// Lane I-A on the running app: the Now Playing art carousel (#8), the offline bar (#5) and the
/// output-device line (#24).
final class PlayerChromeFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Late Night Drive at track 4, paused, 10 s in: past the 3 s where ⏮ restarts the song.
    private func launch(_ extra: [String] = [], links: String = "encore://play/LOCALPLAYLIST:1?index=3&pause=1&seek=10 encore://nowplaying") {
        app.launchArguments = ["-mock", "-deeplink", links] + extra
        app.launch()
    }

    private var title: XCUIElement { app.descendants(matching: .any)["np-title"] }
    private var art: XCUIElement { app.descendants(matching: .any)["np-artwork"] }

    private func value(_ e: XCUIElement) -> String { e.value as? String ?? "" }

    private func waitValue(_ e: XCUIElement, not old: String, timeout: TimeInterval = 4) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let v = value(e)
            if v != old && !v.isEmpty { return v }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return value(e)
    }

    private func drag(_ e: XCUIElement, dx: CGFloat, velocity: XCUIGestureVelocity) {
        let s = e.coordinate(withNormalizedOffset: CGVector(dx: dx < 0 ? 0.8 : 0.2, dy: 0.5))
        s.press(forDuration: 0.05, thenDragTo: s.withOffset(CGVector(dx: dx, dy: 0)), withVelocity: velocity, thenHoldForDuration: 0)
    }

    /// 10 s into a track, swipe right goes back to the previous **track**, not the start of the
    /// current one (Spotify; the mini player already did this). Swipe left then plays the next.
    func testArtSwipePreviousTrackThenNext() {
        launch()
        XCTAssertTrue(art.waitForExistence(timeout: 8))
        sleep(1)
        let first = value(title)
        XCTAssertFalse(first.isEmpty)

        art.swipeRight()
        let previous = waitValue(title, not: first)
        XCTAssertNotEqual(previous, first, "swipe right past 3 s should play the previous track, not restart")

        art.swipeLeft()
        let back = waitValue(title, not: previous)
        XCTAssertEqual(back, first, "swipe left should play the next track")
    }

    /// A short, slow drag springs back without skipping.
    func testShortSlowArtDragSpringsBack() {
        launch()
        XCTAssertTrue(art.waitForExistence(timeout: 8))
        sleep(1)
        let first = value(title)
        drag(art, dx: -60, velocity: .slow)
        sleep(2)
        XCTAssertEqual(value(title), first, "a 60 pt slow drag is under 30 %: no skip")
        XCTAssertTrue(art.isHittable)
    }

    /// The ⏮ button still restarts after 3 s (only the swipe goes to the previous track).
    func testPreviousButtonStillRestarts() {
        launch()
        XCTAssertTrue(art.waitForExistence(timeout: 8))
        sleep(1)
        let first = value(title)
        app.buttons["Previous"].tap()
        sleep(2)
        XCTAssertEqual(value(title), first, "⏮ after 3 s restarts the same track")
    }

    func testOfflineBarShows() {
        launch(links: "encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://offline?on=1")
        let bar = app.descendants(matching: .any)["offline-banner"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "offline mode shows the bar")
        XCTAssertTrue(bar.label.contains("Offline mode is on"))
    }

    func testOfflineBarHidesWhenBackOnline() {
        launch(links: "encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://offline?on=1 encore://offline?on=0")
        XCTAssertTrue(app.descendants(matching: .any)["mini-player-text"].waitForExistence(timeout: 8))
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any)["offline-banner"].exists, "back online: the bar goes")
    }

    func testExternalDeviceShownInGreenLine() {
        launch(["-fakeRoute", "Kitchen Speaker"], links: "encore://play/LOCALPLAYLIST:1?index=3&pause=1")
        let mini = app.descendants(matching: .any)["mini-player-text"]
        XCTAssertTrue(mini.waitForExistence(timeout: 8))
        sleep(1)
        XCTAssertTrue(mini.label.contains("playing on Kitchen Speaker"), mini.label)
        mini.tap()
        XCTAssertTrue(app.descendants(matching: .any)["np-device"].firstMatch.waitForExistence(timeout: 4))
    }
}
