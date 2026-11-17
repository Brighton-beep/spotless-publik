import XCTest

/// stream: instant. A tap answers at once, as in Spotify: the mini player switches to the tapped
/// song with a loading play button, and the sound follows when its stream is ready. The mock plays
/// the core's order out with a 2 s stream resolve (`-mockResolveMs`), so a UI that waited for the
/// audio would still show the old song here.
final class InstantFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Late Night Drive playing in the mini player, Discovery Deep Cuts open to tap from.
        app.launchArguments = ["-mock", "-e2e", "YES", "-mockResolveMs", "2000",
                               "-deeplink", "encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://playlist/LOCALPLAYLIST:3"]
        app.launch()
    }

    private var mini: XCUIElement { app.descendants(matching: .any)["mini-player-text"] }
    private var play: XCUIElement { app.buttons["mini-play"] }
    private func row(_ i: Int) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "track-row").element(boundBy: i) }
    private var miniTitle: String { mini.value as? String ?? "" }
    private var probe: [String: Any] {
        let v = app.descendants(matching: .any)["e2e-state"].firstMatch.value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [String: Any] ?? [:]
    }

    /// Polls until `cond` holds or `timeout` passes; returns the seconds it took (or nil).
    private func within(_ timeout: TimeInterval, _ cond: () -> Bool) -> TimeInterval? {
        let t0 = Date()
        repeat {
            if cond() { return Date().timeIntervalSince(t0) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date().timeIntervalSince(t0) < timeout
        return nil
    }

    func testTapShowsTitleWithinPointThreeSeconds() {
        XCTAssertTrue(row(1).waitForExistence(timeout: 8))
        XCTAssertTrue(mini.waitForExistence(timeout: 8))
        let target = row(1)
        let old = miniTitle
        let title = target.label.components(separatedBy: ", ").first ?? ""
        XCTAssertFalse(title.isEmpty)
        XCTAssertNotEqual(old, title, "the tapped song must not already be playing")

        target.tap()
        // The app's own clock, tap handler to the mini player's song (XCUITest's tap round trip
        // is not part of what the user waits for).
        XCTAssertNotNil(within(1) { (probe["tapUiMs"] as? Int ?? -1) >= 0 }, "tap → mini player measured")
        let ui = probe["tapUiMs"] as? Int ?? -1
        print("INSTANT_NOTE mock tapUiMs=\(ui)")
        XCTAssertLessThan(ui, 300, "the mini player shows the tapped song within 0.3 s")
        XCTAssertEqual(miniTitle, title, "mini player shows the tapped title while the stream resolves")
        XCTAssertEqual(play.label, "Loading", "the play button shows the loading state")

        // The sound arrives when the stream is ready: then the button is Pause.
        XCTAssertNotNil(within(5) { play.label == "Pause" }, "playing once the stream resolved")
        XCTAssertEqual(miniTitle, title)
    }

    /// A second tap while the first loads wins: its title shows at once and stays, and the first
    /// one never comes back when its resolve would have finished.
    func testSecondTapWins() {
        XCTAssertTrue(row(2).waitForExistence(timeout: 8))
        row(1).tap()
        let second = row(2).label.components(separatedBy: ", ").first ?? ""
        row(2).tap()
        XCTAssertNotNil(within(1) { miniTitle == second }, "the second tap shows at once")
        XCTAssertNotNil(within(5) { play.label == "Pause" }, "the second song plays")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(miniTitle, second, "the first tap's load never takes over")
        XCTAssertEqual(probe["title"] as? String, second)
    }
}

/// stream: pod-fixes. A chapter tapped on the page of an episode that isn't playing starts that
/// episode at the chapter, not at 0:00. The mock takes 1.5 s to resolve the stream and, like mpv,
/// drops a seek sent before then, so only a start that rides on the play call passes.
final class ChapterStartFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private let episode = "1rn_Clc-MM0"

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // A song in the mini player (paused), the episode page open: the episode isn't current.
        app.launchArguments = ["-mock", "-e2e", "YES", "-mockResolveMs", "1500",
                               "-deeplink", "encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://episode/\(episode)"]
        app.launch()
    }

    private var probe: [String: Any] {
        let v = app.descendants(matching: .any)["e2e-state"].firstMatch.value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [String: Any] ?? [:]
    }

    private func within(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let t0 = Date()
        repeat {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date().timeIntervalSince(t0) < timeout
        return false
    }

    /// "1:02:03" / "12:34" → seconds.
    private func secs(_ label: String) -> Double {
        label.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }

    func testChapterTapStartsTheEpisodeAtTheChapter() {
        // Chapter 3 of the mock's five: "Light in the morning, <start>".
        let chapter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Light in the morning, ")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), "the episode page lists its chapters")
        for _ in 0..<6 where !chapter.isHittable { app.swipeUp() }
        let start = secs(chapter.label.components(separatedBy: ", ").last ?? "")
        XCTAssertGreaterThan(start, 60, "chapter 3 starts well into the episode")
        XCTAssertNotEqual(probe["id"] as? String, episode, "the episode isn't playing before the tap")

        chapter.tap()
        XCTAssertTrue(within(2) { probe["id"] as? String == episode }, "the tap starts the episode")
        XCTAssertGreaterThanOrEqual(probe["pos"] as? Double ?? 0, start - 1, "the clock shows the chapter while the stream resolves")
        XCTAssertTrue(within(5) { probe["loading"] as? Bool == false && probe["paused"] as? Bool == false }, "then it plays")
        XCTAssertGreaterThanOrEqual(probe["pos"] as? Double ?? 0, start - 1, "playing from the chapter, not from 0:00")

        // Now Playing shows it there too.
        app.descendants(matching: .any)["mini-player-text"].tap()
        let scrubber = app.descendants(matching: .any)["np-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let shown = secs(scrubber.value as? String ?? "")
        XCTAssertGreaterThanOrEqual(shown, start - 1, "Now Playing at \(shown) s, chapter starts at \(start) s")
    }
}
