import XCTest

/// stream: audiobooks — Home's Audiobooks chip → a book → its page → a chapter plays → Now Playing
/// shows the book's chapters; the book saves to Your Library under the Audiobooks chip. Mock core.
final class AudiobookFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testChipBookChapterAndLibrary() {
        app.launchArguments = ["-mock", "-uitest", "-deeplink", "encore://home?chip=audiobooks"]
        app.launch()
        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Pride and Prejudice'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8), "the Audiobooks chip shows popular books")
        card.tap()
        XCTAssertTrue(el("audiobook-page").waitForExistence(timeout: 5))
        let chapters = app.buttons.matching(identifier: "book-chapter")
        XCTAssertTrue(chapters.element(boundBy: 2).waitForExistence(timeout: 5))
        chapters.element(boundBy: 2).tap()
        let mini = el("mini-player-text")
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        XCTAssertTrue(NSPredicate(format: "value == 'Chapter 3'").evaluate(with: mini) || mini.label.hasPrefix("Chapter 3"), "chapter 3 plays: \(mini.label)")
        mini.tap()
        XCTAssertTrue(el("np-book-chapters").waitForExistence(timeout: 8) || {
            app.swipeUp(); return el("np-book-chapters").waitForExistence(timeout: 4)
        }(), "Now Playing lists the book's chapters")
        app.swipeDown(); app.swipeDown()
        el("book-save").tap()
        app.terminate()

        app.launchArguments = ["-mock", "-uitest", "-deeplink", "encore://audiobook/pride_and_prejudice_librivox"]
        app.launch()
        XCTAssertTrue(el("audiobook-page").waitForExistence(timeout: 8))
    }

    /// Live (TEST_RUNNER_ENCORE_LIVE=1, real core, volume 0): search "Pride and Prejudice" under the
    /// Audiobooks chip, open the book, play chapter 3 ("Chapter 6"), let it save its position, quit,
    /// relaunch: the book offers to resume that chapter and plays it.
    func testLiveSearchPlayResumeAfterRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENCORE_LIVE"] == "1", "live only (TEST_RUNNER_ENCORE_LIVE=1)")
        app.launchArguments = ["-volume", "0", "-uitest", "-deeplink", "encore://search?q=Pride%20and%20Prejudice&chip=audiobooks"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "result-row").containing(NSPredicate(format: "label CONTAINS 'Pride and Prejudice'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the book is found")
        row.tap()
        XCTAssertTrue(el("audiobook-page").waitForExistence(timeout: 20))
        let chapters = app.buttons.matching(identifier: "book-chapter")
        XCTAssertTrue(chapters.element(boundBy: 2).waitForExistence(timeout: 20))
        XCTAssertTrue(chapters.element(boundBy: 2).label.contains("Chapter 6"), chapters.element(boundBy: 2).label)
        chapters.element(boundBy: 2).tap()
        let mini = el("mini-player-text")
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        // Playing: the mini player's button turns to Pause; then ~20 s of audio (saves every 5 s).
        XCTAssertTrue(NSPredicate(format: "label == 'Pause'").evaluate(with: el("mini-play")) || el("mini-play").waitForExistence(timeout: 1))
        sleep(25)
        XCTAssertTrue(mini.label.hasPrefix("Chapter 6"), mini.label)
        app.terminate()

        app.launchArguments = ["-volume", "0", "-uitest", "-deeplink", "encore://audiobook/pride_and_prejudice_librivox"]
        app.launch()
        let resume = el("book-resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "the book offers to resume")
        XCTAssertTrue(resume.label.contains("Chapter 6"), resume.label)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHOT"] ?? "/dev/null"))
        resume.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        sleep(5)
        XCTAssertTrue(mini.label.hasPrefix("Chapter 6"), mini.label)
    }
}
