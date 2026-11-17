// Made for you, What's New, the Home bell and Smart Shuffle in the queue (stream ios-screens2, fork D).
import XCTest
@testable import Encore

final class SmartSnapshotTests: SnapshotCase {
    func testMadeForYouHub() async { await snap("encore://made-for-you") }
    func testDailyMix() async { await snap("encore://playlist/MFY_DAILY_1") }
    func testDiscoverWeekly() async { await snap("encore://playlist/MFY_DISCOVER_WEEKLY") }
    func testWhatsNew() async { await snap("encore://whats-new") }
    func testHomeBellDot() async {
        XCTAssertGreaterThan(app.settings.whatsNewCount, 0)
        await snap("encore://home")
    }
    func testWhatsNewClearsDot() async {
        await snap("encore://whats-new", wait: 0.6)
        XCTAssertEqual(app.settings.whatsNewCount, 0)
    }
    func testQueueSmartShuffle() async {
        await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1", "encore://queue?smart=1", wait: 1.2)
        XCTAssertTrue(app.settings.smartShuffle.on)
        XCTAssertFalse(app.settings.smartShuffle.recIds.isEmpty)
    }
}
