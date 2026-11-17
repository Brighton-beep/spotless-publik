import XCTest

/// Stream ios-parity: the screens and gestures checked against the Spotify iOS spec that need a real
/// touch to reach: the collapsing entity header (sticky play, nav title), the queue sheet (Edit,
/// remove, swipe-down close), Now Playing's context and artist links, "Remove from this playlist",
/// and recent searches that stay cleared. Mock core. `TEST_RUNNER_PARITY_SHOTS=<dir>` also writes a
/// screenshot of each checked state there (for docs/compare/ios).
final class ParityFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ links: String) {
        app.launchArguments = ["-mock", "-uitest", "-deeplink", links]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PARITY_SHOTS"] else { return }
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    private func toastShows(_ text: String, timeout: TimeInterval = 4) -> Bool {
        let t = el("toast")
        guard t.waitForExistence(timeout: timeout) else { return false }
        return t.label.contains(text) || t.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(text) }
    }

    /// Scrolling a playlist: the inline play button scrolls away and the sticky copy pins under the nav bar.
    func testEntityHeaderCollapsesToStickyPlay() {
        launch("encore://play/LOCALPLAYLIST:1?index=1&pause=1 encore://playlist/LOCALPLAYLIST:1")
        XCTAssertTrue(el("entity-play").waitForExistence(timeout: 8))
        XCTAssertFalse(el("sticky-play").exists)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -420)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(el("sticky-play").waitForExistence(timeout: 3), "the play button pins under the nav bar")
        shot("parity-playlist-scrolled")
        el("sticky-play").tap()
        // The context is already playing (paused): the sticky button resumes it.
        XCTAssertEqual(el("mini-play").label, "Pause")
    }

    func testArtistHeaderCollapses() {
        launch("encore://play/LOCALPLAYLIST:1?index=1&pause=1 encore://artist/UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertTrue(el("artist-follow").waitForExistence(timeout: 8))
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -380)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(el("sticky-play").waitForExistence(timeout: 3))
        shot("parity-artist-scrolled")
    }

    /// The queue sheet: Edit selects rows, Remove takes them out, a swipe down on the header closes it.
    func testQueueEditRemoveAndSwipeClose() {
        launch("encore://play/LOCALPLAYLIST:1?index=1&pause=1 encore://queue")
        XCTAssertTrue(el("queue").waitForExistence(timeout: 8))
        let rows = app.descendants(matching: .any).matching(identifier: "queue-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 4))
        let first = rows.element(boundBy: 0)
        let before = first.label
        XCTAssertTrue(before.hasPrefix("Karma Police"), before)
        el("queue-edit").tap()
        first.tap()
        shot("parity-queue-edit")
        el("queue-remove").tap()
        sleep(1)
        XCTAssertNotEqual(rows.element(boundBy: 0).label, before, "the selected row was removed")
        el("queue-edit").tap()   // Done
        XCTAssertTrue(el("queue-shuffle").exists, "the footer is back to Shuffle · Repeat · Timer")
        let top = el("queue-close").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        XCTAssertFalse(el("queue").exists, "swipe down closes the queue")
        XCTAssertTrue(el("np-close").isHittable, "back on Now Playing")
    }

    /// A tap on a queue row plays it (single tap, as in Spotify).
    func testQueueRowTapPlays() {
        launch("encore://play/LOCALPLAYLIST:1?index=1&pause=1 encore://queue")
        let rows = app.descendants(matching: .any).matching(identifier: "queue-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        let playing = el("mini-player-text").value as? String
        rows.element(boundBy: 1).tap()
        el("queue-close").tap()
        sleep(1)
        XCTAssertNotEqual(el("mini-player-text").value as? String, playing, "the tapped row plays")
    }

    /// Now Playing's header opens the context page; the artist line opens the artist.
    func testNowPlayingContextAndArtistLinks() {
        launch("encore://play/LOCALPLAYLIST:1?index=1&pause=1&open=1")
        XCTAssertTrue(el("np-context").waitForExistence(timeout: 8))
        sleep(1)
        el("np-context").tap()
        XCTAssertTrue(el("entity-play").waitForExistence(timeout: 5), "the playlist page opens")
        XCTAssertFalse(el("np-close").isHittable)
        el("mini-player-text").tap()
        XCTAssertTrue(el("np-artist").waitForExistence(timeout: 4))
        sleep(1)
        el("np-artist").tap()
        XCTAssertTrue(el("artist-follow").waitForExistence(timeout: 5), "the artist page opens")
    }

    /// Own playlists: the track sheet's "Remove from this playlist" takes the song out.
    func testRemoveFromThisPlaylist() {
        launch("encore://playlist/LOCALPLAYLIST:2")
        let rows = app.descendants(matching: .any).matching(identifier: "track-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        let before = rows.count
        rows.element(boundBy: 0).press(forDuration: 1.0)   // long-press → track sheet
        XCTAssertTrue(el("action-sheet").waitForExistence(timeout: 4))
        shot("parity-track-sheet")
        app.buttons["Remove from this playlist"].tap()
        XCTAssertTrue(toastShows("Removed from"))
        let deadline = Date().addingTimeInterval(4)
        while rows.count == before && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual(rows.count, before - 1)
    }

    /// "Clear recent searches" sticks after leaving and reopening search.
    func testClearedRecentSearchesStayCleared() {
        launch("encore://search?focus=1")
        let clear = el("search-clear-recents")
        XCTAssertTrue(clear.waitForExistence(timeout: 8))
        clear.tap()
        XCTAssertTrue(app.staticTexts["Find your next favourite"].waitForExistence(timeout: 3))
        shot("parity-search-empty")
        el("search-cancel").tap()
        el("search-field").firstMatch.tap()
        XCTAssertTrue(el("search-input").waitForExistence(timeout: 4))
        XCTAssertFalse(el("search-clear-recents").exists, "recents stay cleared")
        // Results: "Top" is the default chip.
        el("search-input").typeText("daft punk")
        XCTAssertTrue(el("result-row").waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Top"].exists)
        XCTAssertTrue(app.buttons["Profiles"].exists, "search2: Profiles is a chip (YouTube channels)")
        shot("parity-search-results")
    }

    /// Stream ios-dailymix: Home's live Your Mix tile (before Made for you's first build) opens
    /// the mix page with its songs, and Play plays them.
    func testDailyMixTileOpensMixPageAndPlays() {
        app.launchArguments = ["-mock", "-uitest", "-mockLiveMixes", "1"]
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your Mix 1'")).firstMatch
        var tries = 0
        while !tile.waitForExistence(timeout: tries == 0 ? 8 : 2) || !tile.isHittable, tries < 6 {
            app.swipeUp(); tries += 1
        }
        tile.tap()
        XCTAssertTrue(el("mix-page").waitForExistence(timeout: 5), "the mix page opens, not a playlist page")
        let rows = app.descendants(matching: .any).matching(identifier: "track-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the mix shows its songs")
        XCTAssertGreaterThan(rows.count, 3)
        let first = rows.element(boundBy: 0).label
        shot("dailymix-page")
        el("entity-play").tap()
        XCTAssertTrue(el("mini-player").waitForExistence(timeout: 5))
        let playing = el("mini-player-text").value as? String ?? ""
        XCTAssertFalse(playing.isEmpty)
        XCTAssertTrue(first.hasPrefix(playing), "the mix's first song plays: \(first) vs \(playing)")
        XCTAssertEqual(el("entity-play").label, "Pause", "the page knows its mix is playing")
    }
}
