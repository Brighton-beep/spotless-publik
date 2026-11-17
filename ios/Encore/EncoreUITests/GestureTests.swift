import XCTest

/// Gesture checks for the shell (plan §6 verification): mini player swipe skips, swipe up / tap
/// opens Now Playing, drag down dismisses it, row swipe right queues.
final class GestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Start Late Night Drive at track 4, paused, so the mock clock doesn't advance on its own.
        app.launchArguments = ["-mock", "-deeplink", "encore://play/LOCALPLAYLIST:1?index=3&pause=1"]
        app.launch()
    }

    private var miniText: XCUIElement { app.descendants(matching: .any)["mini-player-text"] }

    private func waitValue(_ e: XCUIElement, not old: String, timeout: TimeInterval = 4) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let v = e.value as? String ?? ""
            if v != old && !v.isEmpty { return v }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return e.value as? String ?? ""
    }

    func testMiniPlayerSwipeSkipsBothWays() {
        XCTAssertTrue(miniText.waitForExistence(timeout: 8))
        sleep(1)
        let first = miniText.value as? String ?? ""
        XCTAssertFalse(first.isEmpty)

        miniText.swipeLeft()
        let second = waitValue(miniText, not: first)
        XCTAssertNotEqual(second, first, "swipe left should skip to the next track")

        miniText.swipeRight()
        let back = waitValue(miniText, not: second)
        XCTAssertEqual(back, first, "swipe right should go back to the previous track")
    }

    func testNowPlayingOpensAndDragDismisses() {
        XCTAssertTrue(miniText.waitForExistence(timeout: 8))
        miniText.tap()
        let close = app.buttons["np-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        sleep(1)
        XCTAssertTrue(close.isHittable, "Now Playing should be on screen")

        // Drag down from the header area to the bottom of the screen.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        XCTAssertFalse(close.isHittable, "drag down should dismiss Now Playing")
        XCTAssertTrue(miniText.isHittable)
    }

    func testMiniPlayerSwipeUpOpensNowPlaying() {
        XCTAssertTrue(miniText.waitForExistence(timeout: 8))
        miniText.swipeUp()
        let close = app.buttons["np-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        sleep(1)
        XCTAssertTrue(close.isHittable)
    }

    func testTrackRowSwipeRightQueues() {
        app.terminate()
        app.launchArguments = ["-mock", "-deeplink", "encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://playlist/LOCALPLAYLIST:2"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "track-row").element(boundBy: 2)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let s = row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        s.press(forDuration: 0.05, thenDragTo: s.withOffset(CGVector(dx: 200, dy: 0)), withVelocity: .default, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: 3), "swipe right should queue and toast")
    }

    private func toastShows(_ text: String) -> Bool {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 3)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 1)
    }

    func testTrackRowSwipeLeftLikes() {
        app.terminate()
        // Discovery Deep Cuts: its rows include songs not in Liked Songs.
        app.launchArguments = ["-mock", "-deeplink", "encore://playlist/LOCALPLAYLIST:3"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "track-row").element(boundBy: 1)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let s = row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        s.press(forDuration: 0.05, thenDragTo: s.withOffset(CGVector(dx: -220, dy: 0)), withVelocity: .default, thenHoldForDuration: 0.1)
        XCTAssertTrue(toastShows("Liked Songs"), "swipe left should like/unlike and toast")
    }

    func testLibraryRowSwipeRightPins() {
        app.terminate()
        app.launchArguments = ["-mock", "-deeplink", "encore://library"]
        app.launch()
        // Third row is unpinned (Late Night Drive and Liked Songs are pinned).
        let row = app.descendants(matching: .any).matching(identifier: "library-row").element(boundBy: 2)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let s = row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        s.press(forDuration: 0.05, thenDragTo: s.withOffset(CGVector(dx: 220, dy: 0)), withVelocity: .default, thenHoldForDuration: 0.1)
        XCTAssertTrue(toastShows("Pinned"), "swipe right should pin and toast")
    }
}
