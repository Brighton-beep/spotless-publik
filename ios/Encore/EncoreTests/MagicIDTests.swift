// Lane I-D (magic gaps 23, 29, 30): the shared row swipe, greyed rows that say why, and the
// shared title marquee. Pure rules, the app model on the mock core, and search snapshots.
import XCTest
@testable import Encore

final class MagicIDRuleTests: XCTestCase {
    private func r(unavailable: Bool = false, offline: Bool = false, mode: Bool = false, hidden: Bool = false,
                   filter: Bool = false, explicit: Bool = false, skip: String? = nil) -> RowBlock? {
        RowBlock.resolve(unavailable: unavailable, offline: offline, offlineMode: mode, hidden: hidden,
                         explicitFilter: filter, explicit: explicit, skipReason: skip)
    }

    /// #29: the reason, in the core's order (unavailable, offline, hidden, explicit, then the queue's).
    func testBlockReasonOrder() {
        XCTAssertNil(r())
        XCTAssertNil(r(explicit: true), "explicit with the filter off plays")
        XCTAssertEqual(r(filter: true, explicit: true), .explicit)
        XCTAssertEqual(r(hidden: true, filter: true, explicit: true), .hidden, "hidden wins over explicit")
        XCTAssertEqual(r(offline: true, hidden: true), .offline, "offline wins over hidden")
        XCTAssertEqual(r(offline: true, mode: true), .offlineMode, "offline because the user turned Offline mode on")
        XCTAssertEqual(r(unavailable: true, offline: true), .unavailable)
        XCTAssertEqual(r(skip: "explicit"), .explicit, "the core learned the flag (smart_explicit)")
        XCTAssertEqual(r(skip: "hidden"), .hidden)
        XCTAssertEqual(r(skip: "offline"), .offline)
        XCTAssertEqual(r(mode: true, skip: "offline"), .offlineMode)
        XCTAssertEqual(r(skip: "region"), .unavailable, "an unknown reason still says something")
    }

    /// #29: every reason has words; the fixable ones carry the way out.
    func testBlockReasonActions() {
        let all: [RowBlock] = [.unavailable, .offline, .offlineMode, .hidden, .explicit]
        for b in all { XCTAssertFalse(b.message.isEmpty) }
        XCTAssertEqual(RowBlock.hidden.action, "Unhide")
        XCTAssertEqual(RowBlock.explicit.action, "Settings")
        XCTAssertEqual(RowBlock.explicit.settingsPage, .contentDisplay)
        XCTAssertEqual(RowBlock.offlineMode.action, "Settings")
        XCTAssertEqual(RowBlock.offlineMode.settingsPage, .dataSaver)
        XCTAssertNil(RowBlock.offline.action, "no switch fixes a lost connection")
        XCTAssertNil(RowBlock.unavailable.action)
    }

    /// #23: commit at a third of the row (96 pt at least); past it the row moves at 30 %.
    func testRowSwipeThresholdAndRubberBand() {
        XCTAssertEqual(RowSwipe.threshold(width: 402), 150.75)
        XCTAssertEqual(RowSwipe.threshold(width: 200), 96)
        XCTAssertEqual(RowSwipe.damped(50, threshold: 134), 50)
        XCTAssertEqual(RowSwipe.damped(-50, threshold: 134), -50)
        XCTAssertEqual(RowSwipe.damped(234, threshold: 134), 164, accuracy: 0.001)
        XCTAssertEqual(RowSwipe.damped(-234, threshold: 134), -164, accuracy: 0.001)
    }

    /// #30: scrolls only when it overflows and Reduce Motion is off; 30 pt/s over title + gap.
    func testMarqueeRules() {
        XCTAssertFalse(Marquee.scrolls(text: 200, box: 300, reduceMotion: false), "fits: plain text")
        XCTAssertFalse(Marquee.scrolls(text: 300.4, box: 300, reduceMotion: false), "rounding slack")
        XCTAssertTrue(Marquee.scrolls(text: 420, box: 300, reduceMotion: false))
        XCTAssertFalse(Marquee.scrolls(text: 420, box: 300, reduceMotion: true), "Reduce Motion truncates")
        XCTAssertFalse(Marquee.scrolls(text: 420, box: 0, reduceMotion: false), "not laid out yet")
        XCTAssertEqual(Marquee.glide(text: 252), 10, accuracy: 0.001)
    }
}

@MainActor
final class MagicIDModelTests: XCTestCase {
    private var app: AppModel!

    override func setUp() async throws {
        app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
    }

    private let song = SongItem(videoId: "52fNscjkST4", title: "Aerodynamic", artists: "Daft Punk", albumId: nil,
                                duration: "3:33", thumbnail: nil, explicit: false)

    private func waitToast(_ text: String) async -> ToastMessage? {
        for _ in 0..<40 {
            if let t = app.toast, t.text == text { return t }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return app.toast
    }

    /// #29: a hidden song is greyed; its tap toasts the reason, and Unhide brings it back.
    func testHiddenRowExplainsAndUnhides() async throws {
        XCTAssertNil(app.rowBlock(song))
        try await app.core.setHidden(song, hidden: true)
        await app.library.refresh()
        XCTAssertEqual(app.rowBlock(song), .hidden)
        app.explain(.hidden, song)
        let t = await waitToast(RowBlock.hidden.message)
        XCTAssertEqual(t?.text, "You hid this song")
        XCTAssertEqual(t?.action, "Unhide")
        t?.run?()
        _ = await waitToast("Song unhidden")
        XCTAssertNil(app.rowBlock(song), "Unhide makes it playable again")
    }

    /// #29: explicit filter on: the toast's Settings opens Content and display.
    func testExplicitRowOpensSettings() {
        var e = song
        e.explicit = true
        XCTAssertNil(app.rowBlock(e))
        app.settings.smart.explicitFilter = true
        XCTAssertEqual(app.rowBlock(e), .explicit)
        app.explain(.explicit, e)
        XCTAssertEqual(app.toast?.action, "Settings")
        app.toast?.run?()
        XCTAssertEqual(app.router.paths[app.router.tab]?.suffix(2), [.settings, .settingsPage(.contentDisplay)])
    }

    /// #29: offline and not downloaded: greyed with the connection reason.
    func testOfflineRowReason() {
        app.downloads.snapshot.network.online = false
        app.downloads.snapshot.network.offline = true
        XCTAssertEqual(app.rowBlock(song), .offline)
        app.downloads.snapshot.network.offlineMode = true
        XCTAssertEqual(app.rowBlock(song), .offlineMode)
    }
}

final class MagicIDSnapshotTests: SnapshotCase {
    /// #29: search results with a hidden song greyed, and the toast its tap raises.
    func testSearchGreyedRowToast() async {
        await snap("encore://search?q=daft%20punk", setup: { app in
            let s = SongItem(videoId: "52fNscjkST4", title: "Aerodynamic", artists: "Daft Punk", albumId: nil,
                             duration: "3:33", thumbnail: nil, explicit: false)
            try? await app.core.setHidden(s, hidden: true)
            await app.library.refresh()
            app.explain(.hidden, s)
        }, wait: 1.5)
    }
}
