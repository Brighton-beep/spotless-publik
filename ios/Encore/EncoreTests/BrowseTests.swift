// Stream ios-sync2: Search › Browse (Charts, New releases, genre pages) and Appears on, on the mock
// (the desktop's fixtures), the new account arms on the real core signed out (no network), and
// snapshots of the new screens.
import XCTest
@testable import Encore
import EncoreCore

final class BrowseTests: XCTestCase {
    private let mock = MockCoreClient(bundle: Bundle(for: AppModel.self))

    func testChartsDecodeTheDesktopsCapture() async throws {
        let c = try await mock.getCharts(country: nil)
        XCTAssertEqual(c.country?.code, "US")
        XCTAssertEqual(c.featured.count, 3)
        let artists = try XCTUnwrap(c.sections.first { $0.kind == "top_artists" })
        XCTAssertEqual(artists.items.first?.rank, 1)
        XCTAssertEqual(artists.items.first?.trend, "neutral")
        XCTAssertEqual(artists.items.first?.item.kind, .artist)
        let picked = try await mock.getCharts(country: "gb")
        XCTAssertEqual(picked.country?.code, "GB")
    }

    func testNewReleasesAndGenrePagesDecode() async throws {
        let n = try await mock.getNewReleases()
        XCTAssertNotNil(n.mix)
        XCTAssertEqual(n.sections.first?.title, "Albums & singles")
        XCTAssertFalse(n.sections.first?.items.isEmpty ?? true)
        let g = try await mock.getBrowseSections(browseId: moodsCategoryId, params: "x")
        XCTAssertEqual(g.title, "Chill")
        XCTAssertFalse(g.sections.isEmpty)
    }

    func testAppearsOnAnswers() async throws {
        let items = try await mock.getArtistAppearsOn(id: "UCRr1xG_2WIDs18a6cIiCxeA", songsId: "VLx")
        XCTAssertFalse(items.isEmpty)
    }

    /// The account and browse arms answer through the real bridge. Signed out: no account rows,
    /// an empty index, and account writes refused at once (no request goes out).
    func testRealCoreAccountArmsSignedOut() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sync2-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let core = try RealCoreClient(config: CoreConfig(dataDir: data.path, cacheDir: cache.path, exportDir: base.path),
                                      secrets: KeychainStore(service: "app.encore.ios.test"))
        let rows = try await core.getLibrary()
        XCTAssertEqual(rows, [], "Liked Songs, Your Rotation and this phone's playlists are left out")
        let albums = try await core.getLibraryAlbums()
        XCTAssertEqual(albums, [])
        let subs = try await core.getLibrarySubscriptions()
        XCTAssertEqual(subs, [])
        let artists = try await core.getLibraryArtists()
        XCTAssertEqual(artists, [])
        let index = try await core.playlistIndex()
        XCTAssertEqual(index, [:])
        let synced = try await core.syncPlaylistIndex()
        XCTAssertEqual(synced, [:])
        let readOnly = try await core.readonlyPlaylists()
        XCTAssertEqual(readOnly, [])
        do { _ = try await core.createPlaylist(title: "Nope"); XCTFail("needs an account") } catch {}
        do { _ = try await core.addToPlaylist(playlistId: "VLPLx", videoId: "v"); XCTFail("needs an account") } catch {}
        do { try await core.subscribe(channelId: "UCx", subscribed: true); XCTFail("needs an account") } catch {}
        // A playlist on this phone still edits through the same routing.
        let pl = try await core.createPlaylist(name: "Mine")
        try await core.markSynced(ids: [pl.id])
        try await core.updatePlaylist(id: pl.id, name: "Mine 2", description: nil)
        let renamed = try await core.librarySnapshot().playlists.first { $0.id == pl.id }?.name
        XCTAssertEqual(renamed, "Mine 2")
    }
    // MARK: Your Mix (stream ios-dailymix)

    /// A Home "Your Mix" tile opens the mix page (not a playlist page), and both cores answer
    /// `smart_mix`: the mock with songs, the real bridge (fresh, no listening) with none, offline.
    @MainActor func testDailyMixTileOpensTheMixPage() async throws {
        let r = Router()
        let tile = ShelfItem(kind: "daily_mix", id: "dailymix:a,b", title: "Your Mix 1", subtitle: "A, B and more", explicit: false)
        r.open(homeBrowseItem(tile))
        XCTAssertEqual(r.paths[.home], [.dailyMix("dailymix:a,b", "Your Mix 1", "A, B and more", nil)])
        r.open(BrowseItem(kind: .playlist, id: "MFY_DAILY_1", title: "Your Mix 1"))
        XCTAssertEqual(r.paths[.home]?.last, .playlist("MFY_DAILY_1"), "Made for you's stored mixes stay playlists")
        XCTAssertEqual(HomeStore.shortcut(for: PlayContext(kind: .dailyMix, id: "dailymix:a,b", title: "Your Mix 1"), thumbnail: nil)?.kind,
                       "daily_mix", "a played mix comes back as a Home shortcut the router opens the same way")

        let songs = try await mock.smartMix(id: "dailymix:mock1a,mock1b", size: nil)
        XCTAssertEqual(songs.count, 25)
        try await mock.playPlaylist(items: songs, start: 0, context: PlayContext(kind: .dailyMix, id: "dailymix:mock1a,mock1b", title: "Your Mix 1"), shuffle: false)
        let q = try await mock.getQueue()
        XCTAssertNil(q.sourceId, "no source id for a mix, as the real core gets it")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dailymix-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let core = try RealCoreClient(config: CoreConfig(dataDir: data.path, cacheDir: cache.path, exportDir: base.path),
                                      secrets: KeychainStore(service: "app.encore.ios.test"))
        let real = try await core.smartMix(id: "dailymix:nobody", size: 20)
        XCTAssertEqual(real, [])
        do { _ = try await core.smartMix(id: "VLPLx", size: nil); XCTFail("not a mix") } catch let e as CoreFailure {
            XCTAssertFalse(e.message.contains("unknown command"), e.message)
        }
    }

}

final class BrowseSnapshotTests: SnapshotCase {
    func testSearchBrowse() async { await snap("encore://search", wait: 1.5) }
    func testCharts() async { await snap("encore://charts", wait: 1.5) }
    func testNewReleases() async { await snap("encore://new-releases", wait: 1.5) }

    /// Signed in: the account's playlists in Your Library, yours marked "Playlist • <you>".
    func testLibraryWithYouTubeAccount() async {
        await snap("encore://library?filter=Playlists&sort=alphabetical", setup: { app in
            _ = try? await app.account.complete(with: [HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SAPISID", .value: "s"])!])
            for _ in 0..<40 where app.account.youtube.playlists.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        }, wait: 1.5)
    }
}
