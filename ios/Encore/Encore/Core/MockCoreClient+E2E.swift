// DEV ONLY: the mock's side of own-playlist editing and Clear queue (stream ios-e2e).
import Foundation

extension MockCoreClient {
    func whatsNewRefreshed() async throws -> WhatsNew { try await whatsNew() }

    func setHidden(_ song: SongItem, hidden: Bool) async throws {
        withLock { if hidden { mockHidden.insert(song.videoId) } else { mockHidden.remove(song.videoId) } }
        emit("library-changed", ["scope": "hidden"])
    }

    func clearQueued() async throws {
        withLock {
            let cur = items.indices.contains(current) ? items[current].videoId : nil
            items.removeAll { $0.queued == true && $0.videoId != cur }
            if let cur, let i = items.firstIndex(where: { $0.videoId == cur }) { current = i }
        }
        emit("queue-changed", withLock { queuePayload() })
    }

    func updatePlaylist(id: String, name: String?, description: String?) async throws {
        if !isLocalPlaylistId(id), withLock({ ytIndexLocked(id) }) != nil { return try await editPlaylistDetails(playlistId: id, name: name, description: description, public: nil) }
        withLock {
            guard let i = playlists.firstIndex(where: { $0.meta.id == id }) else { return }
            if let name { playlists[i].meta.name = name }
            if let description { playlists[i].meta.description = description }
            playlists[i].meta.updatedAt = Date().timeIntervalSince1970
        }
        emit("library-changed", ["scope": "playlists"])
    }

    func deletePlaylist(id: String) async throws {
        if !isLocalPlaylistId(id), withLock({ ytIndexLocked(id) }) != nil { return try await deletePlaylist(playlistId: id) }
        withLock {
            if let i = playlists.firstIndex(where: { $0.meta.id == id }) { mockTrash[id] = playlists.remove(at: i) }
        }
        emit("library-changed", ["scope": "playlists"])
    }

    func restorePlaylist(id: String) async throws {
        withLock { if let p = mockTrash.removeValue(forKey: id) { playlists.insert(p, at: 0) } }
        emit("library-changed", ["scope": "playlists"])
    }

    func playlistEntries(id: String) async throws -> [PlaylistEntry] {
        withLock {
            let items = playlists.first { $0.meta.id == id }?.items ?? []
            return items.enumerated().map { PlaylistEntry(rowId: Int64($0.offset + 1), position: Int64($0.offset), addedAt: 0, song: $0.element) }
        }
    }

    /// The mock's row ids are 1-based positions at the time of reading.
    func removeFromPlaylist(id: String, rowIds: [Int64]) async throws {
        withLock {
            guard let i = playlists.firstIndex(where: { $0.meta.id == id }) else { return }
            let drop = Set(rowIds.map { Int($0) - 1 })
            playlists[i].items = playlists[i].items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            playlists[i].meta.count = playlists[i].items.count
        }
        emit("library-changed", ["scope": "playlists"])
    }

    func setPlaylistOrder(id: String, rowIds: [Int64]) async throws {
        withLock {
            guard let i = playlists.firstIndex(where: { $0.meta.id == id }) else { return }
            let old = playlists[i].items
            playlists[i].items = rowIds.compactMap { r in old.indices.contains(Int(r) - 1) ? old[Int(r) - 1] : nil }
            playlists[i].meta.count = playlists[i].items.count
        }
        emit("library-changed", ["scope": "playlists"])
    }
}
