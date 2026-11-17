import XCTest

/// Streams ios-import-review and onboard: the import onboarding and its review, driven like a user. Mock core by default.
/// `TEST_RUNNER_ENCORE_LIVE=1 TEST_RUNNER_ENCORE_IMPORT_ZIP=<name> TEST_RUNNER_ENCORE_IMPORT_ZIP2=<name>`
/// (zips in the app's Documents) runs `testLiveReviewAndReimport` on the real core: a synthetic Spotify export
/// (`scripts/make-spotify-export.py <zip> --review`, then the same with `--more`) is matched,
/// reviewed (a new pick from a search, a song left out), created, then imported again.
final class ImportReviewFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func ids(_ prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    /// First screen to review by a pasted link: one choice per screen, Back works.
    func testWelcomeLinkToReview() {
        app.launchArguments = ["-mock", "-uitest", "-deeplink", "encore://import"]
        app.launch()
        XCTAssertTrue(el("import-link").waitForExistence(timeout: 15), "the first screen offers a link")
        XCTAssertTrue(el("import-everything").exists)
        XCTAssertTrue(el("import-skip").exists, "Not now")

        // The data-file guide, and back.
        el("import-everything").tap()
        XCTAssertTrue(el("import-choose-file").waitForExistence(timeout: 5))
        XCTAssertTrue(el("import-open-spotify").exists)
        el("import-back").tap()
        XCTAssertTrue(el("import-link").waitForExistence(timeout: 5))

        // A link: Continue stays off until there is one.
        el("import-link").tap()
        let field = el("import-link-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(el("import-continue").isEnabled)
        field.tap()
        field.typeText("https://open.spotify.com/user/alex")
        el("import-continue").tap()
        XCTAssertTrue(el("import-start").waitForExistence(timeout: 10), "what to bring")
        el("import-start").tap()
        XCTAssertTrue(el("import-review").waitForExistence(timeout: 20), "matching ends on the summary")
        XCTAssertTrue(el("import-create").exists, "Looks good")
        XCTAssertTrue(el("import-check").exists, "the quiet link to the details")
    }

    func testReviewPickLeaveOutCreate() {
        app.launchArguments = ["-mock", "-uitest", "-deeplink", "encore://import?file=/tmp/my_spotify_data.zip&step=review"]
        app.launch()
        XCTAssertTrue(el("import-review").waitForExistence(timeout: 15), "matching ends on the summary")
        XCTAssertTrue(el("import-check").label.hasPrefix("Check "), "the link counts the uncertain ones")
        el("import-check").tap()
        XCTAssertTrue(el("import-check-list").waitForExistence(timeout: 5))
        XCTAssertTrue(el("import-section-check").waitForExistence(timeout: 5), "uncertain ones lead")

        // Another candidate for the first row.
        let first = el("import-row-sp0")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(el("import-choose").waitForExistence(timeout: 5))
        let candidates = ids("import-candidate-")
        XCTAssertGreaterThan(candidates.count, 1)
        candidates.element(boundBy: 1).tap()
        XCTAssertTrue(waitGone(el("import-choose")), "a pick closes the sheet")
        XCTAssertFalse(el("import-keep-sp0").exists, "a picked row is settled")

        // Leave the second out (from its sheet); Looks right on the third.
        el("import-row-sp1").tap()
        XCTAssertTrue(el("import-leave-out").waitForExistence(timeout: 5))
        el("import-leave-out").tap()
        XCTAssertTrue(waitGone(el("import-choose")))
        XCTAssertFalse(el("import-keep-sp1").exists, "a left-out row is settled")
        el("import-keep-sp2").tap()
        XCTAssertTrue(waitGone(el("import-keep-sp2")))

        // Not found is in the same list; the matched ones come on request.
        XCTAssertTrue(el("import-section-missing").exists || app.swipeUpAndFind(el("import-section-missing")))
        XCTAssertTrue(app.swipeUpAndFind(el("import-show-matched")))
        el("import-show-matched").tap()
        XCTAssertTrue(el("import-section-matched").waitForExistence(timeout: 5))

        el("import-check-done").tap()
        XCTAssertTrue(el("import-review").waitForExistence(timeout: 5))
        el("import-create").tap()
        XCTAssertTrue(el("import-done").waitForExistence(timeout: 10), "Looks good writes and ends on Done")
    }

    private func waitGone(_ e: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let p = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter.wait(for: [p], timeout: timeout) == .completed
    }

    // MARK: live

    private func runImport(_ zip: String, reset: Bool) {
        var args = ["-volume", "0", "-uitest", "-e2e", "YES"]
        if reset { args += ["-e2eReset", "YES"] }
        app.launchArguments = args + ["-deeplink", "encore://import?file=\(zip)&step=review"]
        app.launch()
        // A fresh user's first launch sometimes lands on Home before the link is handled (seen
        // after -e2eReset); the reset is done by then, so a plain relaunch follows the link.
        if !el("import").waitForExistence(timeout: 30) {
            app.terminate()
            app.launchArguments = ["-volume", "0", "-uitest", "-e2e", "YES", "-deeplink", "encore://import?file=\(zip)&step=review"]
            app.launch()
            XCTAssertTrue(el("import").waitForExistence(timeout: 30), "the import opens")
        }
    }

    func testLiveReviewAndReimport() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ENCORE_LIVE"] == "1", "live only (TEST_RUNNER_ENCORE_LIVE=1)")
        let zip = try XCTUnwrap(env["ENCORE_IMPORT_ZIP"]), zip2 = try XCTUnwrap(env["ENCORE_IMPORT_ZIP2"])

        // 1. First import, fresh user: matching on the real core, then review.
        runImport(zip, reset: true)
        XCTAssertTrue(el("import-review").waitForExistence(timeout: 180), "matching ends on the summary")
        XCTContext.runActivity(named: "summary: \(el("import-review").staticTexts.firstMatch.label); link: \(el("import-check").label)") { _ in }
        el("import-check").tap()
        XCTAssertTrue(el("import-section-missing").waitForExistence(timeout: 10), "the made-up demo isn't on YouTube Music")

        // A different song for a matched row, through the sheet's search.
        XCTAssertTrue(app.swipeUpAndFind(el("import-show-matched")))
        el("import-show-matched").tap()
        XCTAssertTrue(el("import-section-matched").waitForExistence(timeout: 10))
        // The matched ones come last in the list.
        let row = ids("import-row-").element(boundBy: ids("import-row-").count - 1)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let rowId = row.identifier
        row.tap()
        XCTAssertTrue(el("import-choose").waitForExistence(timeout: 5))
        let search = el("import-search")
        search.tap()
        search.typeText("\n")
        let results = ids("import-candidate-")
        XCTAssertTrue(results.element(boundBy: 1).waitForExistence(timeout: 30), "a YouTube Music search answers")
        results.element(boundBy: 1).tap()
        XCTAssertTrue(waitGone(el("import-choose"), timeout: 10))

        // Leave another one out, from its sheet.
        let other = ids("import-row-").element(boundBy: ids("import-row-").count - 2)
        XCTAssertNotEqual(rowId, other.identifier)
        other.tap()
        XCTAssertTrue(el("import-leave-out").waitForExistence(timeout: 5))
        el("import-leave-out").tap()
        XCTAssertTrue(waitGone(el("import-choose"), timeout: 10))

        el("import-check-done").tap()
        XCTAssertTrue(el("import-create").waitForExistence(timeout: 5))
        el("import-create").tap()
        XCTAssertTrue(el("import-done").waitForExistence(timeout: 120))
        XCTAssertTrue(app.staticTexts["Road Trip Classics"].exists)
        app.terminate()

        // 2. The same export a few weeks later, one song more: no second playlist.
        runImport(zip2, reset: false)
        XCTAssertTrue(el("import-review").waitForExistence(timeout: 180))
        el("import-create").tap()
        XCTAssertTrue(el("import-done").waitForExistence(timeout: 120))
        let updated = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Already imported'"))
        XCTAssertTrue(updated.firstMatch.waitForExistence(timeout: 5), "the playlists are topped up, not copied")
        XCTAssertTrue(app.staticTexts["Already imported • 1 new song"].exists, "Road Trip Classics gets its new song only")
        // Review Mix: nothing new, its made-up demo still not found.
        XCTAssertTrue(app.staticTexts["Already imported • 0 new songs • 1 not found"].exists, "Review Mix is unchanged")
    }
}

extension XCUIApplication {
    /// Scrolls the front list up until `e` is on screen (or gives up after a few swipes).
    func swipeUpAndFind(_ e: XCUIElement, tries: Int = 8) -> Bool {
        for _ in 0..<tries {
            if e.exists && e.isHittable { return true }
            swipeUp()
        }
        return e.exists && e.isHittable
    }
}
