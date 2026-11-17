// Stream magic-ib (I-B2, SYNC-GAPS §1): models for the desktop commands bridged for the iOS lanes
// P1–P3 (queue restore, smart chips, Enhance, recovered playlists, history and stats, blocked
// artists, folders, playlist cover). Shapes are the core's JSON (api.ts / trackapi.ts).
import Foundation

/// A genre or mood chip over Liked Songs (`smart_tags_liked`; event `smart-tags-changed`).
struct SmartChip: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case genre, mood }
    var label: String
    var kind: Kind
    var videoIds: [String]
    var id: String { label }
}

struct LikedChips: Codable, Hashable {
    var chips: [SmartChip]
    /// Liked tracks whose tags are known so far, of `total`.
    var done: Int
    var total: Int
    static let empty = LikedChips(chips: [], done: 0, total: 0)
}

/// Enhance on one playlist (`enhance_*`; event `enhance-changed`): the suggestions shown between rows.
struct EnhanceState: Codable, Hashable {
    var playlistId: String
    var on: Bool
    var recs: [SongItem]
    var at: Int64
}

/// A deleted playlist that can still be restored (`lib_deleted_playlists`; restore: `lib_playlist_restore`).
struct DeletedPlaylist: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var count: Int
    var thumbnail: String?
    var deletedAt: Int64
    var purgeAt: Int64
}

/// One row of the local listening history (`lib_recent_tracks`).
struct RecentTrack: Codable, Hashable {
    var song: SongItem
    var playedAt: Int64
    var plays: Int
}

/// `[id, position]` / `[day, secs]` pairs, which the core sends as two-element arrays.
struct CorePair<A: Codable & Hashable, B: Codable & Hashable>: Codable, Hashable {
    var first: A
    var second: B
    init(_ a: A, _ b: B) { first = a; second = b }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        first = try c.decode(A.self); second = try c.decode(B.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(first); try c.encode(second)
    }
}

struct TopArtist: Codable, Hashable {
    var name: String
    var id: String?
    var thumbnail: String?
    var plays: Int
    var secs: Int
}

/// The stats page (`listening_stats {since}`).
struct ListeningStats: Codable, Hashable {
    struct TopSong: Codable, Hashable { var song: SongItem; var plays: Int; var secs: Int }
    struct TopAlbum: Codable, Hashable { var id: String; var title: String; var artist: String; var thumbnail: String?; var plays: Int; var secs: Int }
    /// A show by time heard; `id` is its browse id when its episodes were played from the show.
    struct TopPodcast: Codable, Hashable { var id: String?; var name: String; var thumbnail: String?; var plays: Int; var secs: Int }
    /// Seconds heard, podcast episodes included.
    var secs: Int
    /// Of those, podcast episodes; and how many distinct episodes.
    var podcastSecs: Int? = nil
    var episodes: Int? = nil
    var prevSecs: Int?
    var plays: Int
    var songs: Int
    var newSongs: Int
    var artists: Int
    /// Per day: ["2026-11-01", seconds].
    var days: [CorePair<String, Int>]
    /// Seconds per local weekday (0 = Sunday) and hour: `hours[day * 24 + hour]` (168).
    var hours: [Int]
    var topSongs: [TopSong]
    var topArtists: [TopArtist]
    var topAlbums: [TopAlbum]
    var topPodcasts: [TopPodcast]? = nil
    var firstAt: Int64?
    var streak: Int
    var bestStreak: Int? = nil
}

/// "Don't play this artist" (`block_artist` / `unblock_artist {key}` / `get_blocked_artists`).
struct BlockedArtist: Codable, Hashable {
    var id: String?
    var name: String
    /// The handle `unblock_artist` takes: the channel id, else the name.
    var key: String { id ?? name }
}

/// What `lib_folder_delete` removed, for its Undo (`lib_folder_restore {snapshot}`): pass it back unchanged.
struct FolderSnapshot: Codable, Hashable {
    var folder: Folder
    var childFolders: [CorePair<String, Int>]
    var items: [CorePair<String, Int>]
}

/// `set_playlist_cover`: the custom cover (a file URL) and YouTube's own thumbnail.
struct PlaylistCoverResult: Codable, Hashable {
    var cover: String?
    var thumbnail: String?
}

/// A YouTube playlist's next page (`get_playlist_more`).
struct PlaylistMore: Codable, Hashable {
    var items: [SongItem]
    var continuation: String?
}
