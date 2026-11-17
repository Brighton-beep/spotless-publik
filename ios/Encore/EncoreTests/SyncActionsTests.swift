// Lane P1: the track and queue actions (radio page, credits, taste exclusion, playlist-remove Undo,
// clear-queue Undo, Don't play this artist). Pure helpers first, then each flow on the mock core
// through the same code the menus call, Undo toast included.
import XCTest
@testable import Encore

@MainActor
final class SyncActionsTests: XCTestCase {
    private var core: MockCoreClient!
    private var app: AppModel!

    override func setUp() async throws {
        core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        app = AppModel(core: core)
        await app.start()
        TasteExclusions.shared.reset()
        CreditsCache.shared.reset()
    }

    /// Waits for a toast whose text contains `text`, then returns it.
    private func toast(_ text: String, timeout: Double = 4) async -> ToastMessage? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let t = app.toast, t.text.contains(text) { return t }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func until(_ timeout: Double = 4, _ ok: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if await ok() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return false
    }

    // MARK: pure helpers

    func testPlaylistUndoOrderPutsRowsBack() {
        // [a b c d], b (row 2) removed → [a c d] + re-added row 9 → [a 9 c d].
        XCTAssertEqual(PlaylistUndo.order(current: [1, 3, 4, 9], restoredAt: [1]), [1, 9, 3, 4])
        // Two copies, at 0 and 3 of [x a b x c] → [a b c] + 7, 8.
        XCTAssertEqual(PlaylistUndo.order(current: [2, 3, 5, 7, 8], restoredAt: [3, 0]), [7, 2, 3, 8, 5])
        // A position past the end (unknown) appends.
        XCTAssertEqual(PlaylistUndo.order(current: [1, 2, 9], restoredAt: [Int.max]), [1, 2, 9])
        XCTAssertEqual(PlaylistUndo.order(current: [], restoredAt: [0]), [])
    }

    func testQueuedRowsAreOnlyQueuedSongsAfterCurrent() {
        func s(_ id: String, _ q: Bool) -> SongItem { var x = SongItem(videoId: id, title: id, artists: "A"); x.queued = q; return x }
        let q = QueueState(items: [s("old", true), s("cur", false), s("q1", true), s("ctx", false), s("q2", true)], currentIndex: 1)
        XCTAssertEqual(QueueUndo.queuedRows(q).map(\.videoId), ["q1", "q2"])
    }

    // Credit rows (one per person, roles merged) are the core's: `credits::tests` in Rust.

    func testBlockTargetsTheFirstBylineRun() {
        var s = SongItem(videoId: "v", title: "t", artists: "Unlinked & Linked", artistId: "UCsong")
        s.artistRuns = [ArtistRun(text: "Unlinked", id: nil), ArtistRun(text: "Linked", id: "UClinked")]
        XCTAssertEqual(ArtistBlock.artist(of: s)?.name, "Unlinked")
        XCTAssertNil(ArtistBlock.artist(of: s)?.id, "never run 1's name with another run's id")
        s.artistRuns = nil
        XCTAssertEqual(ArtistBlock.artist(of: s)?.id, "UCsong")
    }

    func testRadioSavesRoundTrip() {
        let d = UserDefaults(suiteName: "p1-radio-\(UUID())")!
        let k = RadioSaves.radioKey(kind: "song", id: "abc")
        XCTAssertNil(RadioSaves.get(k, defaults: d))
        RadioSaves.set(k, "LOCALPLAYLIST:9", defaults: d)
        XCTAssertEqual(RadioSaves.get(k, defaults: d), "LOCALPLAYLIST:9")
        RadioSaves.set(k, nil, defaults: d)
        XCTAssertNil(RadioSaves.get(k, defaults: d))
    }

    // MARK: flows on the mock core

    func testRemoveFromPlaylistUndoRestoresPosition() async throws {
        let id = "LOCALPLAYLIST:1"
        let before = try await core.playlistEntries(id: id).map(\.song)
        XCTAssertGreaterThan(before.count, 3)
        let victim = before[2]
        PlaylistUndo.remove(app, song: victim, playlistId: id, playlistName: "Mine")
        let t = await toast("Removed from Mine")
        XCTAssertEqual(t?.action, "Undo")
        let gone = try await core.playlistEntries(id: id).map(\.song.videoId)
        XCTAssertFalse(gone.contains(victim.videoId))
        t?.run?()
        let restored = await until { (try? await self.core.playlistEntries(id: id).map(\.song.videoId)) == before.map(\.videoId) }
        XCTAssertTrue(restored, "Undo puts the song back at its old position")
    }

    func testClearQueueUndoRestoresQueuedRows() async throws {
        let page = try await core.getPlaylist(id: "LOCALPLAYLIST:1")
        try await core.playPlaylist(items: page.items, start: 0, context: PlayContext(kind: .playlist, id: "LOCALPLAYLIST:1", title: "P"), shuffle: false)
        try await core.addToQueue([page.items[3], page.items[4]], from: "P")
        await app.player.refresh()
        XCTAssertEqual(QueueUndo.queuedRows(app.player.queue).count, 2)
        QueueUndo.clear(app)
        let t = await toast("Queue cleared")
        XCTAssertEqual(t?.action, "Undo")
        await app.player.refresh()
        XCTAssertTrue(QueueUndo.queuedRows(app.player.queue).isEmpty)
        t?.run?()
        let back = await until { await self.app.player.refresh(); return QueueUndo.queuedRows(self.app.player.queue).map(\.videoId) == [page.items[3].videoId, page.items[4].videoId] }
        XCTAssertTrue(back, "Undo puts the queued songs back, in order")
    }

    func testClearingAnEmptyQueueHasNoUndo() async {
        QueueUndo.clear(app)
        let t = await toast("Queue cleared", timeout: 1)
        XCTAssertNil(t)
    }

    func testTasteExcludeToggleAndUndo() async throws {
        let taste = TasteExclusions.shared
        XCTAssertFalse(taste.isExcluded("song1", core: core))
        _ = await until { taste.loaded }
        taste.toggle(app, id: "song1", kind: "song", title: "S") { ["song1"] }
        let t = await toast("Excluded from your taste profile")
        XCTAssertEqual(t?.action, "Undo")
        let stored = try await core.tasteExcluded()
        XCTAssertEqual(stored, ["song1"])
        XCTAssertTrue(taste.isExcluded("song1", core: core), "the menu label flips to Include")
        t?.run?()
        let undone = await until { ((try? await self.core.tasteExcluded()) ?? ["x"]).isEmpty && !taste.isExcluded("song1", core: self.core) }
        XCTAssertTrue(undone)
    }

    func testBlockArtistAndUndo() async throws {
        ArtistBlock.block(app, id: "UCx", name: "Some Band")
        let t = await toast("You won't hear Some Band")
        XCTAssertEqual(t?.action, "Undo")
        let blocked = try await core.blockedArtists()
        XCTAssertEqual(blocked.map(\.name), ["Some Band"])
        t?.run?()
        let undone = await until { ((try? await self.core.blockedArtists()) ?? [BlockedArtist(id: nil, name: "x")]).isEmpty }
        XCTAssertTrue(undone)
    }

    func testCreditsCacheAsksOncePerSong() async throws {
        let s = SongItem(videoId: "cc1", title: "T", artists: "Band", artistId: "UCband")
        let a = try await CreditsCache.shared.load(s, core: core)
        XCTAssertEqual(a.sections.first?.title, "Performed by")
        XCTAssertNotNil(CreditsCache.shared.cached("cc1"))
    }
}
