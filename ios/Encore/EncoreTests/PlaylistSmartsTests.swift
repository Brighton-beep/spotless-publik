// Stream magic-ib (I-B2): Liked Songs chips, Enhance's interleave and rows, on the mock core.
import XCTest
@testable import Encore

@MainActor
final class PlaylistSmartsTests: XCTestCase {
    private func s(_ id: String) -> SongItem { SongItem(videoId: id, title: "T\(id)", artists: "A") }

    func testInterleaveOneSuggestionEveryTwoSongs() {
        let out = PlaylistSmarts.interleave(["1", "2", "3", "4", "5"].map(s), ["a", "b", "c"].map(s))
        XCTAssertEqual(out.map(\.videoId), ["1", "2", "a", "3", "4", "b", "5"])
        XCTAssertEqual(PlaylistSmarts.interleave([s("1")], [s("a")]).map(\.videoId), ["1"])
    }

    func testRowsChipsAndEnhance() {
        let m = PlaylistSmarts()
        let list = ["1", "2", "3", "4"].map(s)
        m.enhance = EnhanceState(playlistId: "P", on: true, recs: [s("a"), s("b")], at: 0)
        let rows = m.rows(list, query: "")
        // Never a suggestion after the last song (the core's `interleave`; stream ios-sync2).
        XCTAssertEqual(rows.map(\.song.videoId), ["1", "2", "a", "3", "4"])
        XCTAssertEqual(rows.filter(\.suggestion).map(\.index), [2])
        // A find query hides Enhance; rows keep their index into what Play queues.
        let found = m.rows(list, query: "T3")
        XCTAssertEqual(found.map(\.song.videoId), ["3"])
        XCTAssertEqual(found.first?.index, 2)
        // A chip filters and also hides Enhance; Play queues the chip's set.
        m.chips = LikedChips(chips: [SmartChip(label: "Rock", kind: .genre, videoIds: ["2", "4"])], done: 4, total: 4)
        m.chip = "Rock"
        XCTAssertEqual(m.queue(list, finding: false).map(\.videoId), ["2", "4"])
        XCTAssertFalse(m.enhanceActive(finding: false))
        m.chip = "Gone"
        XCTAssertEqual(m.base(list).count, 4, "an unknown chip filters nothing")
    }

    func testMockFlow() async throws {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        let m = PlaylistSmarts()
        let load = Task { await m.loadChips(app) }
        try await Task.sleep(for: .milliseconds(300))
        load.cancel()
        XCTAssertFalse(m.chips.chips.isEmpty, "Liked Songs gets chips")
        await m.loadEnhance(app, id: "LOCALPLAYLIST:8")
        XCTAssertEqual(m.enhance?.on, false)
        await m.toggleEnhance(app, id: "LOCALPLAYLIST:8", length: 9)
        XCTAssertEqual(m.enhance?.on, true)
        let first = try XCTUnwrap(m.enhance?.recs.first)
        await m.keep(app, id: "LOCALPLAYLIST:8", song: first, liked: false, title: "Robot Rock")
        XCTAssertFalse(m.enhance?.recs.contains(first) ?? true)
        let page = try await app.core.getPlaylist(id: "LOCALPLAYLIST:8")
        XCTAssertTrue(page.items.contains { $0.videoId == first.videoId }, "+ adds the suggestion to the playlist")
        let second = try XCTUnwrap(m.enhance?.recs.first)
        await m.remove(app, id: "LOCALPLAYLIST:8", song: second)
        XCTAssertFalse(m.enhance?.recs.contains(second) ?? true)
        await m.toggleEnhance(app, id: "LOCALPLAYLIST:8", length: 9)
        XCTAssertEqual(m.enhance?.on, false)
    }
}

final class PlaylistSmartsSnapshotTests: SnapshotCase {
    func testLikedSongsChips() async { await snap("encore://liked", wait: 1.5) }

    func testEnhancedPlaylist() async {
        await snap("encore://playlist/LOCALPLAYLIST:8", setup: { app in
            _ = try? await app.core.enhanceSet(playlistId: "LOCALPLAYLIST:8", on: true, len: 9)
            app.router.paths[app.router.tab] = []
            try? await Task.sleep(for: .milliseconds(300))
            app.router.push(.playlist("LOCALPLAYLIST:8"))
        }, wait: 1.5)
    }
}
