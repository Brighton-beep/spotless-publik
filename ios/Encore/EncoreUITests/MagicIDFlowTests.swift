import XCTest

/// Lane I-D on the running app: song results swipe like track rows (#23), and a greyed row says
/// why when tapped, with a way out (#29).
final class MagicIDFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-mock", "-uitest", "-deeplink", "encore://search?q=daft%20punk"]
        app.launch()
    }

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'result-row' AND label CONTAINS %@", title)).firstMatch
    }

    private var toast: XCUIElement { app.descendants(matching: .any)["toast"] }

    private func toastSays(_ text: String, timeout: TimeInterval = 4) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        return app.descendants(matching: .any).matching(identifier: "toast").matching(p).firstMatch.waitForExistence(timeout: timeout)
            || app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: 1)
    }

    private func drag(_ e: XCUIElement, dx: CGFloat) {
        let s = e.coordinate(withNormalizedOffset: CGVector(dx: dx > 0 ? 0.1 : 0.8, dy: 0.5))
        s.press(forDuration: 0.05, thenDragTo: s.withOffset(CGVector(dx: dx, dy: 0)), withVelocity: .default, thenHoldForDuration: 0.1)
    }

    /// #23: swipe right on a song result adds it to the queue; swipe left saves it.
    func testSongResultSwipes() {
        let r = row("Aerodynamic")
        XCTAssertTrue(r.waitForExistence(timeout: 8))
        drag(r, dx: 220)
        XCTAssertTrue(toastSays("Added to queue"), "swipe right on a search result queues it")
        drag(r, dx: -220)
        XCTAssertTrue(toastSays("Liked Songs"), "swipe left on a search result saves it")
    }

    /// A finger-like swipe (no press first, straight into the drag) past the threshold queues, as
    /// on a real phone; a short one springs back and does nothing.
    func testSwipeToQueueLikeAFinger() {
        let r = row("Aerodynamic")
        XCTAssertTrue(r.waitForExistence(timeout: 8))
        let w = app.frame.width  // the row spans the screen
        // Short: ~20 % of the row, released before the threshold.
        let s = r.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        s.press(forDuration: 0, thenDragTo: s.withOffset(CGVector(dx: w * 0.2, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertFalse(toast.waitForExistence(timeout: 1.5), "a short swipe cancels")
        sleep(1)
        s.press(forDuration: 0, thenDragTo: s.withOffset(CGVector(dx: w * 0.55, dy: 4)), withVelocity: .default, thenHoldForDuration: 0)
        XCTAssertTrue(toastSays("Added to queue"), "a full swipe right queues the song")
        add({ let a = XCTAttachment(screenshot: app.screenshot()); a.name = "swipe-queue-toast"; a.lifetime = .keepAlways; return a }())
        // A quick flick works too.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: toast)
        waitForExpectations(timeout: 8)
        s.press(forDuration: 0, thenDragTo: s.withOffset(CGVector(dx: w * 0.6, dy: -6)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(toastSays("Added to queue"), "a flick right queues the song")
    }

    /// A slightly slanted vertical drag on a song row still scrolls the list and queues nothing.
    func testVerticalDragOnRowScrolls() {
        let r = row("Voyager")
        XCTAssertTrue(r.waitForExistence(timeout: 8))
        let y = r.frame.minY
        let s = r.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        s.press(forDuration: 0, thenDragTo: s.withOffset(CGVector(dx: 30, dy: -200)), withVelocity: .default, thenHoldForDuration: 0.3)
        XCTAssertFalse(toast.waitForExistence(timeout: 1.5), "a vertical drag doesn't queue")
        XCTAssertLessThan(r.frame.minY, y - 100, "a vertical drag on a row scrolls the results")
    }

    /// #23: artists, albums and playlists don't swipe (a short drag leaves no toast).
    func testNonSongResultDoesNotSwipe() {
        let artist = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'result-row' AND label BEGINSWITH 'Daft Punk'")).firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 8))
        drag(artist, dx: 220)
        XCTAssertFalse(toast.waitForExistence(timeout: 1.5))
    }

    /// #29: hide a song, tap its greyed row: a toast says why, and Unhide makes it playable.
    func testGreyedRowToastUnhides() {
        let r = row("Aerodynamic")
        XCTAssertTrue(r.waitForExistence(timeout: 8))
        r.press(forDuration: 0.8)
        let sheet = app.descendants(matching: .any)["action-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 6))
        let hide = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Hide song'")).firstMatch
        if !hide.isHittable { sheet.swipeUp() }
        XCTAssertTrue(hide.waitForExistence(timeout: 4))
        hide.tap()
        XCTAssertTrue(toastSays("Song hidden"))
        XCTAssertTrue(row("Aerodynamic").waitForExistence(timeout: 4))
        // Wait out the first toast so the next one is the row's.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: toast)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(row("Aerodynamic").value as? String, "unavailable")

        row("Aerodynamic").tap()
        XCTAssertTrue(toastSays("You hid this song"), "a greyed row explains itself")
        add({ let a = XCTAttachment(screenshot: app.screenshot()); a.name = "magic-id-greyed-toast"; a.lifetime = .keepAlways; return a }())
        toast.tap()
        XCTAssertTrue(toastSays("Song unhidden"))
        let playable = NSPredicate(format: "value == ''")
        expectation(for: playable, evaluatedWith: row("Aerodynamic"))
        waitForExpectations(timeout: 4)
    }
}
