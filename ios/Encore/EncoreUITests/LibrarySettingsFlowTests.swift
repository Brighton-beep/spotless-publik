import XCTest

/// Stream ios-p2 flows on the mock core: YouTube sign-in and sign-out (the mock stands in for
/// Google's page; nobody types a password), folder rename and delete with Undo, Recover playlists,
/// Recents, Clear listening history, and the media-quality list.
final class LibrarySettingsFlowTests: XCTestCase {
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

    private func toastShows(_ text: String, timeout: TimeInterval = 6) -> Bool {
        let t = el("toast")
        guard t.waitForExistence(timeout: timeout) else { return false }
        return t.label.contains(text) || t.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(text) }
    }

    func testYouTubeSignInAndSignOut() {
        launch("encore://settings/account")
        let signIn = el("youtube-signin")
        XCTAssertTrue(signIn.waitForExistence(timeout: 8))
        signIn.tap()
        // The sheet's web view lands on music.youtube.com with a signed-in jar: the app reads the
        // cookies from WKHTTPCookieStore and signs in through the core, then closes the sheet.
        XCTAssertTrue(toastShows("Signed in as Test Listener", timeout: 12))
        XCTAssertTrue(el("youtube-account").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Signed in to YouTube Music"].exists)

        el("youtube-signout").tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out' AND identifier != 'youtube-signout'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.tap()
        XCTAssertTrue(toastShows("Signed out of YouTube"))
        XCTAssertTrue(el("youtube-signin").waitForExistence(timeout: 4))
    }

    func testFolderRenameThenDeleteWithUndo() {
        launch("encore://folder/FOLDER:1")
        let menu = el("folder-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        el("folder-rename").tap()
        let field = el("name-field")
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24) + "Lifting")
        el("name-create").tap()
        XCTAssertTrue(app.staticTexts["Lifting"].waitForExistence(timeout: 4), "the page title follows the rename")

        el("folder-menu").tap()
        el("folder-delete").tap()
        let del = app.alerts.buttons["Delete"]
        XCTAssertTrue(del.waitForExistence(timeout: 4))
        del.tap()
        XCTAssertTrue(toastShows("Deleted Lifting"))
        el("toast").tap() // the whole toast is its action
        // Back in Your Library, the folder is listed again.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Lifting'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
    }

    func testRecoverADeletedPlaylist() {
        launch("encore://playlist/LOCALPLAYLIST:2")
        // Delete it from its ··· sheet, then restore it from Settings › Recover playlists.
        let more = app.buttons["More options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        let delete = app.buttons["Delete playlist"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.tap()
        sleep(1)
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(el("avatar").firstMatch.waitForExistence(timeout: 6))
        let avatar = app.descendants(matching: .any).matching(identifier: "avatar").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(avatar)
        avatar?.tap()
        app.buttons["Settings and privacy"].firstMatch.tap()
        let row = el("settings-row-Recover playlists")
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.tap()
        let restore = el("restore-LOCALPLAYLIST:2")
        XCTAssertTrue(restore.waitForExistence(timeout: 6), "the deleted playlist is listed")
        restore.tap()
        XCTAssertTrue(toastShows("Restored"))
        XCTAssertTrue(el("recover-empty").waitForExistence(timeout: 4))
    }

    func testRecentsAndClearHistory() {
        launch("encore://settings/privacy")
        let recents = el("settings-row-Recents")
        XCTAssertTrue(recents.waitForExistence(timeout: 8))
        recents.tap()
        XCTAssertTrue(app.staticTexts["Recents"].waitForExistence(timeout: 4))
        XCTAssertTrue(el("track-row").waitForExistence(timeout: 6), "the listening history lists songs")
        el("history-chip-top").tap()
        XCTAssertTrue(app.staticTexts["Top artists"].waitForExistence(timeout: 4))
        el("back").tap()

        el("clear-history").tap()
        let clear = app.alerts.buttons["Clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 4))
        clear.tap()
        XCTAssertTrue(toastShows("Listening history cleared"))
        el("settings-row-Recents").tap()
        XCTAssertTrue(el("history-empty").waitForExistence(timeout: 6))
    }

    func testQualityListHasNoDeadChoices() {
        launch("encore://settings/quality")
        XCTAssertTrue(el("quality-ios_stream_quality-auto").waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Very high"].exists, "YouTube has no tier above High")
        el("quality-ios_stream_quality-low").tap()
        XCTAssertTrue(el("quality-ios_stream_quality-low").isSelected)
    }
}
