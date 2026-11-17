// DEV ONLY: the mock's side of the actions stream ios-wire moved from UI-local state onto the core
// (Smart Shuffle −/+, Storage, move to folder, more show episodes, add to playlist, collection radio).
import Foundation

extension MockCoreClient {
    func smartShuffleRemove(videoId: String) async throws -> SmartShuffleState {
        let s = withLock { () -> SmartShuffleState in
            fs.smartShuffle.recIds.removeAll { $0 == videoId }
            if let i = items.firstIndex(where: { $0.videoId == videoId }), i != current {
                items.remove(at: i)
                if i < current { current -= 1 }
            }
            return fs.smartShuffle
        }
        emit("queue-changed", withLock { queuePayload() })
        emit("smart-shuffle-changed", s)
        return s
    }

    func smartShuffleKeep(videoId: String) async throws -> SmartShuffleState {
        let s = withLock { () -> SmartShuffleState in
            fs.smartShuffle.recIds.removeAll { $0 == videoId }
            return fs.smartShuffle
        }
        if let song = withLock({ items.first { $0.videoId == videoId } }) { try await setLiked(song, liked: true) }
        emit("smart-shuffle-changed", s)
        return s
    }

    func cacheSize() async throws -> Double { withLock { Double(fs.settings["mock_cache_bytes"] ?? "") ?? 184_000_000 } }
    func clearCaches() async throws { withLock { fs.settings["mock_cache_bytes"] = "0" } }

    func moveToFolder(itemId: String, folderId: String?) async throws {
        withLock {
            for i in fs.folders.indices { fs.folders[i].items.removeAll { $0 == itemId } }
            if let folderId, let i = fs.folders.firstIndex(where: { $0.id == folderId }) { fs.folders[i].items.append(itemId) }
            for i in playlists.indices where playlists[i].meta.id == itemId { playlists[i].meta.folderId = folderId }
        }
        emit("library-changed", ["scope": "folders"])
    }

    /// The fixture holds one page of episodes: there is never a next one.
    func podcastShowMore(id: String, continuation: String, sort: EpisodeSort) async throws -> PodcastEpisodePage {
        PodcastEpisodePage(episodes: [], continuation: nil)
    }

    func addToPlaylist(id: String, songs: [SongItem]) async throws {
        if !isLocalPlaylistId(id), withLock({ ytIndexLocked(id) }) != nil { try await addToYouTubePlaylist(id, songs: songs); return }
        withLock {
            guard let i = playlists.firstIndex(where: { $0.meta.id == id }) else { return }
            playlists[i].items += songs
            playlists[i].meta.count = playlists[i].items.count
            playlists[i].meta.updatedAt = Date().timeIntervalSince1970
        }
        emit("library-changed", ["scope": "playlists"])
    }

    func startRadio(kind: String, id: String, name: String?) async throws {
        let list = poolSlice(Int.random(in: 0..<max(pool.count, 1)), 25)
        try await playPlaylist(items: list, start: 0, context: PlayContext(kind: .radio, id: id, title: "\(name ?? "") Radio"), shuffle: false)
    }
}
