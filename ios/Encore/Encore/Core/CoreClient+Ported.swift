// Desktop features ported to iPhone (parity audit): Settings › Podcasts (SponsorBlock, ad-free
// YouTube versions, OPML), the lyrics ⋯ menu (source picker, timing), Spotify track/album/artist
// links, and Export library. Models, the real core's calls and the mock's answers.
import Foundation

// MARK: models

/// Core `podcasts::api::PodcastSettings` (camelCase).
struct PodcastSettings: Codable, Equatable {
    var sponsorblock: Bool
    var sponsorblockCategories: [String]
}

/// Core `podcasts::api::ImportReport`.
struct OpmlImportReport: Codable, Equatable {
    var found: Int
    var added: Int
    var alreadyFollowed: Int
}

/// Core `lyrics::ProviderInfo`.
struct LyricsProvider: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var on: Bool
}

/// Core `import::Resolved`: what a Spotify link is on YouTube Music.
enum SpotifyResolved: Decodable, Equatable {
    case song(SongItem)
    case album(String)
    case artist(String)
    /// Playlists and profiles go to the import.
    case playlist

    private enum K: String, CodingKey { case kind, song, id }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "song": self = .song(try c.decode(SongItem.self, forKey: .song))
        case "album": self = .album(try c.decode(String.self, forKey: .id))
        case "artist": self = .artist(try c.decode(String.self, forKey: .id))
        default: self = .playlist
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.song(let x), .song(let y)): x.videoId == y.videoId
        case (.album(let x), .album(let y)), (.artist(let x), .artist(let y)): x == y
        case (.playlist, .playlist): true
        default: false
        }
    }
}

/// Core `library::ExportReport`.
struct LibraryExportReport: Codable, Equatable {
    var path: String
    var likedSongs: Int
    var playlists: Int
}

/// SponsorBlock's categories, in the desktop's order and wording (settings `SB_CATEGORIES`).
let sponsorBlockCategories: [(id: String, label: String)] = [
    ("sponsor", "Sponsor"), ("selfpromo", "Self-promotion"), ("interaction", "Interaction reminder"), ("intro", "Intro"),
    ("outro", "Outro"), ("preview", "Preview / recap"), ("music_offtopic", "Non-music section"), ("filler", "Filler"),
]

// MARK: real core

extension RealCoreClient {
    func podcastSettings() async throws -> PodcastSettings { try await call("podcast_settings") }
    func podcastSetSettings(sponsorblock: Bool?, categories: [String]?) async throws -> PodcastSettings {
        var patch: [String: Any] = [:]
        if let sponsorblock { patch["sponsorblock"] = sponsorblock }
        if let categories { patch["sponsorblockCategories"] = categories }
        return try await call("podcast_set_settings", ["settings": patch])
    }
    func podcastYouTubeMatch() async throws -> Bool { try await call("podcast_youtube_match") }
    func podcastSetYouTubeMatch(_ on: Bool) async throws -> Bool { try await call("podcast_set_youtube_match", ["on": on]) }
    func podcastOpmlImport(xml: String) async throws -> OpmlImportReport { try await call("podcast_opml_import", ["xml": xml]) }
    func podcastOpmlExport() async throws -> String { try await call("podcast_opml_export") }

    func lyricsProviders() async throws -> [LyricsProvider] { try await call("lyrics_providers") }
    func chooseLyricsSource(videoId: String, title: String, artists: String, duration: Double?, source: String?) async throws -> Lyrics? {
        try await call("choose_lyrics_source", ["videoId": videoId, "title": title, "artists": artists, "duration": duration, "source": source])
    }
    func setLyricsOffset(videoId: String, offsetMs: Int) async throws -> Int {
        try await call("set_lyrics_offset", ["videoId": videoId, "offsetMs": offsetMs])
    }

    func importResolve(link: String) async throws -> SpotifyResolved { try await call("import_resolve", ["link": link]) }
    func libExport(path: String) async throws -> LibraryExportReport { try await call("lib_export", ["path": path]) }
}

// MARK: mock (fs.settings holds what the core keeps in its settings table)

extension MockCoreClient {
    func podcastSettings() async throws -> PodcastSettings {
        withLock {
            PodcastSettings(sponsorblock: fs.settings["podcast_sponsorblock"] != "false",
                            sponsorblockCategories: fs.settings["podcast_sponsorblock_categories"].map { $0.split(separator: ",").map(String.init) }
                                ?? ["sponsor", "selfpromo", "interaction"])
        }
    }
    func podcastSetSettings(sponsorblock: Bool?, categories: [String]?) async throws -> PodcastSettings {
        withLock {
            if let sponsorblock { fs.settings["podcast_sponsorblock"] = sponsorblock ? "true" : "false" }
            if let categories { fs.settings["podcast_sponsorblock_categories"] = categories.joined(separator: ",") }
        }
        return try await podcastSettings()
    }
    func podcastYouTubeMatch() async throws -> Bool { withLock { fs.settings["podcast_youtube_match"] != "false" } }
    func podcastSetYouTubeMatch(_ on: Bool) async throws -> Bool {
        withLock { fs.settings["podcast_youtube_match"] = on ? "true" : "false" }
        return on
    }
    func podcastOpmlImport(xml: String) async throws -> OpmlImportReport {
        let feeds = xml.components(separatedBy: "xmlUrl=").count - 1
        guard feeds > 0 else { throw CoreFailure(message: "No podcast feeds found in that file.") }
        return OpmlImportReport(found: feeds, added: feeds, alreadyFollowed: 0)
    }
    func podcastOpmlExport() async throws -> String {
        let outlines = withLock { fs.follows }.map { "<outline type=\"rss\" text=\"\($0.title)\" xmlUrl=\"\($0.feedUrl ?? "")\"/>" }
        return "<?xml version=\"1.0\"?><opml version=\"2.0\"><body>\(outlines.joined())</body></opml>"
    }

    func lyricsProviders() async throws -> [LyricsProvider] {
        [LyricsProvider(id: "lrclib", name: "LRCLIB", on: true), LyricsProvider(id: "youtube", name: "YouTube Music", on: true),
         LyricsProvider(id: "netease", name: "Netease Cloud Music", on: false)]
    }
    func chooseLyricsSource(videoId: String, title: String, artists: String, duration: Double?, source: String?) async throws -> Lyrics? {
        guard var l = try await getLyrics(videoId: videoId, title: title, artists: artists, duration: duration) else { return nil }
        if let source { l.provider = source; l.pinned = true } else { l.pinned = false }
        return l
    }
    func setLyricsOffset(videoId: String, offsetMs: Int) async throws -> Int { max(-15_000, min(15_000, offsetMs)) }

    func importResolve(link: String) async throws -> SpotifyResolved {
        await pause()
        let l = link.lowercased()
        if l.contains("/track/"), let s = withLock({ pool.first }) { return .song(s) }
        if l.contains("/album/") { return .album("MPREb_mock") }
        if l.contains("/artist/") { return .artist("UCmock") }
        return .playlist
    }
    func libExport(path: String) async throws -> LibraryExportReport {
        let n = withLock { (liked.count, playlists.count) }
        FileManager.default.createFile(atPath: path, contents: Data("PK".utf8))
        return LibraryExportReport(path: path, likedSongs: n.0, playlists: n.1)
    }
}
