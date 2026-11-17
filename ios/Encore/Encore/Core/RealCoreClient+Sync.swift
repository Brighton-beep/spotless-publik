// Stream magic-ib (I-B2): the real core's side of the SYNC-GAPS bridge. Kept out of
// RealCoreClient.swift so its edits stay small (proxyfix has that file open too).
import Foundation

extension RealCoreClient {
    func restoreQueued(_ items: [SongItem]) async throws -> Int { try await call("restore_queued", ["items": items]) }
    func smartTagsLiked() async throws -> LikedChips { try await call("smart_tags_liked") }
    func enhanceState(playlistId: String) async throws -> EnhanceState { try await call("enhance_state", ["playlistId": playlistId]) }
    func enhanceSet(playlistId: String, on: Bool, len: Int) async throws -> EnhanceState {
        try await call("enhance_set", ["playlistId": playlistId, "on": on, "len": len])
    }
    func enhanceRemove(playlistId: String, videoId: String) async throws -> EnhanceState {
        try await call("enhance_remove", ["playlistId": playlistId, "videoId": videoId])
    }
    func enhanceKeep(playlistId: String, videoId: String) async throws -> EnhanceState {
        try await call("enhance_keep", ["playlistId": playlistId, "videoId": videoId])
    }
    func deletedPlaylists() async throws -> [DeletedPlaylist] { try await call("lib_deleted_playlists") }
    func recentTracks(limit: Int?) async throws -> [RecentTrack] {
        try await call("lib_recent_tracks", ["limit": limit], as: Lossy<RecentTrack>.self).items
    }
    func listeningStats(since: Int64) async throws -> ListeningStats { try await call("listening_stats", ["since": Int(since)]) }
    func topArtists(limit: Int) async throws -> [TopArtist] { try await call("top_artists", ["limit": limit]) }
    func clearListeningHistory() async throws { _ = try await call("clear_listening_history") }
    func blockedArtists() async throws -> [BlockedArtist] { try await call("get_blocked_artists") }
    func blockArtist(id: String?, name: String) async throws -> [BlockedArtist] { try await call("block_artist", ["id": id, "name": name]) }
    func unblockArtist(key: String) async throws -> [BlockedArtist] { try await call("unblock_artist", ["key": key]) }
    func renameFolder(id: String, name: String) async throws { _ = try await call("lib_folder_rename", ["id": id, "name": name]) }
    func deleteFolder(id: String) async throws -> FolderSnapshot { try await call("lib_folder_delete", ["id": id]) }
    func restoreFolder(_ snapshot: FolderSnapshot) async throws -> Folder { try await call("lib_folder_restore", ["snapshot": snapshot]) }
    func setPlaylistCover(playlistId: String, path: String?) async throws -> PlaylistCoverResult {
        try await call("set_playlist_cover", ["playlistId": playlistId, "path": path])
    }
    func playlistMore(token: String) async throws -> PlaylistMore {
        let page = try await call("get_playlist_more", ["token": token], as: PlaylistMore.self)
        return PlaylistMore(items: page.items, continuation: page.continuation)
    }
    func playlistContinuation(id: String) async throws -> String? {
        struct Page: Decodable { var continuation: String? }
        return try await call("get_playlist", ["id": id], as: Page.self).continuation
    }

    // Lane D1's commands (radio page, single pick, credits, taste exclusion).
    func radioTracks(kind: String, id: String, name: String?) async throws -> RadioPage {
        try await call("radio_tracks", ["kind": kind, "id": id, "name": name])
    }
    func playSingleAt(_ song: SongItem, from: String?, start: Double?) async throws {
        _ = try await call("play_single_at", ["item": song, "from": from, "start": start])
    }
    func songCredits(_ song: SongItem) async throws -> SongCredits { try await call("song_credits", ["item": song]) }
    func tasteSetExcluded(id: String, kind: String, title: String?, videoIds: [String], excluded: Bool) async throws {
        _ = try await call("taste_set_excluded", ["id": id, "kind": kind, "title": title, "videoIds": videoIds, "excluded": excluded])
    }
    func tasteExcluded() async throws -> [String] { try await call("taste_excluded") }
}
