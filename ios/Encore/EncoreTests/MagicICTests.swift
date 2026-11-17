// Lane magic-ic (docs/compare/MAGIC-GAPS.md #2, #5, #10, #27, #28, #32, #33): Home and Recents
// moving as you play and like, offline Home and Library, Library view state kept across
// launches, Home's Music chip and "Show all", the creator sort and the playing row.
import XCTest
@testable import Encore

@MainActor
final class MagicICTests: XCTestCase {
    private func item(_ kind: String, _ id: String) -> ShelfItem { ShelfItem(kind: kind, id: id, title: id, explicit: false) }
    private func shortcuts(_ ids: [String]) -> Shelf {
        Shelf(id: "shortcuts", title: "", layout: .shortcuts, source: "local", items: ids.map { item($0 == "liked" ? "liked" : "playlist", $0) })
    }
    private func song(_ id: String) -> SongItem { SongItem(videoId: id, title: "Song \(id)", artists: "A") }

    private func suite() -> UserDefaults {
        let name = "magic-ic-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    // MARK: #2 Home and Recents react

    func testStartingAContextMovesItsTileFirst() {
        let s = [shortcuts(["liked", "A", "B", "C"])]
        let out = HomeStore.bumped(s, context: item("playlist", "C"))
        XCTAssertEqual(out[0].items.map(\.id), ["liked", "C", "A", "B"], "Liked Songs stays pinned first")
        XCTAssertEqual(HomeStore.bumped([shortcuts(["A", "B"])], context: item("playlist", "B"))[0].items.map(\.id), ["B", "A"])
        // A context not on Home yet comes in first and the grid stays at 8.
        let full = [shortcuts((1...8).map { "P\($0)" })]
        let more = HomeStore.bumped(full, context: item("album", "NEW"))
        XCTAssertEqual(more[0].items.count, 8)
        XCTAssertEqual(more[0].items.first?.id, "NEW")
        XCTAssertFalse(more[0].items.contains { $0.id == "P8" })
    }

    func testLikedSongsFoldsItsTwoIds() {
        let s = [shortcuts(["A", "liked"])]
        let ctx = HomeStore.shortcut(for: PlayContext(kind: .liked, id: likedPlaylistId, title: "Liked Songs"), thumbnail: nil)!
        let out = HomeStore.bumped(s, context: ctx)
        XCTAssertEqual(out[0].items.map(\.id), ["liked", "A"], "the core's own tile moves, no duplicate")
    }

    func testCoreTouchesCountForRecents() {
        let lib = LibraryStore(core: MockCoreClient())
        lib.snapshot.lastPlayed = ["PL": 10]
        lib.snapshot.lastTouched = ["PL": 500]
        XCTAssertEqual(lib.recentsKey("PL"), 500)
    }

    func testLoosePlaysAreNoShortcut() {
        XCTAssertNil(HomeStore.shortcut(for: PlayContext(kind: .search, id: nil, title: "q"), thumbnail: nil))
        XCTAssertNil(HomeStore.shortcut(for: PlayContext(kind: .song, id: nil, title: "x"), thumbnail: nil))
        XCTAssertEqual(HomeStore.shortcut(for: PlayContext(kind: .album, id: "MPRE1", title: "One"), thumbnail: "t")?.kind, "album")
    }

    func testPlayingASongBumpsRecentlyPlayed() {
        let rp = Shelf(id: "recently_played", title: "Recently played", layout: .cards, source: "local",
                       items: ["a", "b"].map { ShelfItem(kind: "song", id: $0, title: $0, explicit: false, song: song($0)) })
        XCTAssertEqual(HomeStore.bumped([rp], song: song("b"))[0].items.map(\.id), ["b", "a"])
        XCTAssertEqual(HomeStore.bumped([rp], song: song("z"))[0].items.map(\.id), ["z", "a", "b"])
    }

    func testPlayMovesHomeAndRecentsAtOnce() async {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        await app.home.load { false }
        let tiles = app.home.shelves.first { $0.layout == .shortcuts }!.items
        let last = tiles.last!
        app.player.play([song("x")], at: 0, context: PlayContext(kind: .playlist, id: last.id, title: last.title))
        let now = app.home.shelves.first { $0.layout == .shortcuts }!.items
        XCTAssertEqual(now[tiles.first?.kind == "liked" ? 1 : 0].id, last.id)
        let top = LibraryRows.sort(LibraryRows.all(app).filter { !$0.pinned }, .recents).first
        XCTAssertEqual(top?.id, HomeStore.key(last.id), "Recents leads with what just started")
    }

    func testLikeTouchesLikedSongsInRecents() async {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        app.library.setPinned(BrowseItem(kind: .playlist, id: likedPlaylistId, title: "Liked Songs"), false)
        app.library.toggleLike(song("fresh-like"))
        let rows = LibraryRows.sort(LibraryRows.all(app).filter { !$0.pinned }, .recents)
        XCTAssertEqual(rows.first?.id, likedPlaylistId)
    }

    func testTouchesSurviveRelaunch() {
        let d = suite()
        let a = LibraryStore(core: MockCoreClient(), prefs: d)
        a.touch("PL1", at: 123)
        XCTAssertEqual(LibraryStore(core: MockCoreClient(), prefs: d).touches["PL1"], 123)
        XCTAssertEqual(a.recentsKey("PL1", base: 50), 123)
        XCTAssertEqual(a.recentsKey("PL1", base: 200_000), 200_000)
        XCTAssertEqual(a.recentsKey("PL2", base: 1_700_000_000_000), 1_700_000_000, "milliseconds fold to seconds")
    }

    // MARK: #5 offline

    func testOfflineHomeIsYourDownloads() {
        let shelves = [
            shortcuts(["liked", "A", "B"]),
            Shelf(id: "recently_played", title: "Recently played", layout: .cards, source: "local",
                  items: ["s1", "s2"].map { ShelfItem(kind: "song", id: $0, title: $0, explicit: false) }),
            Shelf(id: "yt:0", title: "Quick picks", layout: .songs, source: "youtube", items: [item("song", "y")]),
        ]
        let dl = [DownloadCollectionStatus(id: "B", kind: "playlist", title: "B", total: 3, done: 3, failed: 0, bytes: 0, addedAt: 1),
                  DownloadCollectionStatus(id: likedPlaylistId, kind: "liked", title: "Liked Songs", total: 9, done: 9, failed: 0, bytes: 0, addedAt: 2)]
        // The mock stands in for the core's `offline_shelves` (crates/core/src/smart/home.rs).
        let off = MockCoreClient.offlineShelves(shelves, downloads: dl, done: ["s2"])
        XCTAssertEqual(off.map(\.id), ["offline", "shortcuts", "downloaded", "recently_played"])
        XCTAssertEqual(off[0].layout, .notice)
        XCTAssertEqual(off[1].items.map(\.id), ["liked", "B"])
        XCTAssertEqual(off[2].items.map(\.id), ["liked", "B"], "newest download first")
        XCTAssertEqual(off[3].items.map(\.id), ["s2"])
    }

    func testGoingOfflineOpensLibraryOnDownloadedAndBack() {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)), prefs: .some(suite()))
        app.libraryFilter = "Albums"
        var n = app.downloads.snapshot.network
        n.offline = true
        app.downloads.setNetwork(n)
        XCTAssertEqual(app.libraryFilter, "Downloaded")
        XCTAssertEqual(app.viewPrefs.load().filter, "Albums", "the forced chip isn't saved")
        n.offline = false
        app.downloads.setNetwork(n)
        XCTAssertEqual(app.libraryFilter, "Albums")
    }

    func testChipPickedOfflineWins() {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)), prefs: .some(suite()))
        var n = app.downloads.snapshot.network
        n.offline = true
        app.downloads.setNetwork(n)
        app.libraryFilter = "Artists"
        n.offline = false
        app.downloads.setNetwork(n)
        XCTAssertEqual(app.libraryFilter, "Artists")
        XCTAssertEqual(app.viewPrefs.load().filter, "Artists")
    }

    // MARK: #10 Library view state

    func testLibraryViewStateSurvivesRelaunch() {
        let d = suite()
        let a = AppModel(core: MockCoreClient(), prefs: .some(d))
        a.librarySort = .alphabetical           // All's sort
        a.libraryFilter = "Playlists"
        a.librarySort = .custom                 // Playlists' own sort
        a.librarySubFilter = "By you"
        a.libraryGrid = true
        let b = AppModel(core: MockCoreClient(), prefs: .some(d))
        XCTAssertEqual(b.libraryFilter, "Playlists")
        XCTAssertEqual(b.librarySubFilter, "By you")
        XCTAssertTrue(b.libraryGrid)
        XCTAssertEqual(b.librarySort, .custom)
        b.libraryFilter = nil
        XCTAssertEqual(b.librarySort, .alphabetical, "each chip remembers its own sort")
        b.libraryFilter = "Albums"
        XCTAssertEqual(b.librarySort, .recents)
    }

    func testCustomOrderOnlyForPlaylists() {
        let a = AppModel(core: MockCoreClient(), prefs: .some(suite()))
        a.librarySorts["Albums"] = .custom
        a.libraryFilter = "Albums"
        XCTAssertEqual(a.librarySort, .recents)
    }

    func testMockDoesNotPersistByDefault() {
        XCTAssertNil(AppModel.defaultPrefs(for: MockCoreClient()))
    }

    // MARK: #28 Music chip

    func testMusicChipDropsPodcasts() {
        let shelves = [
            Shelf(id: "shortcuts", title: "", layout: .shortcuts, source: "local", items: [item("playlist", "A"), item("podcast", "P")]),
            Shelf(id: "yt:podcasts", title: "Podcasts for you", layout: .cards, source: "youtube", items: [item("playlist", "x")]),
            Shelf(id: "eps", title: "Episodes", layout: .cards, source: "youtube", items: [item("episode", "e")]),
            Shelf(id: "yt:1", title: "Albums", layout: .cards, source: "youtube", items: [item("album", "b")]),
        ]
        let m = HomeStore.musicOnly(shelves)
        XCTAssertEqual(m.map(\.id), ["shortcuts", "yt:1"])
        XCTAssertEqual(m[0].items.map(\.id), ["A"])
    }

    // MARK: #33 creator

    func testCreatorOf() {
        XCTAssertEqual(creatorOf("Album • Daft Punk • 2001"), "Daft Punk")
        XCTAssertEqual(creatorOf("Playlist • Owner • 12 songs"), "Owner")
        XCTAssertEqual(creatorOf("Single • Justice"), "Justice")
        XCTAssertEqual(creatorOf("Daft Punk"), "Daft Punk")
        XCTAssertEqual(creatorOf("1.2M views • Someone"), "Someone")
        XCTAssertEqual(creatorOf(nil), "")
    }

    func testOwnPlaylistsUseYourName() async {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        XCTAssertEqual(app.localUser, "You")
        app.settings.values[SettingKey.youtubeAccount] = "Sam"
        let own = LibraryRows.all(app).first { $0.byYou && $0.row == .collection && $0.id != likedPlaylistId }
        XCTAssertEqual(own?.subtitle, "Playlist • Sam")
        XCTAssertEqual(own?.creator, "Sam")
        // Saved albums sort by their artist, not by the word "Album".
        let album = LibraryRows.all(app).first { $0.kind == .album }
        XCTAssertNotEqual(album?.creator.lowercased(), "album")
        XCTAssertFalse(album?.creator.isEmpty ?? true)
    }
}
