import XCTest

/// Stream ios-sync2 flows on the mock core: Search › Browse › Charts and New releases, and the
/// signed-in YouTube library (the mock stands in for Google; nobody types a password): the
/// account's playlists in Your Library, and one of yours opened and renamed through Edit playlist.
final class Sync2FlowTests: XCTestCase {
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

    func testBrowseOpensChartsAndNewReleases() {
        launch("encore://search")
        let charts = el("browse-charts")
        XCTAssertTrue(charts.waitForExistence(timeout: 8))
        charts.tap()
        XCTAssertTrue(app.staticTexts["Featured charts"].waitForExistence(timeout: 6))
        XCTAssertTrue(el("charts-country").exists)
        app.swipeUp()
        XCTAssertTrue(el("chart-artist").firstMatch.waitForExistence(timeout: 4), "Top artists as ranked rows")
        el("back").firstMatch.tap()
        let releases = el("browse-new")
        XCTAssertTrue(releases.waitForExistence(timeout: 6))
        releases.tap()
        XCTAssertTrue(app.staticTexts["Albums & singles"].waitForExistence(timeout: 6))
    }

    func testSignedInLibraryEditsAnAccountPlaylist() {
        launch("encore://settings/account")
        let signIn = el("youtube-signin")
        XCTAssertTrue(signIn.waitForExistence(timeout: 8))
        signIn.tap()
        XCTAssertTrue(el("youtube-account").waitForExistence(timeout: 12))
        // Your Library lists the account's playlists next to this phone's.
        // The sign-in sheet closes on its own; the tab bar is under it until then.
        let library = el("tab-library")
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: library)
        wait(for: [hittable], timeout: 15)
        library.tap()
        XCTAssertTrue(el("library-search").waitForExistence(timeout: 6))
        el("library-search").tap()
        let field = el("library-search-field")
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.typeText("Road")
        let road = app.descendants(matching: .any).matching(identifier: "library-row").matching(NSPredicate(format: "label CONTAINS 'Road Trip'")).firstMatch
        XCTAssertTrue(road.waitForExistence(timeout: 6))
        road.tap()
        XCTAssertTrue(el("add-to-this-playlist").waitForExistence(timeout: 6), "yours: Add to this playlist")
        app.buttons["More options"].firstMatch.tap()
        let edit = app.buttons["Edit playlist"]
        XCTAssertTrue(edit.waitForExistence(timeout: 4))
        edit.tap()
        let name = el("edit-name")
        XCTAssertTrue(name.waitForExistence(timeout: 6))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Road Trip 2")
        el("edit-save").tap()
        let renamed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Road Trip 2'")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 6), "renamed on the account")
    }
}
