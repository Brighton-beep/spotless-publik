import XCTest

/// Stream ios-video on the running app (mock core): Now Playing's "Switch to video", the video in
/// place of the cover, full screen on rotate, and "Switch to audio" back to the cover.
final class VideoFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Discovery from "One More Time", which has a music video; Now Playing opens on it.
        app.launchArguments = ["-mock", "-uitest", "-videoPick", "MPREb_7ltM34kr0mH"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func waitValue(_ e: XCUIElement, _ want: String, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if e.exists, e.value as? String == want { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func testSwitchToVideoAndBack() {
        let pill = el("np-video-switch")
        XCTAssertTrue(pill.waitForExistence(timeout: 8))
        XCTAssertTrue(waitValue(pill, "audio"))
        XCTAssertEqual(pill.label, "Switch to video")
        XCTAssertTrue(el("np-artwork").exists)

        pill.tap()
        XCTAssertTrue(waitValue(pill, "video"))
        XCTAssertEqual(pill.label, "Switch to audio")
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 3), "the video replaces the cover")
        XCTAssertFalse(el("np-artwork").exists)

        // Turning the phone: the video full screen; turning back: Now Playing again.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(el("np-video-fullscreen").waitForExistence(timeout: 4))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(el("np-video").waitForExistence(timeout: 4))
        XCTAssertFalse(el("np-video-fullscreen").exists)

        el("np-video-switch").tap()
        XCTAssertTrue(waitValue(el("np-video-switch"), "audio"))
        XCTAssertTrue(el("np-artwork").waitForExistence(timeout: 3), "the cover is back")
        XCTAssertFalse(el("np-video").exists)

        // On the song (audio) side, turning the phone keeps Now Playing in portrait.
        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(el("np-video-fullscreen").exists)
    }
}
