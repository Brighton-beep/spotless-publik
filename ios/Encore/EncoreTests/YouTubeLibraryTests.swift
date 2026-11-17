// Stream ios-sync2: the YouTube account's library and playlist edits on the iPhone, on the mock
// core (nobody may sign in for real). Signed out nothing changes; signed in, Your Library lists the
// account's playlists, Save / Follow reach the account, and edits to a playlist you own there go
// to YouTube: add (Add to playlist, New playlist), remove with Undo, Edit's reorder, rename, delete.
import XCTest
@testable import Encore

@MainActor
final class YouTubeLibraryTests: XCTestCase {
    private var core: MockCoreClient!
    private var app: AppModel!
    private let owned = MockYouTubeState.ownedId
    private let saved = MockYouTubeState.savedId

    override func setUp() async throws {
        core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        app = AppModel(core: core)
        await app.start()
    }

    private func signIn() async throws {
        _ = try await app.account.complete(with: [HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SAPISID", .value: "s"])!])
        await eventually { self.app.account.youtube.loaded && !self.app.account.youtube.playlists.isEmpty }
    }

    /// Fails the test unless `ok` turns true within a few seconds.
    private func eventually(_ message: String = "", _ ok: () async -> Bool) async {
        let r = await until(4, ok)
        XCTAssertTrue(r, message)
    }

    private func until(_ timeout: Double = 4, _ ok: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if await ok() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return false
    }

    private func toast(_ text: String) async -> ToastMessage? {
        var hit: ToastMessage?
        _ = await until { hit = self.app.toast.flatMap { $0.text.contains(text) ? $0 : nil }; return hit != nil }
        return hit
    }

    private func ytItems(_ id: String) async throws -> [SongItem] { try await core.getPlaylist(id: id).items }

    // MARK: pure

    func testAccountRowsLeaveOutWhatTheSnapshotAlreadyHas() {
        XCTAssertTrue(YouTubeLibrary.isAccountRow(BrowseItem(kind: .playlist, id: "VLPL1", title: "")))
        for id in [likedPlaylistId, "LIMUSIC_ON_REPEAT", "LOCALPLAYLIST:3"] {
            XCTAssertFalse(YouTubeLibrary.isAccountRow(BrowseItem(kind: .playlist, id: id, title: "")), id)
        }
        XCTAssertFalse(YouTubeLibrary.isAccountRow(BrowseItem(kind: .album, id: "MPRE1", title: "")))
    }

    func testReorderPlanMovesOnlyRowsOutOfPlace() {
        XCTAssertTrue(playlistMoves(from: ["a", "b", "c"], to: ["a", "b", "c"]).isEmpty)
        let m = playlistMoves(from: ["a", "b", "c", "d"], to: ["c", "a", "b", "d"])
        XCTAssertEqual(m.map(\.0), ["c"]); XCTAssertEqual(m.map(\.1), ["a"])
        // Removed rows are simply not in the target.
        XCTAssertEqual(playlistMoves(from: ["a", "b", "c"], to: ["c", "a"]).map(\.0), ["c"])
    }

    func testPickerCountReadsYouTubesLine() {
        XCTAssertEqual(AddToPlaylistSheet.count("Test Listener • 6 tracks"), "6 songs")
        XCTAssertEqual(AddToPlaylistSheet.count("Me • 1 track"), "1 song")
        XCTAssertEqual(AddToPlaylistSheet.count("Me • 1,204 songs"), "1204 songs")
        XCTAssertEqual(AddToPlaylistSheet.count(nil), "Playlist")
    }

    // MARK: signed out / in

    func testSignedOutNothingFromTheAccount() async {
        XCTAssertFalse(app.account.youtube.loaded)
        XCTAssertFalse(LibraryRows.all(app).contains { $0.id == owned })
        XCTAssertFalse(app.isOwnPlaylist(owned))
        XCTAssertTrue(app.isOwnPlaylist("LOCALPLAYLIST:1"))
    }

    func testSignInListsTheAccountsPlaylistsAndSignOutDropsThem() async throws {
        try await signIn()
        let rows = LibraryRows.all(app)
        let mine = try XCTUnwrap(rows.first { $0.id == owned })
        XCTAssertTrue(mine.byYou)
        XCTAssertEqual(mine.subtitle, "Playlist • Test Listener")
        let theirs = try XCTUnwrap(rows.first { $0.id == saved })
        XCTAssertFalse(theirs.byYou)
        XCTAssertEqual(theirs.subtitle, "Playlist • Jazz Radio")
        XCTAssertTrue(app.isOwnPlaylist(owned))
        XCTAssertFalse(app.isOwnPlaylist(saved))
        // Only your own, editable ones are offered as targets.
        XCTAssertEqual(app.account.youtube.editable.map(\.id), [owned])
        XCTAssertEqual(app.account.youtube.readOnly, [saved])
        try await app.account.signOut()
        XCTAssertFalse(app.account.youtube.loaded)
        XCTAssertFalse(LibraryRows.all(app).contains { $0.id == owned })
    }

    // MARK: save, follow, like

    func testSaveAndFollowReachTheAccount() async throws {
        try await signIn()
        let albumFound = try await core.searchAll(query: "radiohead", recordHistory: false).albums.first { !self.app.library.isSaved($0.id) }
        let album = try XCTUnwrap(albumFound)
        XCTAssertFalse(app.inLibrary(album))
        XCTAssertTrue(app.toggleInLibrary(album))
        let pidFound = try await core.getAlbum(id: album.id).playlistId
        let pid = try XCTUnwrap(pidFound)
        await eventually { self.core.withLock { self.core.fs.yt.likedPlaylists.contains(pid) } }
        await eventually("marked synced") { self.core.withLock { self.core.fs.yt.synced.contains(album.id) } }
        XCTAssertTrue(app.library.isSaved(album.id), "the row on this phone too")

        let artist = BrowseItem(kind: .artist, id: "UCRr1xG_2WIDs18a6cIiCxeA", title: "Daft Punk")
        app.toggleInLibrary(artist)
        let channel = try await core.getArtist(id: artist.id).channelId
        await eventually { self.core.withLock { self.core.fs.yt.subscribed.contains(channel) } }
        XCTAssertTrue(app.inLibrary(artist))
        // Unfollow takes it back out on both sides.
        await eventually { self.app.library.isSaved(artist.id) }
        XCTAssertFalse(app.toggleInLibrary(artist))
        await eventually { !self.core.withLock { self.core.fs.yt.subscribed.contains(channel) } }
    }

    func testSavingSignedOutStaysOnThisPhone() async throws {
        let albumFound = try await core.searchAll(query: "radiohead", recordHistory: false).albums.first { !self.app.library.isSaved($0.id) }
        let album = try XCTUnwrap(albumFound)
        app.toggleInLibrary(album)
        await eventually { self.app.library.isSaved(album.id) }
        XCTAssertTrue(core.withLock { core.fs.yt.likedPlaylists.isEmpty })
    }

    func testALikeIsMirroredToTheAccount() async throws {
        try await signIn()
        let songFound = try await ytItems(saved).first
        let song = try XCTUnwrap(songFound)
        let first: Rating = app.library.isLiked(song.videoId) ? .indifferent : .like
        app.library.toggleLike(song)
        await eventually { self.core.withLock { self.core.fs.yt.ratings[song.videoId] == first } }
        app.library.toggleLike(song)
        await eventually { self.core.withLock { self.core.fs.yt.ratings[song.videoId] == (first == .like ? .indifferent : .like) } }
    }

    // MARK: playlist edits

    func testAddToPlaylistWritesToTheAccountAndMarksSavedIn() async throws {
        try await signIn()
        let songFound = try await ytItems(saved).first
        let song = try XCTUnwrap(songFound)
        let ok = await AddToPlaylistSave.apply(app, songs: [song], added: [owned], removed: [], names: [owned: "Road Trip"])
        XCTAssertTrue(ok)
        let afterAdd = try await ytItems(owned)
        XCTAssertTrue(afterAdd.contains { $0.videoId == song.videoId })
        XCTAssertEqual(app.account.youtube.index[song.videoId], [owned])
        // Unticking takes it out again (found by its setVideoId).
        let removed = await AddToPlaylistSave.apply(app, songs: [song], added: [], removed: [owned], names: [:])
        XCTAssertTrue(removed)
        let afterRemove = try await ytItems(owned)
        XCTAssertFalse(afterRemove.contains { $0.videoId == song.videoId })
        XCTAssertEqual(app.account.youtube.index[song.videoId], [])
    }

    func testNewPlaylistGoesOnTheAccountWhenSignedIn() async throws {
        try await signIn()
        let songFound = try await ytItems(saved).first
        let song = try XCTUnwrap(songFound)
        let created = await AddToPlaylistSave.create(app, name: "Gym", songs: [song])
        XCTAssertTrue(created)
        let row = try XCTUnwrap(app.account.youtube.playlists.first { $0.title == "Gym" })
        XCTAssertTrue(app.account.youtube.owns(row.id))
        let items = try await ytItems(row.id)
        XCTAssertEqual(items.map(\.videoId), [song.videoId])
        let t = await toast("Added to Gym")
        XCTAssertNotNil(t)
    }

    func testRemoveFromAccountPlaylistUndoPutsItBackInPlace() async throws {
        try await signIn()
        let before = try await ytItems(owned)
        let victim = before[2]
        PlaylistUndo.remove(app, song: victim, playlistId: owned, playlistName: "Road Trip")
        let removedToast = await toast("Removed from Road Trip")
        let t = try XCTUnwrap(removedToast)
        let gone = try await ytItems(owned)
        XCTAssertFalse(gone.contains { $0.videoId == victim.videoId })
        t.run?()
        await eventually { (try? await self.ytItems(self.owned).map(\.videoId)) == before.map(\.videoId) }
    }

    func testRenameAndDeleteAnAccountPlaylist() async throws {
        try await signIn()
        try await app.core.updatePlaylist(id: owned, name: "Road Trip 2", description: nil)
        let renamed = try await core.getPlaylist(id: owned).title
        XCTAssertEqual(renamed, "Road Trip 2")
        confirmDeletePlaylist(app, id: owned, name: "Road Trip 2")
        XCTAssertEqual(app.confirm?.message, "It will be deleted from your YouTube account too.")
        app.confirm?.run()
        let deletedToast = await toast("Deleted Road Trip 2")
        let t = try XCTUnwrap(deletedToast)
        XCTAssertNil(t.action, "no Undo for a playlist deleted from YouTube")
        XCTAssertFalse(app.account.youtube.playlists.contains { $0.id == owned })
        XCTAssertFalse(core.withLock { core.fs.yt.playlists.contains { $0.card.id == owned } })
    }

    func testEditsStampTheAccountPlaylistSoItsPageReloads() async throws {
        try await signIn()
        let songFound = try await ytItems(saved).first
        let song = try XCTUnwrap(songFound)
        try await app.core.addToPlaylist(id: owned, songs: [song])
        await eventually { self.app.library.snapshot.lastTouched?[self.owned] != nil }
    }

    func testReorderThroughTheClientMatchesTheTarget() async throws {
        try await signIn()
        let rows = try await ytItems(owned).compactMap(\.setVideoId)
        let target = [rows[3], rows[0], rows[1], rows[2]] + rows.dropFirst(4)
        try await core.reorderYouTubePlaylist(owned, from: rows, to: target)
        let now = try await ytItems(owned).compactMap(\.setVideoId)
        XCTAssertEqual(now, target)
    }

    func testThisPhonesPlaylistsStillUseTheLocalCommands() async throws {
        try await signIn()
        let songFound = try await ytItems(saved).first
        let song = try XCTUnwrap(songFound)
        try await app.core.addToPlaylist(id: "LOCALPLAYLIST:1", songs: [song])
        let local = try await core.getPlaylist(id: "LOCALPLAYLIST:1").items
        XCTAssertTrue(local.contains { $0.videoId == song.videoId })
        let account = try await ytItems(owned)
        XCTAssertFalse(account.contains { $0.videoId == song.videoId })
    }
}
