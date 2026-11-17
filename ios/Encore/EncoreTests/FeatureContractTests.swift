import XCTest
@testable import Encore

/// The feature half of the contract: podcast fixtures decode through the Swift models, the mock
/// follows the Rust rules the UI depends on (resume, played, Smart Shuffle, download queue), and
/// the flattened api.ts shapes round-trip.
final class FeatureContractTests: XCTestCase {
    let showId = "MPSPPLPNW_gerXa4Pc8S2qoUQc5e8Ir97RLuVW"

    func testPodcastFixturesDecode() async throws {
        let core = MockCoreClient()
        let page = try await core.podcastShow(id: showId, sort: .newest)
        XCTAssertEqual(page.show.title, "Huberman Lab")
        XCTAssertEqual(page.episodes.count, 20)
        XCTAssertTrue(page.show.followed)
        let oldest = try await core.podcastShow(id: showId, sort: .oldest)
        XCTAssertEqual(oldest.episodes.first?.id, page.episodes.last?.id)
        let search = try await core.podcastSearch(query: "huberman")
        XCTAssertEqual(search.shows.count, 20)
        XCTAssertEqual(search.episodes.count, 20)
        let ep = try await core.podcastEpisode(id: page.episodes[0].id)
        XCTAssertNotNil(ep.description)
        XCTAssertEqual(ep.song.isEpisode, true)
        let saved = try await core.podcastSavedEpisodes()
        XCTAssertEqual(saved.count, 2)
        let cont = try await core.podcastContinueListening(limit: 10)
        XCTAssertEqual(cont.count, 2)
        XCTAssertTrue(cont.allSatisfy { $0.progress.fraction > 0 && !$0.progress.played })
    }

    func testEpisodeResumesFiveSecondsEarly() async throws {
        let core = MockCoreClient()
        let ep = try await core.podcastContinueListening(limit: 1)[0]
        try await core.playPlaylist(items: [ep.song], start: 0, context: PlayContext(kind: .song, id: nil, title: ep.showTitle), shuffle: false)
        let pb = try await core.getPlayback()
        XCTAssertEqual(pb.position, ep.progress.positionSecs - 5, accuracy: 0.3)
        try await core.togglePause()
        try await core.seekRelative(15)
        let after = try await core.getPlayback()
        XCTAssertEqual(after.position, pb.position + 15, accuracy: 0.6)
        let p = try await core.podcastMarkPlayed(id: ep.id, played: true)
        XCTAssertTrue(p.played)
        XCTAssertEqual(p.fraction, 1)
    }

    func testWhatsNewFlattensEpisodes() async throws {
        let core = MockCoreClient()
        let wn = try await core.whatsNew()
        XCTAssertFalse(wn.music.isEmpty)
        XCTAssertFalse(wn.podcasts.isEmpty)
        let data = try JSONEncoder().encode(wn.podcasts[0])
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(obj["isNew"])
        XCTAssertNotNil(obj["showTitle"], "api.ts shape is PodcastEpisode & {isNew}, flat")
        let back = try JSONDecoder().decode(WhatsNewEpisode.self, from: data)
        XCTAssertEqual(back, wn.podcasts[0])
        try await core.whatsNewMarkSeen()
        let after = try await core.whatsNew()
        XCTAssertEqual(after.newCount, 0)
    }

    func testMadeForYouPlaylists() async throws {
        let core = MockCoreClient()
        let cards = try await core.madeForYou()
        XCTAssertEqual(cards.map(\.title).prefix(7), ["Your Mix 1", "Your Mix 2", "Your Mix 3", "Your Mix 4", "Your Mix 5", "Your Mix 6", "Weekly Discoveries"])
        let page = try await core.getPlaylist(id: "MFY_DAILY_1")
        XCTAssertEqual(page.items.count, 50)
        XCTAssertTrue(cards[0].thumbnail?.hasPrefix("mfy:") == true)
    }

    func testSmartShuffleOnlyInOwnPlaylists() async throws {
        let core = MockCoreClient()
        let page = try await core.getPlaylist(id: "LOCALPLAYLIST:1")
        try await core.playPlaylist(items: page.items, start: 0, context: PlayContext(kind: .playlist, id: "LOCALPLAYLIST:1", title: "x"), shuffle: false)
        let s = try await core.smartShuffleSet(true)
        XCTAssertTrue(s.on)
        XCTAssertFalse(s.recIds.isEmpty)
        let q = try await core.getQueue()
        // A suggestion after every 3 songs.
        XCTAssertEqual(q.items[4].videoId, s.recIds[0])
        let off = try await core.smartShuffleSet(false)
        XCTAssertFalse(off.on)
        let q2 = try await core.getQueue()
        XCTAssertFalse(q2.items.contains { s.recIds.contains($0.videoId) })
        let album = try await core.getAlbum(id: "MPREb_K8qWMWVqXGi")
        try await core.playPlaylist(items: album.items, start: 0, context: PlayContext(kind: .album, id: "MPREb_K8qWMWVqXGi", title: "x"), shuffle: false)
        do { _ = try await core.smartShuffleSet(true); XCTFail("albums have no Smart Shuffle") } catch {}
    }

    func testDownloadQueueAndOffline() async throws {
        let core = MockCoreClient()
        var snap = try await core.downloadsSnapshot()
        XCTAssertEqual(snap.collections.first?.id, "LOCALPLAYLIST:1", "Late Night Drive starts downloaded")
        XCTAssertEqual(snap.collections.first?.done, snap.collections.first?.total)
        try await core.downloadsAdd(DownloadCollection(id: likedPlaylistId, kind: "liked", title: "Liked Songs"), songs: nil)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        snap = try await core.downloadsSnapshot()
        let liked = snap.collections.first { $0.id == likedPlaylistId }!
        XCTAssertEqual(liked.total, 40)
        XCTAssertGreaterThan(liked.done + snap.active.count, 0)
        _ = try await core.downloadsSetSettings(DownloadSettingsPatch(offlineMode: true))
        let other = try await core.getPlaylist(id: "LOCALPLAYLIST:2")
        try await core.playPlaylist(items: other.items, start: 0, context: PlayContext(kind: .playlist, id: "LOCALPLAYLIST:2", title: "x"), shuffle: false)
        let q = try await core.getQueue()
        XCTAssertFalse((q.skipReasons ?? [:]).isEmpty)
        XCTAssertTrue((q.skipReasons ?? [:]).values.allSatisfy { $0 == "offline" })
        try await core.downloadsRemoveAll()
        snap = try await core.downloadsSnapshot()
        XCTAssertEqual(snap.count, 0)
    }

    func testSleepAndImport() async throws {
        let core = MockCoreClient()
        let s = try await core.setSleepTimer(minutes: 15, endOfTrack: false)
        XCTAssertEqual(s.mode?.kind, "at")
        XCTAssertEqual(s.remaining ?? 0, 900, accuracy: 1)
        let off = try await core.cancelSleepTimer()
        XCTAssertNil(off.mode)
        let prof = try await core.importRead(link: "https://open.spotify.com/user/someone")
        XCTAssertEqual(prof.profile?.playlists.count, 10)
        _ = try await core.importStart(lists: [0, 1])
        try await Task.sleep(nanoseconds: 3_600_000_000)
        // Matching ends in review (stream ios-import-review); Create writes and finishes.
        let review = try await core.importStatus()
        XCTAssertEqual(review?.phase, "review")
        try await core.importCreate(names: [:], local: true)
        let done = try await core.importStatus()
        XCTAssertEqual(done?.phase, "done")
        XCTAssertEqual(done?.results.count, 2)
    }
}
