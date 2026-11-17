// Swift mirrors of the desktop UI contract (`ui/src/lib/api.ts`). Same JSON on the wire: the
// UniFFI core (stream S2) hands these payloads over as JSON, and the mock decodes the devmock
// fixtures with them, so field names and casing follow api.ts exactly.
import Foundation

struct ArtistRun: Codable, Hashable {
    var text: String
    var id: String?
}

enum Rating: String, Codable, Hashable { case like, dislike, indifferent }

struct SongItem: Codable, Hashable, Identifiable {
    var videoId: String
    var title: String
    var artists: String
    var artistId: String?
    var artistRuns: [ArtistRun]?
    var album: String?
    var albumId: String?
    var duration: String?
    var playCount: String?
    var thumbnail: String?
    var rating: Rating?
    var queued: Bool?
    var queuedEnd: Bool?
    var queuedFrom: String?
    var autoplay: Bool?
    var unavailable: Bool?
    var explicit: Bool?
    var isVideo: Bool?
    /// Podcast episode row (`episodeSong`): speed + 15 s skips in Now Playing, no music radio.
    var isEpisode: Bool?
    /// The other version of this track (#442): a song's music video, or a video's song. Now
    /// Playing's "Switch to video" / "Switch to audio" plays it (stream ios-video).
    var counterpart: String?
    var counterpartThumbnail: String?
    /// The row's id inside a YouTube playlist (`playlistSetVideoId`): what removing or moving it takes.
    var setVideoId: String?

    var id: String { videoId }

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id", title, artists, artistId = "artist_id", artistRuns = "artist_runs"
        case album, albumId = "album_id", duration, playCount = "play_count", thumbnail, rating
        case queued, queuedEnd = "queued_end", queuedFrom = "queued_from", autoplay, unavailable
        case explicit, isVideo = "is_video", isEpisode = "is_episode"
        case counterpart, counterpartThumbnail = "counterpart_thumbnail", setVideoId = "set_video_id"
    }

    init(videoId: String, title: String, artists: String, artistId: String? = nil, album: String? = nil,
         albumId: String? = nil, duration: String? = nil, thumbnail: String? = nil, explicit: Bool? = nil) {
        self.videoId = videoId; self.title = title; self.artists = artists; self.artistId = artistId
        self.album = album; self.albumId = albumId; self.duration = duration; self.thumbnail = thumbnail
        self.explicit = explicit
    }

    /// One you queued: "Play next" (`queued`) or "Add to queue" (`queued_end`). Both are the
    /// queue's "Next in queue" block and both go on Clear queue, as on the desktop.
    var isQueued: Bool { queued == true || queuedEnd == true }

    /// Duration in seconds parsed from "m:ss" / "h:mm:ss".
    var seconds: Double {
        guard let d = duration else { return 0 }
        return d.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }
}

/// `podcast` (show `MPSP…`) and `episode` (`MPED…`) come from explore surfaces (api.ts `ExploreItem`).
enum BrowseKind: String, Codable, Hashable { case song, playlist, album, artist, podcast, episode, audiobook }

struct BrowseItem: Codable, Hashable, Identifiable {
    var kind: BrowseKind
    var id: String
    var title: String
    var subtitle: String?
    var thumbnail: String?
    var duration: String?
    var albumId: String?
    var artistRuns: [ArtistRun]?
    var playCount: String?
    var explicit: Bool?

    var asSong: SongItem {
        var s = SongItem(videoId: id, title: title, artists: artistRuns?.map(\.text).joined(separator: ", ") ?? subtitle ?? "",
                         albumId: albumId, duration: duration, thumbnail: thumbnail, explicit: explicit)
        s.artistRuns = artistRuns
        s.artistId = artistRuns?.first(where: { $0.id != nil })?.id
        return s
    }
}

struct HomeChip: Codable, Hashable { var title: String; var params: String }
struct HomeSection: Codable, Hashable { var title: String; var kind: String?; var items: [BrowseItem] }
struct HomePage: Codable { var chips: [HomeChip]; var sections: [HomeSection] }

struct SearchResults: Codable {
    var top: [BrowseItem]
    var songs: [BrowseItem]
    var albums: [BrowseItem]
    var artists: [BrowseItem]
    var playlists: [BrowseItem]
    static let empty = SearchResults(top: [], songs: [], albums: [], artists: [], playlists: [])
}

struct SearchSuggestions: Codable {
    struct Query: Codable, Hashable { var text: String; var history: Bool }
    var queries: [Query]
    var items: [BrowseItem]
}

/// `kind`: the core's shelf kind (`albums`, `singles`, `videos`, `featured`, `playlists`, `fans`, `other`).
struct ArtistCarousel: Codable, Hashable { var title: String; var kind: String?; var items: [BrowseItem] }

struct AlbumPage: Codable {
    var title: String?
    var artist: String?
    var artistId: String?
    var artistThumbnail: String?
    var subtitle: String?
    var secondSubtitle: String?
    var description: String?
    var thumbnail: String?
    var items: [SongItem]
    var explicit: Bool?
    var playlistId: String?
    var inLibrary: Bool
    var sections: [ArtistCarousel]?
}

struct ArtistPage: Codable {
    var name: String?
    var thumbnail: String?
    var description: String?
    var subscribers: String?
    var monthlyListeners: String?
    var channelId: String
    var subscribed: Bool
    var topSongs: [SongItem]
    /// The artist's full top-songs playlist (Appears on reads it).
    var topSongsId: String? = nil
    var sections: [ArtistCarousel]
}

struct PlaylistPage: Codable {
    var title: String?
    var subtitle: String?
    var thumbnail: String?
    var description: String?
    var cover: String?
    var items: [SongItem]
    var owned: Bool
    var collaborative: Bool
    /// `PUBLIC` / `PRIVATE` / `UNLISTED`: one of your YouTube playlists (nil for anything else).
    var privacy: String? = nil
}

struct ShelfItem: Codable, Hashable, Identifiable {
    var kind: String
    var id: String
    var title: String
    var subtitle: String?
    var thumbnail: String?
    var explicit: Bool
    var song: SongItem?
    var params: String?
    var color: String?
    /// `episode` shortcut tiles (magic-d4): how far in (0...1) a started episode is, and whether
    /// it's a new, unplayed episode of a followed show (the blue dot).
    var progress: Double? = nil
    var newEpisode: Bool? = nil
}

struct Shelf: Codable, Hashable, Identifiable {
    enum Layout: String, Codable { case shortcuts, cards, songs, moods }
    var id: String
    var title: String
    var subtitle: String?
    var layout: Layout
    var source: String
    var items: [ShelfItem]
}

struct Mood: Codable, Hashable { var title: String; var params: String; var color: String? }
struct MoodSection: Codable, Hashable { var title: String; var items: [Mood] }

struct LyricLine: Codable, Hashable {
    var timeMs: Int?
    var text: String
    enum CodingKeys: String, CodingKey { case timeMs = "time_ms", text }
}

struct Lyrics: Codable {
    var source: String
    var provider: String
    var synced: Bool
    var instrumental: Bool
    var lines: [LyricLine]
    /// The song's lyrics offset (set on the desktop, `set_lyrics_offset`): positive shows lines later.
    var offsetMs: Int? = nil
    /// Its source picked by hand (or its timing nudged): the ⋯ menu ticks `provider`, not Automatic.
    var pinned: Bool? = nil
    enum CodingKeys: String, CodingKey { case source, provider, synced, instrumental, lines, offsetMs = "offset_ms", pinned }

    /// Index of the line being sung at `seconds`, offset applied (the desktop's `activeLine`), or
    /// nil before the first cue and for unsynced lyrics.
    func activeIndex(at seconds: Double) -> Int? {
        guard synced, !instrumental else { return nil }
        let ms = Int(seconds * 1000) - (offsetMs ?? 0)
        return lines.lastIndex { ($0.timeMs ?? .max) <= ms }
    }
}

enum RepeatMode: String, Codable { case off, all, one }

struct QueueState: Codable {
    var items: [SongItem]
    var currentIndex: Int
    var shuffle: Bool?
    var `repeat`: RepeatMode?
    var sourceName: String?
    var sourceId: String?
    /// videoId → why playback steps over the row (explicit | unavailable | offline).
    var skipReasons: [String: String]?
    static let empty = QueueState(items: [], currentIndex: -1)
}

struct NowPlaying: Codable, Hashable {
    var videoId: String
    var title: String
    var artists: String
    var artistId: String?
    var thumbnail: String?
    var duration: String?
    var album: String?
    var rating: Rating?
    // System Now Playing (lock screen, Dynamic Island): every artist, the "E" badge, podcast skips,
    // no scrubber on a live broadcast. All optional: older cores and the fixtures don't send them.
    var artistRuns: [ArtistRun]? = nil
    var explicit: Bool? = nil
    var isEpisode: Bool? = nil
    var live: Bool? = nil
    /// stream: pod-fixes. false: no lyrics card or full-screen lyrics; an episode shows its chapters
    /// and description instead (core `lyrics::offered`). Missing means a song.
    var showsLyrics: Bool? = nil
    /// stream: instant. Shown the moment it was picked, ahead of its audio (state.rs
    /// `show_loading`): the play buttons show their loading state until the track starts.
    var loading: Bool? = nil
}

struct PlaybackSnapshot: Codable {
    var now: NowPlaying?
    var paused: Bool
    var position: Double
    var duration: Double
}

// Library (Rust `library.rs`): local, no account.
struct LibPlaylist: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String
    /// A cover the user picked (a file path, `set_playlist_cover`); else `thumbnail` stands in.
    var cover: String? = nil
    var thumbnail: String?
    var count: Int
    var pinned: Bool
    var updatedAt: Double
    var lastPlayedAt: Double?
    var folderId: String? = nil
}

enum SavedKind: String, Codable { case album, playlist, artist }
struct SavedItem: Codable, Hashable, Identifiable {
    var id: String
    var kind: SavedKind
    var title: String
    var subtitle: String?
    var thumbnail: String?
    var addedAt: Double
}

struct RecentContext: Codable, Hashable {
    var itemId: String
    var kind: String
    var card: BrowseItem?
    var playedAt: Double
}

struct LibrarySnapshot: Codable {
    var likedIds: [String]
    var playlists: [LibPlaylist]
    var saved: [SavedItem]
    var pinnedIds: [String]
    var lastPlayed: [String: Double]
    /// Likes and playlist edits (`lib_touched`): Recents sorts by the later of this and `lastPlayed`.
    var lastTouched: [String: Double]? = nil
    var folders: [Folder]? = nil
    var privateSession: Bool? = nil
    /// Songs hidden everywhere ("Hide song"): greyed, and playback steps over them.
    var hiddenIds: [String]? = nil
    static let empty = LibrarySnapshot(likedIds: [], playlists: [], saved: [], pinnedIds: [], lastPlayed: [:])
}

/// One row of an own playlist (`lib_playlist_entries`): the row id is what removal and reordering use.
struct PlaylistEntry: Codable, Hashable, Identifiable {
    var rowId: Int64
    var position: Int64
    var addedAt: Int64
    var song: SongItem
    var id: Int64 { rowId }
}

/// Liked Songs' id: the same as YouTube's Liked Music (`LIKED_ID` in api.ts).
let likedPlaylistId = "VLLM"
