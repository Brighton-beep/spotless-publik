import XCTest

/// Lane magic-ic flows on the mock core: Your Library's grid/sort/chip survive a relaunch, a Home
/// shelf's "Show all" grid (pages open on top of it; Home re-tap and Back return to Home), and the
/// Music chip's ✕ state.
final class MagicICFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ links: String, persist: Bool = false) {
        app.launchArguments = ["-mock", "-uitest"] + (persist ? ["-persistViews"] : []) + ["-deeplink", links]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testLibraryViewStateSurvivesRelaunch() {
        launch("encore://library", persist: true)
        // Start from list mode whatever an earlier run left behind.
        XCTAssertTrue(el("library-sort").waitForExistence(timeout: 15))
        if app.buttons["Show as list"].exists { app.buttons["Show as list"].tap() }
        XCTAssertTrue(app.buttons["Show as grid"].waitForExistence(timeout: 8))
        app.buttons["Show as grid"].tap()
        el("library-chip-Playlists").tap()
        XCTAssertTrue(el("library-clear-filter").waitForExistence(timeout: 3))
        sleep(1) // let cfprefsd take the writes before the process is killed
        app.terminate()

        // No library deep link this time (a link sets its own chip): open the tab like a person.
        app.launchArguments = ["-mock", "-uitest", "-persistViews"]
        app.launch()
        XCTAssertTrue(el("tab-library").waitForExistence(timeout: 10))
        el("tab-library").tap()
        XCTAssertTrue(app.buttons["Show as list"].waitForExistence(timeout: 8), "grid mode came back")
        XCTAssertTrue(el("library-clear-filter").exists, "the Playlists chip came back")
        // Leave the defaults as other runs expect them.
        app.buttons["Show as list"].tap()
        el("library-clear-filter").tap()
    }

    func testShowAllGridSitsInHomeStack() {
        launch("encore://home")
        let showAll = el("home-show-all").firstMatch
        XCTAssertTrue(showAll.waitForExistence(timeout: 15))
        showAll.tap()
        XCTAssertTrue(el("shelf-grid").waitForExistence(timeout: 4))
        let first = el("shelf-grid-item").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.tap()
        // A page opened from the grid goes on top of it.
        sleep(1)
        XCTAssertFalse(el("shelf-grid-item").firstMatch.isHittable, "the opened page covers the grid")
        // Re-tapping Home pops back to Home.
        el("tab-home").tap()
        if !showAll.waitForExistence(timeout: 3) { el("tab-home").tap() }
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        // And Show all again, then back, lands on Home.
        showAll.tap()
        XCTAssertTrue(el("shelf-grid").waitForExistence(timeout: 4))
        el("back").firstMatch.tap()
        XCTAssertTrue(showAll.waitForExistence(timeout: 4))
        sleep(1)
        XCTAssertFalse(el("shelf-grid").exists)
    }

    func testChipsStayAndToggle() {
        launch("encore://home")
        XCTAssertTrue(el("home-chip-Music").waitForExistence(timeout: 15))
        el("home-chip-Music").tap()
        XCTAssertTrue(el("home-chip-Music").isSelected)
        XCTAssertTrue(el("home-chip-Podcasts").exists, "the other chips stay")
        XCTAssertTrue(el("home-chip-Audiobooks").exists)
        // The picked chip again goes back to All.
        el("home-chip-Music").tap()
        XCTAssertTrue(el("home-chip-All").isSelected)
        el("home-chip-Podcasts").tap()
        XCTAssertTrue(el("home-chip-Podcasts").isSelected)
        el("home-chip-All").tap()
        XCTAssertTrue(el("home-chip-All").isSelected)
    }
}
