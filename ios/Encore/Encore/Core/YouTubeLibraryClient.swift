// Stream ios-sync2: the signed-in YouTube account's library and playlist edits, the desktop's
// `get_library*` / `add_to_playlist` / `remove_*_from_playlist` / `move_in_playlist` /
// `create_playlist` / `edit_playlist_details` / `delete_playlist` / `subscribe` /
// `set_album_saved` / `playlist_index` / `lib_mark_synced`. Its own protocol, like `AccountClient`,
// so `CoreClient` stays as it is; both clients conform below. The store is App/YouTubeLibrary.swift.
//
// The existing playlist calls (`addToPlaylist(id:songs:)`, `removeFromPlaylist(id:videoIds:)`,
// `updatePlaylist`, `deletePlaylist`) take either kind of id: a playlist on this phone goes to the
// `lib_*` commands, one on the account comes here (`isLocalPlaylistId`), as the desktop's
// `addToOne` routes it.
import Foundation

/// A playlist kept on this phone (no account owns it).
func isLocalPlaylistId(_ id: String) -> Bool { id.hasPrefix("LOCALPLAYLIST:") }

protocol YouTubeLibraryClient: AnyObject, Sendable {
    func getLibrary() async throws -> [BrowseItem]                                              // get_library
    func getLibraryAlbums() async throws -> [BrowseItem]                                        // get_library_albums
    func getLibraryArtists() async throws -> [BrowseItem]                                       // get_library_artists
    func getLibrarySubscriptions() async throws -> [BrowseItem]                                 // get_library_subscriptions
    func subscribe(channelId: String, subscribed: Bool) async throws                            // subscribe
    /// An album's like (its `OLAK5uy_…` audio playlist) or a saved playlist's.
    func setAlbumSaved(playlistId: String, saved: Bool) async throws                            // set_album_saved
    /// videoId → your own playlists holding it (no network).
    func playlistIndex() async throws -> [String: [String]]                                     // playlist_index
    /// Re-crawl your playlists when the index is stale, then answer it.
    func syncPlaylistIndex() async throws -> [String: [String]]                                 // sync_playlist_index
    /// Library playlists you can't edit (saved from someone else).
    func readonlyPlaylists() async throws -> [String]                                           // readonly_playlists
    /// A new playlist on the account (`local: false`); answers its id.
    func createPlaylist(title: String) async throws -> String                                   // create_playlist
    /// `public`: true / false sets who can see it on YouTube (nil leaves it).
    func editPlaylistDetails(playlistId: String, name: String?, description: String?, public: Bool?) async throws // edit_playlist_details
    func deletePlaylist(playlistId: String) async throws                                        // delete_playlist
    /// False when YouTube already had it (nothing added).
    func addToPlaylist(playlistId: String, videoId: String) async throws -> Bool                // add_to_playlist
    func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String) async throws // remove_from_playlist
    /// `(videoId, setVideoId)` pairs, all or nothing.
    func removeManyFromPlaylist(playlistId: String, tracks: [(String, String)]) async throws    // remove_many_from_playlist
    /// `before` nil moves it to the end.
    func moveInPlaylist(playlistId: String, setVideoId: String, before: String?) async throws   // move_in_playlist
    /// A save on this phone that the account now holds too.
    func markSynced(ids: [String]) async throws                                                 // lib_mark_synced
    /// The thumbs YouTube keeps (`rate`): a like mirrored to the account.
    func rate(videoId: String, rating: Rating) async throws                                     // rate
}

extension YouTubeLibraryClient {
    /// Every song, one add each (YouTube's add takes one video). Answers how many it took.
    @discardableResult
    func addToYouTubePlaylist(_ id: String, songs: [SongItem]) async throws -> Int {
        var added = 0
        for s in songs { if try await addToPlaylist(playlistId: id, videoId: s.videoId) { added += 1 } }
        return added
    }

    /// Take these videos out of an account playlist: its rows are found by `setVideoId` on the
    /// playlist's page, then removed in one request.
    func removeFromYouTubePlaylist(_ id: String, videoIds: [String], page: PlaylistPage) async throws {
        let want = Set(videoIds)
        let tracks = page.items.filter { want.contains($0.videoId) }.compactMap { s in s.setVideoId.map { (s.videoId, $0) } }
        guard !tracks.isEmpty else { return }
        try await removeManyFromPlaylist(playlistId: id, tracks: tracks)
    }

    /// Reorder an account playlist to `target` (setVideoIds), one move per row out of place.
    func reorderYouTubePlaylist(_ id: String, from current: [String], to target: [String]) async throws {
        for (row, before) in playlistMoves(from: current, to: target) {
            try await moveInPlaylist(playlistId: id, setVideoId: row, before: before)
        }
    }
}

/// The plan `reorderYouTubePlaylist` follows, pure (tests): each move as (setVideoId, before).
func playlistMoves(from current: [String], to target: [String]) -> [(String, String)] {
    var now = current.filter(target.contains), out: [(String, String)] = []
    for (i, want) in target.enumerated() where i < now.count && now[i] != want {
        out.append((want, now[i]))
        now.removeAll { $0 == want }
        now.insert(want, at: i)
    }
    return out
}

extension RealCoreClient: YouTubeLibraryClient {
    /// The account's rows only: Liked Songs, Your Rotation and this phone's playlists come from the
    /// library snapshot, as on the desktop's sidebar.
    func getLibrary() async throws -> [BrowseItem] {
        try await call("get_library", as: Lossy<BrowseItem>.self).items.filter(YouTubeLibrary.isAccountRow)
    }
    func getLibraryAlbums() async throws -> [BrowseItem] { try await call("get_library_albums", as: Lossy<BrowseItem>.self).items }
    func getLibraryArtists() async throws -> [BrowseItem] { try await call("get_library_artists", as: Lossy<BrowseItem>.self).items }
    func getLibrarySubscriptions() async throws -> [BrowseItem] { try await call("get_library_subscriptions", as: Lossy<BrowseItem>.self).items }
    func subscribe(channelId: String, subscribed: Bool) async throws {
        _ = try await call("subscribe", ["channelId": channelId, "subscribed": subscribed])
    }
    func setAlbumSaved(playlistId: String, saved: Bool) async throws {
        _ = try await call("set_album_saved", ["playlistId": playlistId, "saved": saved])
    }
    func playlistIndex() async throws -> [String: [String]] { try await call("playlist_index") }
    func syncPlaylistIndex() async throws -> [String: [String]] { try await call("sync_playlist_index") }
    func readonlyPlaylists() async throws -> [String] { try await call("readonly_playlists") }
    func createPlaylist(title: String) async throws -> String { try await call("create_playlist", ["title": title, "local": false]) }
    func editPlaylistDetails(playlistId: String, name: String?, description: String?, public: Bool?) async throws {
        _ = try await call("edit_playlist_details", ["playlistId": playlistId, "name": name, "description": description, "public": `public`])
    }
    func deletePlaylist(playlistId: String) async throws { _ = try await call("delete_playlist", ["playlistId": playlistId]) }
    func addToPlaylist(playlistId: String, videoId: String) async throws -> Bool {
        try await call("add_to_playlist", ["playlistId": playlistId, "videoId": videoId])
    }
    func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String) async throws {
        _ = try await call("remove_from_playlist", ["playlistId": playlistId, "videoId": videoId, "setVideoId": setVideoId])
    }
    func removeManyFromPlaylist(playlistId: String, tracks: [(String, String)]) async throws {
        _ = try await call("remove_many_from_playlist", ["playlistId": playlistId, "tracks": tracks.map { [$0.0, $0.1] }])
    }
    func moveInPlaylist(playlistId: String, setVideoId: String, before: String?) async throws {
        _ = try await call("move_in_playlist", ["playlistId": playlistId, "setVideoId": setVideoId, "beforeSetVideoId": before])
    }
    func markSynced(ids: [String]) async throws { _ = try await call("lib_mark_synced", ["ids": ids]) }
    func rate(videoId: String, rating: Rating) async throws { _ = try await call("rate", ["videoId": videoId, "rating": rating]) }
}

/// The mock's account library: one playlist you own and one saved from someone else, filled from
/// the fixture pool; edits land here so the UI and the tests can read them back.
struct MockYouTubeState {
    var playlists: [(card: BrowseItem, items: [SongItem])] = []
    var albums: [BrowseItem] = []
    var subscriptions: [BrowseItem] = []
    /// Albums' audio playlists liked (`set_album_saved`), and channels subscribed.
    var likedPlaylists: Set<String> = []
    var subscribed: Set<String> = []
    var ratings: [String: Rating] = [:]
    var synced: Set<String> = []
    /// The core's `touched` stamps for edited account playlists (`lastTouched` in the snapshot).
    var touched: [String: Double] = [:]
    /// Edit playlist's description and Public switch, read back by `get_playlist`.
    var descriptions: [String: String] = [:]
    var privacy: [String: String] = [:]
    var seeded = false
    static let ownedId = "VLPLmockowned"
    static let savedId = "VLPLmocksaved"
}

extension MockCoreClient: YouTubeLibraryClient {
    var mockSignedIn: Bool { MockAccounts.shared.get(self).account.signedIn }

    /// Seeds the account's library the first time it is asked for while signed in.
    private func ytSeedLocked() {
        guard !fs.yt.seeded else { return }
        fs.yt.seeded = true
        let name = Self.mockAccount.name ?? "You"
        func rows(_ from: Int, _ n: Int, _ prefix: String) -> [SongItem] {
            poolSlice(from, n).enumerated().map { i, s in var s = s; s.setVideoId = "\(prefix)\(i)"; return s }
        }
        let mine = rows(0, 6, "own")
        let theirs = rows(10, 5, "sav")
        fs.yt.playlists = [
            (BrowseItem(kind: .playlist, id: MockYouTubeState.ownedId, title: "Road Trip", subtitle: "\(name) • \(mine.count) tracks",
                        thumbnail: mine.first?.thumbnail), mine),
            (BrowseItem(kind: .playlist, id: MockYouTubeState.savedId, title: "Late Night Jazz", subtitle: "Jazz Radio • \(theirs.count) tracks",
                        thumbnail: theirs.first?.thumbnail), theirs),
        ]
    }

    private func requireAccount() throws {
        guard mockSignedIn else { throw CoreFailure(message: "Sign in to YouTube first.") }
    }

    func getLibrary() async throws -> [BrowseItem] {
        guard mockSignedIn else { return [] }
        return withLock { ytSeedLocked(); return fs.yt.playlists.map(\.card) }
    }
    func getLibraryAlbums() async throws -> [BrowseItem] { mockSignedIn ? withLock { fs.yt.albums } : [] }
    func getLibraryArtists() async throws -> [BrowseItem] { [] }
    func getLibrarySubscriptions() async throws -> [BrowseItem] { mockSignedIn ? withLock { fs.yt.subscriptions } : [] }
    func subscribe(channelId: String, subscribed: Bool) async throws {
        try requireAccount()
        withLock { if subscribed { fs.yt.subscribed.insert(channelId) } else { fs.yt.subscribed.remove(channelId) } }
    }
    func setAlbumSaved(playlistId: String, saved: Bool) async throws {
        try requireAccount()
        withLock { if saved { fs.yt.likedPlaylists.insert(playlistId) } else { fs.yt.likedPlaylists.remove(playlistId) } }
    }
    func playlistIndex() async throws -> [String: [String]] {
        withLock {
            var out: [String: [String]] = [:]
            for p in fs.yt.playlists where p.card.id == MockYouTubeState.ownedId {
                for s in p.items { out[s.videoId, default: []].append(p.card.id) }
            }
            return out
        }
    }
    func syncPlaylistIndex() async throws -> [String: [String]] { try await playlistIndex() }
    func readonlyPlaylists() async throws -> [String] { mockSignedIn ? [MockYouTubeState.savedId] : [] }
    func createPlaylist(title: String) async throws -> String {
        try requireAccount()
        return withLock {
            ytSeedLocked()
            let id = "VLPLmocknew\(fs.yt.playlists.count)"
            fs.yt.playlists.insert((BrowseItem(kind: .playlist, id: id, title: title, subtitle: "\(Self.mockAccount.name ?? "You") • 0 tracks"), []), at: 0)
            return id
        }
    }
    func editPlaylistDetails(playlistId: String, name: String?, description: String?, public: Bool?) async throws {
        try requireAccount()
        withLock {
            if let i = ytIndexLocked(playlistId), let name { fs.yt.playlists[i].card.title = name }
            if let description { fs.yt.descriptions[playlistId] = description }
            if let `public` { fs.yt.privacy[playlistId] = `public` ? "PUBLIC" : "PRIVATE" }
        }
        ytTouched(playlistId)
    }
    func deletePlaylist(playlistId: String) async throws {
        try requireAccount()
        withLock { fs.yt.playlists.removeAll { $0.card.id == playlistId } }
    }
    func addToPlaylist(playlistId: String, videoId: String) async throws -> Bool {
        try requireAccount()
        let song = try await song(videoId: videoId)
        let added = try withLock {
            guard let i = ytIndexLocked(playlistId) else { throw MockError.missing(playlistId) }
            guard playlistId != MockYouTubeState.savedId else { throw CoreFailure(message: "not_editable") }
            if fs.yt.playlists[i].items.contains(where: { $0.videoId == videoId }) { return false }
            var s = song
            s.setVideoId = "new\(fs.yt.playlists[i].items.count)-\(videoId)"
            fs.yt.playlists[i].items.append(s)
            return true
        }
        ytTouched(playlistId)
        return added
    }
    func removeFromPlaylist(playlistId: String, videoId: String, setVideoId: String) async throws {
        try await removeManyFromPlaylist(playlistId: playlistId, tracks: [(videoId, setVideoId)])
    }
    func removeManyFromPlaylist(playlistId: String, tracks: [(String, String)]) async throws {
        try requireAccount()
        let drop = Set(tracks.map(\.1))
        withLock {
            if let i = ytIndexLocked(playlistId) { fs.yt.playlists[i].items.removeAll { drop.contains($0.setVideoId ?? "") } }
        }
        ytTouched(playlistId)
    }
    func moveInPlaylist(playlistId: String, setVideoId: String, before: String?) async throws {
        try requireAccount()
        withLock {
            guard let i = ytIndexLocked(playlistId), let from = fs.yt.playlists[i].items.firstIndex(where: { $0.setVideoId == setVideoId }) else { return }
            let row = fs.yt.playlists[i].items.remove(at: from)
            let to = before.flatMap { b in fs.yt.playlists[i].items.firstIndex { $0.setVideoId == b } } ?? fs.yt.playlists[i].items.count
            fs.yt.playlists[i].items.insert(row, at: to)
        }
        ytTouched(playlistId)
    }
    func markSynced(ids: [String]) async throws { withLock { fs.yt.synced.formUnion(ids) } }
    func rate(videoId: String, rating: Rating) async throws {
        try requireAccount()
        withLock { fs.yt.ratings[videoId] = rating }
    }

    func ytIndexLocked(_ id: String) -> Int? { fs.yt.playlists.firstIndex { $0.card.id == id } }

    /// Like the core after an edit (`library::touched`): stamp it and say so.
    private func ytTouched(_ id: String) {
        let at = Date().timeIntervalSince1970
        withLock { fs.yt.touched[id] = at }
        struct T: Encodable { var scope = "touched"; var itemId: String; var at: Double }
        emit("library-changed", T(itemId: id, at: at))
    }

    /// An account playlist's page (`get_playlist`), or nil for any other id.
    func ytPageLocked(_ id: String) -> PlaylistPage? {
        guard mockSignedIn, let p = fs.yt.playlists.first(where: { $0.card.id == id }) else { return nil }
        let owned = id != MockYouTubeState.savedId
        return PlaylistPage(title: p.card.title, subtitle: p.card.subtitle, thumbnail: p.card.thumbnail, description: fs.yt.descriptions[id],
                            items: p.items.map(withRating), owned: owned, collaborative: false,
                            privacy: owned ? fs.yt.privacy[id] ?? "PRIVATE" : nil)
    }
}
