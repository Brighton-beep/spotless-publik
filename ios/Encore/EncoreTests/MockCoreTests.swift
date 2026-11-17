import XCTest
@testable import Encore

/// The mock decodes every desktop fixture it serves (catches contract drift with api.ts).
final class MockCoreTests: XCTestCase {
    func testFixturesDecode() async throws {
        let core = MockCoreClient()
        XCTAssertGreaterThan(core.pool.count, 50)
        let all = try await core.searchAll(query: "daft punk", recordHistory: false)
        XCTAssertFalse(all.songs.isEmpty)
        let album = try await core.getAlbum(id: "MPREb_K8qWMWVqXGi")
        XCTAssertEqual(album.title, "Random Access Memories")
        let artist = try await core.getArtist(id: "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertFalse(artist.topSongs.isEmpty)
        let liked = try await core.getPlaylist(id: likedPlaylistId)
        XCTAssertEqual(liked.items.count, 40)
        let home = try await core.smartHome()
        XCTAssertEqual(home.first?.layout, .shortcuts)
        XCTAssertGreaterThan(home.count, 5)
        let moods = try await core.getMoods()
        XCTAssertEqual(moods.count, 2)
        let lyrics = try await core.getLyrics(videoId: "x", title: "", artists: "", duration: nil)
        XCTAssertNotNil(lyrics)
    }

    func testQueueOps() async throws {
        let core = MockCoreClient()
        let page = try await core.getPlaylist(id: "LOCALPLAYLIST:1")
        try await core.playPlaylist(items: page.items, start: 2, context: PlayContext(kind: .playlist, id: "LOCALPLAYLIST:1", title: "x"), shuffle: false)
        var q = try await core.getQueue()
        XCTAssertEqual(q.currentIndex, 2)
        try await core.addToQueue([page.items[10]], from: "x")
        q = try await core.getQueue()
        XCTAssertEqual(q.items[3].videoId, page.items[10].videoId)
        XCTAssertEqual(q.items[3].queued, true)
        try await core.nextTrack()
        q = try await core.getQueue()
        XCTAssertEqual(q.currentIndex, 3)
    }

    /// stream: autoplay. A search pick plays alone; what follows is Autoplay, not the result list.
    func testSinglePickIsFollowedByAutoplayOnly() async throws {
        let core = MockCoreClient()
        let all = try await core.searchAll(query: "daft punk", recordHistory: false)
        let pick = try XCTUnwrap(all.songs.first).asSong
        try await core.playSingle(pick, from: "daft punk")
        let q = try await core.getQueue()
        XCTAssertEqual(q.items.first?.videoId, pick.videoId)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertNil(q.sourceId, "a single pick has no context")
        XCTAssertEqual(q.sourceName, "daft punk")
        XCTAssertGreaterThan(q.items.count, 1)
        XCTAssertTrue(q.items.dropFirst().allSatisfy { $0.autoplay == true }, "only Autoplay follows")
    }
}
