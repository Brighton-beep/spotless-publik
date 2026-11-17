import XCTest

/// Edge swipe from the left goes back on pushed pages (the bar is hidden app-wide, which turns
/// UIKit's pop gesture off unless SwipeBack.swift re-enables it).
final class SwipeBackTests: XCTestCase {
    func testEdgeSwipeGoesBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-mock"]
        app.launch()

        let liked = app.staticTexts["Liked Songs"].firstMatch
        XCTAssertTrue(liked.waitForExistence(timeout: 10))
        liked.tap()
        sleep(2)
        let allChip = app.buttons["All"].firstMatch
        XCTAssertFalse(allChip.exists && allChip.isHittable, "Liked Songs page should cover Home")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
        sleep(2)
        XCTAssertTrue(allChip.waitForExistence(timeout: 4) && allChip.isHittable, "edge swipe should go back to Home")
    }
}
