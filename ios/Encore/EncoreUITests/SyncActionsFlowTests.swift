import XCTest

/// Lane P1 on the running app (mock core): the radio page, credits with Follow, exclude from the
/// taste profile, Remove from this playlist with Undo, Clear queue with Undo, and Don't play this artist.
final class SyncActionsFlowTests: XCTestCase {
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
    private var rows: XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "track-row") }

    private func toastSays(_ text: String, timeout: TimeInterval = 10) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        return app.descendants(matching: .any).matching(identifier: "toast").matching(p).firstMatch.waitForExistence(timeout: timeout)
    }

    /// Picks a row in the open action sheet, scrolling the sheet up when it sits below the fold.
    private func pick(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = el("action-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 6), "the action sheet opens", file: file, line: line)
        let b = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 4), "\(title) is in the sheet", file: file, line: line)
        if !b.isHittable { sheet.swipeUp() }
        if !b.isHittable { sheet.swipeUp() }
        b.tap()
    }

    private func sheetHas(_ title: String) -> Bool {
        let sheet = el("action-sheet")
        guard sheet.waitForExistence(timeout: 6) else { return false }
        return sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.waitForExistence(timeout: 3)
    }

    private func closeSheet() {
        app.swipeDown(velocity: .fast)
        _ = el("action-sheet").waitForNonExistence(timeout: 3)
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The playlist page with the first song loaded (paused) under the mini player.
    private func openPlaylist() {
        launch("encore://play/LOCALPLAYLIST:1?index=0&pause=1 encore://playlist/LOCALPLAYLIST:1")
        XCTAssertTrue(rows.element(boundBy: 3).waitForExistence(timeout: 8))
    }

    /// Go to song radio opens the page and leaves playback alone; a row then plays the radio.
    func testSongRadioPageThenPlay() {
        launch("encore://play/LOCALPLAYLIST:1?index=1 encore://menu")
        let mini = el("mini-player-text")
        XCTAssertTrue(mini.waitForExistence(timeout: 8))
        let before = mini.label
        pick("Go to song radio")
        XCTAssertTrue(el("radio-page").waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' Radio'")).firstMatch.waitForExistence(timeout: 6))
        XCTAssertTrue(el("radio-cover").exists)
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 6))
        XCTAssertEqual(mini.label, before, "opening the radio page doesn't interrupt playback")
        shot("ios-p1-radio-page")

        let target = rows.element(boundBy: 2)
        let title = target.label.components(separatedBy: ",").first ?? ""
        target.tap()
        let playing = NSPredicate(format: "label CONTAINS %@", title)
        expectation(for: playing, evaluatedWith: mini)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(el("radio-save").exists)
        el("radio-save").tap()
        XCTAssertTrue(toastSays("Added to Your Library"), "Save makes it a playlist")
    }

    /// Show credits opens the sheet; Follow on a linked artist flips to Following.
    func testShowCreditsAndFollow() {
        launch("encore://play/LOCALPLAYLIST:1?index=0&pause=1 encore://menu")
        pick("Show credits")
        XCTAssertTrue(el("credits-sheet").waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Performed by"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Source"].exists)
        let follow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow '")).firstMatch
        if follow.waitForExistence(timeout: 3) {
            follow.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Following '")).firstMatch.waitForExistence(timeout: 4))
        }
        shot("ios-p1-credits-sheet")
    }

    /// Undo in the toast includes the song again; excluding it flips the menu row to Include.
    func testExcludeFromTasteProfileWithUndo() {
        openPlaylist()
        rows.element(boundBy: 0).press(forDuration: 0.8)
        pick("Exclude from your taste profile")
        XCTAssertTrue(toastSays("Excluded from your taste profile"))
        el("toast").tap()   // Undo
        sleep(1)
        rows.element(boundBy: 0).press(forDuration: 0.8)
        XCTAssertTrue(sheetHas("Exclude from your taste profile"), "Undo included it again")
        pick("Exclude from your taste profile")
        XCTAssertTrue(toastSays("Excluded from your taste profile"))
        rows.element(boundBy: 0).press(forDuration: 0.8)
        XCTAssertTrue(sheetHas("Include in your taste profile"), "the menu now offers Include")
        pick("Include in your taste profile")
        XCTAssertTrue(toastSays("Included in your taste profile"))
    }

    /// Remove from this playlist, then Undo: the song comes back at the same row.
    func testRemoveFromPlaylistUndo() {
        openPlaylist()
        let row = rows.element(boundBy: 2)
        let label = row.label
        row.press(forDuration: 0.8)
        pick("Remove from this playlist")
        XCTAssertTrue(toastSays("Removed from"))
        let gone = NSPredicate(format: "label != %@", label)
        expectation(for: gone, evaluatedWith: rows.element(boundBy: 2))
        waitForExpectations(timeout: 5)
        shot("ios-p1-remove-undo")
        el("toast").tap()
        let back = NSPredicate(format: "label == %@", label)
        expectation(for: back, evaluatedWith: rows.element(boundBy: 2))
        waitForExpectations(timeout: 6)
    }

    /// Clear queue in the queue sheet, then Undo puts "Next in queue" back.
    func testClearQueueUndo() {
        openPlaylist()
        rows.element(boundBy: 4).press(forDuration: 0.8)
        pick("Add to queue")
        XCTAssertTrue(toastSays("Added to queue"))
        el("mini-player").tap()
        XCTAssertTrue(el("np-queue").waitForExistence(timeout: 6))
        el("np-queue").tap()
        let clear = el("queue-clear")
        XCTAssertTrue(clear.waitForExistence(timeout: 6))
        clear.tap()
        XCTAssertTrue(toastSays("Queue cleared"), "the toast shows inside the queue")
        // (Now Playing's own "Next in queue" card sits behind the sheet: watch the section's button.)
        XCTAssertTrue(clear.waitForNonExistence(timeout: 4), "the queued section is gone")
        shot("ios-p1-queue-undo")
        // The queue's own toast (the app's copy sits under Now Playing).
        el("queue").descendants(matching: .any).matching(identifier: "toast").firstMatch.tap()
        XCTAssertTrue(el("queue-clear").waitForExistence(timeout: 6), "Undo restores the queued song")
    }

    /// Don't play this artist confirms with an Undo toast.
    func testDontPlayThisArtist() {
        openPlaylist()
        rows.element(boundBy: 1).press(forDuration: 0.8)
        pick("Don't play this artist")
        XCTAssertTrue(toastSays("You won't hear"))
    }
}
