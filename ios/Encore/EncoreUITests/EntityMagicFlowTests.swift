import XCTest

/// Stream magic-ib: the entity-page touches that need a real finger. Pull down a playlist for Find
/// in playlist, Sort by, the Recommended footer's + and Refresh, the artist's Discography chips and
/// "See discography", and re-tapping Search. Mock core. `TEST_RUNNER_MAGIC_SHOTS=<dir>` also writes
/// a screenshot of each checked state there (docs/compare/ios/magic-ib-*.png).
final class EntityMagicFlowTests: XCTestCase {
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
        guard let dir = ProcessInfo.processInfo.environment["MAGIC_SHOTS"] else { return }
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/magic-ib-\(name).png"))
    }

    private func drag(_ dy: CGFloat, from y: CGFloat = 0.7) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// Scroll up until `e` is on screen and clear of the bottom chrome.
    private func scrollTo(_ e: XCUIElement, maxSwipes: Int = 12) {
        let limit = app.frame.height * 0.72
        for _ in 0..<maxSwipes where !(e.exists && e.isHittable && e.frame.maxY < limit) { drag(-300) }
    }

    private func toastShows(_ text: String, timeout: TimeInterval = 4) -> Bool {
        let t = el("toast")
        guard t.waitForExistence(timeout: timeout) else { return false }
        return t.label.contains(text) || t.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(text) }
    }

    /// Pulling the playlist down reveals Find in playlist; typing filters the rows.
    func testPullDownFindsInPlaylist() {
        launch("encore://playlist/LOCALPLAYLIST:1")
        XCTAssertTrue(el("entity-play").waitForExistence(timeout: 8))
        XCTAssertFalse(el("find-in-playlist").exists)
        let before = app.descendants(matching: .any).matching(identifier: "track-row").count
        drag(420, from: 0.25)
        XCTAssertTrue(el("find-in-playlist").waitForExistence(timeout: 3), "pulling down reveals Find in playlist")
        el("find-in-playlist").tap()
        el("find-in-playlist").typeText("zzzq")
        XCTAssertTrue(el("find-no-match").waitForExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "track-row").count, 0)
        app.buttons["Clear"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "track-row").firstMatch.waitForExistence(timeout: 3), "clearing brings the rows back")
        XCTAssertGreaterThan(before, 0)
        shot("find")
    }

    /// Sort by: Title puts the rows in title order; Custom order puts them back (and leaves nothing remembered).
    func testSortSheet() {
        launch("encore://playlist/LOCALPLAYLIST:1?find=")
        XCTAssertTrue(el("playlist-sort").waitForExistence(timeout: 8))
        el("playlist-sort").tap()
        XCTAssertTrue(el("sort-title").waitForExistence(timeout: 3))
        shot("sort-sheet")
        el("sort-title").tap()
        let rows = app.descendants(matching: .any).matching(identifier: "track-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        // A row reads "<title>, downloaded, <artist>, more options…": compare the titles.
        let titles = (0..<min(4, rows.count)).map { rows.element(boundBy: $0).label.lowercased().components(separatedBy: ", ")[0] }
        XCTAssertEqual(titles, titles.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending }, "rows are in title order")
        el("playlist-sort").tap()
        XCTAssertTrue(el("sort-custom").waitForExistence(timeout: 3))
        el("sort-custom").tap()
    }

    /// Own playlist footer: + adds the song (toast, the row leaves), Refresh brings another batch.
    func testRecommendedFooter() {
        launch("encore://playlist/LOCALPLAYLIST:8")
        XCTAssertTrue(el("entity-play").waitForExistence(timeout: 8))
        let add = app.buttons.matching(identifier: "recommended-add").firstMatch
        scrollTo(add)
        XCTAssertTrue(add.waitForExistence(timeout: 4), "own playlists end with Recommended")
        let rows = app.descendants(matching: .any).matching(identifier: "recommended-row")
        let n = rows.count
        let label = add.label
        shot("recommended")
        add.tap()
        XCTAssertTrue(toastShows("Added to Robot Rock"))
        XCTAssertEqual(rows.count, n - 1, "the added row leaves the list")
        XCTAssertNotEqual(app.buttons.matching(identifier: "recommended-add").firstMatch.label, label)
        let refresh = el("recommended-refresh")
        scrollTo(refresh)
        refresh.tap()
        let firstAfter = app.buttons.matching(identifier: "recommended-add").firstMatch
        XCTAssertTrue(firstAfter.waitForExistence(timeout: 4))
    }

    /// "Add to this playlist" opens on Recommended songs before anything is typed; + adds one.
    func testAddSongsRecommended() {
        launch("encore://playlist/LOCALPLAYLIST:8")
        let open = el("add-to-this-playlist")
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()
        let add = app.buttons.matching(identifier: "add-recommended").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "the sheet suggests songs before a search")
        XCTAssertTrue(el("add-recommended-refresh").exists || app.buttons["Refresh"].exists)
        shot("add-songs-recommended")
        let title = add.label.replacingOccurrences(of: "Add ", with: "")
        add.tap()
        XCTAssertTrue(app.buttons["Added \(title)"].waitForExistence(timeout: 4), "the row turns into a check")
    }

    /// Artist page: Discography chips switch the releases; See discography opens the full page.
    func testArtistDiscography() {
        launch("encore://artist/UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertTrue(el("artist-follow").waitForExistence(timeout: 8))
        let chip = el("disco-chip-singles")
        scrollTo(chip)
        XCTAssertTrue(chip.exists, "the artist page has a Discography block with chips")
        chip.tap()
        XCTAssertTrue(chip.isSelected)
        shot("artist-discography")
        let see = el("see-discography")
        scrollTo(see)
        see.tap()
        XCTAssertTrue(el("discography-page").waitForExistence(timeout: 4))
        XCTAssertTrue(el("release-row").waitForExistence(timeout: 4))
        shot("discography-page")
        el("back").firstMatch.tap()
        XCTAssertTrue(el("artist-follow").waitForExistence(timeout: 3))
    }

    /// #27: the "Show all" grid is a route on Home's stack, so Back from a page opened in it
    /// returns to the grid (not to Home).
    func testBackFromShelfGridPageReturnsToGrid() {
        launch("encore://home")
        let showAll = el("home-show-all").firstMatch
        XCTAssertTrue(showAll.waitForExistence(timeout: 15))
        showAll.tap()
        XCTAssertTrue(el("shelf-grid").waitForExistence(timeout: 4))
        let item = el("shelf-grid-item").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
        sleep(1)
        XCTAssertFalse(item.isHittable, "the opened page covers the grid")
        let back = app.buttons.matching(identifier: "back").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(back)
        back?.tap()
        XCTAssertTrue(el("shelf-grid-item").firstMatch.waitForExistence(timeout: 4))
        sleep(1)
        XCTAssertTrue(el("shelf-grid-item").firstMatch.isHittable, "Back lands on the grid")
        XCTAssertFalse(showAll.isHittable, "not on Home")
        shot("shelf-grid-back")
    }

    /// I-B2: Liked Songs chips filter the list; Enhance mixes in suggestions with + and −.
    func testChipsAndEnhance() {
        launch("encore://liked")
        let chip = el("smart-chip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "Liked Songs shows genre chips")
        let rows = app.descendants(matching: .any).matching(identifier: "track-row")
        let before = rows.count
        chip.tap()
        XCTAssertTrue(el("smart-chip-clear").waitForExistence(timeout: 3))
        XCTAssertFalse(el("enhance").exists, "Enhance hides under a chip")
        sleep(1)
        XCTAssertLessThanOrEqual(rows.count, before)
        shot("liked-chips")
        el("smart-chip-clear").tap()
        let enhance = el("enhance")
        XCTAssertTrue(enhance.waitForExistence(timeout: 3))
        enhance.tap()
        let sug = el("enhance-row").firstMatch
        scrollTo(sug)
        XCTAssertTrue(sug.waitForExistence(timeout: 4), "Enhance mixes suggestions into the list")
        shot("enhance")
        let n = app.descendants(matching: .any).matching(identifier: "enhance-row").count
        app.buttons.matching(identifier: "enhance-remove").firstMatch.tap()
        sleep(1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "enhance-row").count, n - 1, "− drops the suggestion")
        // Leave Enhance off for other runs.
        for _ in 0..<6 where !el("enhance").isHittable { drag(300, from: 0.3) }
        el("enhance").tap()
    }

    /// Re-tapping Search on its root puts the cursor in the search field.
    func testSearchRetapFocuses() {
        launch("encore://search")
        XCTAssertTrue(el("tab-search").waitForExistence(timeout: 8))
        XCTAssertFalse(el("search-input").exists)
        el("tab-search").tap()
        XCTAssertTrue(el("search-input").waitForExistence(timeout: 3), "the re-tap opens the focused search")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    }
}
