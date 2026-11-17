// Stream ios-sync2: the signed-in YouTube account's library on the iPhone, what the desktop keeps
// in `player.svelte.ts` (`library`, `savedIn`, `ownedByUser`, `inLibrary`, `addToLibrary`,
// `removeFromLibrary`). Loaded on sign-in, emptied on sign-out (`AccountStore.apply`). Your Library
// lists the account's playlists next to this phone's; Add to playlist, Edit playlist, Delete and
// Save/Follow write to the account through `YouTubeLibraryClient`.
import Foundation
import Observation

@MainActor @Observable
final class YouTubeLibrary {
    @ObservationIgnored let core: CoreClient
    /// The account's library playlists (its own and saved ones), newest first as YouTube lists them.
    var playlists: [BrowseItem] = []
    var albums: [BrowseItem] = []
    var artists: [BrowseItem] = []
    var subscriptions: [BrowseItem] = []
    /// videoId → your own account playlists holding it (Add to playlist's "Saved in").
    var index: [String: [String]] = [:]
    /// Library playlists you can't edit (saved from someone else): never offered as a target.
    var readOnly: Set<String> = []
    /// The account's channel name: what marks a library playlist as yours.
    var accountName: String?
    var loaded = false
    /// A sign-out or account switch mid-load must not paint the previous account's rows.
    @ObservationIgnored private var generation = 0

    init(core: CoreClient) { self.core = core }

    private var client: YouTubeLibraryClient? { core as? YouTubeLibraryClient }

    /// `get_library` rows that belong to the account (the snapshot already has the rest).
    nonisolated static func isAccountRow(_ item: BrowseItem) -> Bool {
        item.kind == .playlist && item.id != likedPlaylistId && item.id != onRepeatId && !isLocalPlaylistId(item.id)
    }
    nonisolated static let onRepeatId = "LIMUSIC_ON_REPEAT"

    func load(account name: String?) async {
        generation += 1
        let gen = generation
        accountName = name
        guard let client else { return }
        async let p = client.getLibrary()
        async let al = client.getLibraryAlbums()
        async let ar = client.getLibraryArtists()
        async let su = client.getLibrarySubscriptions()
        let rows = (try? await p) ?? []
        let (albums, artists, subs) = ((try? await al) ?? [], (try? await ar) ?? [], (try? await su) ?? [])
        guard gen == generation else { return }
        playlists = rows; self.albums = albums; self.artists = artists; subscriptions = subs
        loaded = true
        // The stored index first (instant), then whatever a stale-index crawl turns up.
        readOnly = Set((try? await client.readonlyPlaylists()) ?? [])
        if let i = try? await client.playlistIndex(), gen == generation { index = i }
        if let i = try? await client.syncPlaylistIndex(), gen == generation { index = i }
        if let r = try? await client.readonlyPlaylists(), gen == generation { readOnly = Set(r) }
    }

    func clear() {
        generation += 1
        playlists = []; albums = []; artists = []; subscriptions = []; index = [:]; readOnly = []
        accountName = nil
        loaded = false
    }

    // MARK: reading

    /// Yours on the account (the desktop's `ownedByUser`): YouTube's library line names the owner
    /// first ("<owner> • N tracks"), and on your own playlists that is you.
    func owns(_ id: String) -> Bool {
        guard let me = accountName?.trimmingCharacters(in: .whitespaces), !me.isEmpty,
              let row = playlists.first(where: { $0.id == id }) else { return false }
        return (row.subtitle ?? "").components(separatedBy: "•").first?.trimmingCharacters(in: .whitespaces) == me
    }

    /// Playlists a song can be added to: your own, not ones the crawl found read-only.
    var editable: [BrowseItem] { playlists.filter { owns($0.id) && !readOnly.contains($0.id) } }

    /// The account half of the desktop's `inLibrary`.
    func contains(_ item: BrowseItem) -> Bool {
        let has = { (list: [BrowseItem]) in list.contains { $0.id == item.id } }
        switch item.kind {
        case .artist: return has(artists) || has(subscriptions)
        case .album: return has(albums)
        default: return has(playlists)
        }
    }

    // MARK: writes (the local half is the caller's)

    /// Save or unsave on the account (the desktop's `pushSaved` / `removeFromLibrary`). An album's
    /// like sits on its audio playlist and an artist's subscription on its channel, both read off
    /// the item's page; a playlist is liked by its own id.
    func push(_ item: BrowseItem, saved: Bool) async throws {
        guard let client else { return }
        switch item.kind {
        case .album:
            let album = try await core.getAlbum(id: item.id)
            guard album.inLibrary != saved, let pid = album.playlistId else { break }
            try await client.setAlbumSaved(playlistId: pid, saved: saved)
        case .artist:
            let artist = try await core.getArtist(id: item.id)
            guard artist.subscribed != saved else { break }
            try await client.subscribe(channelId: artist.channelId, subscribed: saved)
        case .playlist:
            guard contains(item) != saved else { break }
            try await client.setAlbumSaved(playlistId: item.id, saved: saved)
        default: return
        }
        if saved { try? await client.markSynced(ids: [item.id]) }
        patch(item, saved: saved)
    }

    private func patch(_ item: BrowseItem, saved: Bool) {
        func apply(_ list: inout [BrowseItem]) {
            list.removeAll { $0.id == item.id }
            if saved { list.insert(item, at: 0) }
        }
        switch item.kind {
        case .album: apply(&albums)
        case .artist: apply(&subscriptions)
        case .playlist: apply(&playlists)
        default: break
        }
    }

    /// A new playlist on the account, in the library at once (YouTube's library browse lags a few
    /// seconds behind a create). Its line names you, so it reads as yours straight away.
    func create(title: String) async throws -> BrowseItem {
        guard let client else { throw CoreFailure(message: "Sign in to YouTube first.") }
        let id = try await client.createPlaylist(title: title)
        let browseId = id.hasPrefix("VL") ? id : "VL\(id)"
        let row = BrowseItem(kind: .playlist, id: browseId, title: title, subtitle: accountName.map { "\($0) • 0 tracks" })
        playlists.removeAll { $0.id == browseId }
        playlists.insert(row, at: 0)
        return row
    }

    func renamed(_ id: String, to name: String) {
        if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].title = name }
    }

    /// Gone from the account: out of the library and the index.
    func forget(_ id: String) {
        playlists.removeAll { $0.id == id }
        for (v, ids) in index where ids.contains(id) { index[v] = ids.filter { $0 != id } }
    }

    func noteAdded(_ id: String, videoIds: [String]) {
        for v in videoIds where !(index[v] ?? []).contains(id) { index[v, default: []].append(id) }
    }

    func noteRemoved(_ id: String, videoIds: [String]) {
        for v in videoIds { index[v]?.removeAll { $0 == id } }
    }
}

/// The app's one door for "is this mine / saved" now that a library can live on the account too.
extension AppModel {
    /// A playlist you can edit: on this phone, or yours on the account.
    func isOwnPlaylist(_ id: String) -> Bool {
        isLocalPlaylistId(id) || (account.signedIn && account.youtube.owns(id))
    }

    /// In Your Library: saved on this phone, or (signed in) on the account.
    func inLibrary(_ item: BrowseItem) -> Bool {
        library.isSaved(item.id) || (account.signedIn && account.youtube.contains(item))
    }

    /// Save / Follow and their undo: the row on this phone always (the whole library signed out),
    /// plus the account's own write when signed in. Returns the new state.
    @discardableResult
    func toggleInLibrary(_ item: BrowseItem) -> Bool {
        let on = !inLibrary(item)
        if library.isSaved(item.id) != on { library.toggleSaved(item) }
        if account.signedIn {
            let yt = account.youtube
            library.actions.run("save", on ? "Couldn't save it to your YouTube library" : "Couldn't remove it from your YouTube library") {
                try await yt.push(item, saved: on)
            }
        }
        return on
    }
}
