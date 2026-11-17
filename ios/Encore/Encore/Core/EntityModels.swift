// Stream magic-ib: what the entity pages need beyond Models.swift. The playlist footer's
// recommendations (api.ts `Recommendation`), the in-playlist find and sort, and the artist
// discography (the core's).
import Foundation
import EncoreCore

/// One "Recommended" row under your own playlist (`playlist_recommendations`).
struct Recommendation: Codable, Hashable {
    var song: SongItem
    /// How many of the playlist's seed songs recommended it.
    var votes: Int
    /// The seed titles that did.
    var because: [String]
    /// `listening`: the playlist had nothing to seed from, so these come from what you play.
    var basis: String? = nil
}

/// The order a playlist page shows its rows in (Spotify iOS: Sort by). `custom` is the list's own
/// order. Remembered per playlist on this phone.
enum PlaylistViewSort: String, CaseIterable, Identifiable {
    case custom, title, artist, album, recentlyAdded = "recent"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .custom: "Custom order"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .recentlyAdded: "Recently added"
        }
    }

    /// The options a list offers: Liked Songs is already newest first and has no custom order.
    static func options(liked: Bool) -> [PlaylistViewSort] {
        liked ? [.recentlyAdded, .title, .artist, .album] : allCases
    }

    /// The core's `PlaylistSort` name for this order (YouTube stores it on playlists you own).
    var server: String {
        switch self {
        case .custom: "default"
        case .title: "title"
        case .artist: "artist"
        case .album: "album"
        case .recentlyAdded: "newest"
        }
    }

    private static func key(_ playlistId: String) -> String { "ios_playlist_sort.\(playlistId)" }
    static func stored(for playlistId: String, defaults: UserDefaults = .standard) -> PlaylistViewSort? {
        defaults.string(forKey: key(playlistId)).flatMap(PlaylistViewSort.init(rawValue:))
    }
    static func store(_ s: PlaylistViewSort?, for playlistId: String, defaults: UserDefaults = .standard) {
        if let s { defaults.set(s.rawValue, forKey: key(playlistId)) } else { defaults.removeObject(forKey: key(playlistId)) }
    }

    /// `items` in this order. `addedAt` (videoId → when it was added) feeds Recently added; without
    /// it the list's own order is taken as oldest first. Ties keep the list's order (stable).
    func apply(_ items: [SongItem], addedAt: [String: Int64]? = nil) -> [SongItem] {
        func by(_ key: (SongItem) -> String) -> [SongItem] {
            items.enumerated().sorted { a, b in
                let c = key(a.element).compare(key(b.element), options: [.caseInsensitive, .numeric, .diacriticInsensitive], locale: .current)
                return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
            }.map(\.element)
        }
        switch self {
        case .custom: return items
        case .title: return by(\.title)
        case .artist: return by(\.artists)
        case .album: return by { $0.album ?? "" }
        case .recentlyAdded:
            guard let addedAt else { return items.reversed() }
            return items.enumerated().sorted { a, b in
                let x = addedAt[a.element.videoId] ?? 0, y = addedAt[b.element.videoId] ?? 0
                return x == y ? a.offset > b.offset : x > y
            }.map(\.element)
        }
    }
}

/// Find in playlist: case-insensitive over title, artists and album (the desktop's `matchSong`).
func matchSong(_ s: SongItem, _ q: String) -> Bool {
    let n = q.trimmingCharacters(in: .whitespaces)
    if n.isEmpty { return true }
    return [s.title, s.artists, s.album ?? ""].contains { $0.range(of: n, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
}

// MARK: lane D1's commands (radio page, credits)

/// A radio as a playlist page, before anything plays (`radio_tracks`; api `RadioPage`).
struct RadioPage: Codable, Hashable {
    var title: String
    /// The radio playlist YouTube answered with; play it as the queue's source so Autoplay stays on it.
    var playlistId: String
    var seed: SongItem?
    var thumbnail: String?
    /// "With <artists>".
    var description: String?
    var items: [SongItem]
}

/// "Show credits" (`song_credits`): role sections ("Written by") with their people.
struct SongCredits: Codable, Hashable {
    struct Person: Codable, Hashable { var name: String; var artistId: String? }
    struct Section: Codable, Hashable { var title: String; var people: [Person] }
    /// One row per person with every role they had, in credit order (the core's
    /// `credits::credit_people`): the Now Playing card.
    struct Row: Codable, Hashable { var name: String; var artistId: String?; var roles: [String] }
    var sections: [Section]
    /// The label that supplied the data (Spotify's "Source").
    var source: String?
    var people: [Row]
}

// MARK: discography

/// An artist's discography in Spotify's chips, from the core (`crates/core/src/discography.rs`,
/// shared with the desktop): release types, compilations, Popular releases and the card lines.
/// Every list is newest first; an empty one is a chip to leave out.
struct Discography: Codable, Hashable {
    struct Release: Codable, Hashable, Identifiable {
        var item: BrowseItem
        var type: String
        var year: Int
        /// "1997 • Album", "Latest Release • Single".
        var line: String
        var id: String { item.id }
    }
    var popular: [Release]
    var all: [Release]
    var album: [Release]
    var single: [Release]
    var compilation: [Release]
    /// Shown on the full page; not the core's.
    var artistName = ""

    private enum CodingKeys: String, CodingKey { case popular, all, album, single, compilation }

    static let empty = Discography(popular: [], all: [], album: [], single: [], compilation: [])

    enum Filter: String, CaseIterable, Identifiable {
        case popular, albums, singles, compilations
        var id: String { rawValue }
        var title: String {
            switch self {
            case .popular: "Popular releases"
            case .albums: "Albums"
            case .singles: "Singles and EPs"
            case .compilations: "Compilations"
            }
        }
    }

    func items(_ f: Filter) -> [Release] {
        switch f {
        case .popular: popular
        case .albums: album
        case .singles: single
        case .compilations: compilation
        }
    }

    /// The chips worth showing (a filter with nothing in it is left out).
    var filters: [Filter] { Filter.allCases.filter { !items($0).isEmpty } }

    /// The core's `discography` for these release cards and top songs (pure, no running core
    /// needed, so the mock client gets the same chips).
    static func build(albums: [BrowseItem], singles: [BrowseItem], topSongs: [SongItem], artistName: String = "") -> Discography {
        struct Args: Encodable { var albums: [BrowseItem]; var singles: [BrowseItem]; var topSongs: [SongItem] }
        guard let json = try? JSONEncoder().encode(Args(albums: albums, singles: singles, topSongs: topSongs)),
              let out = try? discography(argsJson: String(decoding: json, as: UTF8.self)),
              var d = try? JSONDecoder().decode(Discography.self, from: Data(out.utf8)) else { return .empty }
        d.artistName = artistName
        return d
    }

    /// From an artist page's own shelves (no extra requests).
    static func of(_ page: ArtistPage) -> Discography {
        build(albums: page.shelf("albums")?.items ?? [], singles: page.shelf("singles")?.items ?? [],
              topSongs: page.topSongs, artistName: page.name ?? "")
    }
}

extension ArtistPage {
    /// The shelf the core marked `kind` (`albums`, `singles`, …).
    func shelf(_ kind: String) -> ArtistCarousel? { sections.first { $0.kind == kind } }
}

/// The collection meta line, as the desktop writes it (`collections/format.ts`): "7 songs, 25 min
/// 6 sec", "30 songs, 1 hr 32 min"; playlists (`approx`) say "about 3 hr 30 min" past an hour, and
/// long lists round to "about 11 hr".
enum CollectionMeta {
    static func total(_ secs: Int, count: Int, approx: Bool = false) -> String {
        guard secs > 0 else { return "" }
        let h = secs / 3600, m = secs % 3600 / 60, s = secs % 60
        if h == 0 { return s > 0 ? "\(m) min \(s) sec" : "\(m) min" }
        if count > 100 || h >= 10 { return "about \(m >= 30 ? h + 1 : h) hr" }
        let exact = m > 0 ? "\(h) hr \(m) min" : "\(h) hr"
        return approx ? "about \(exact)" : exact
    }

    static func songs(_ songs: [SongItem], count: Int? = nil, approx: Bool = false) -> String {
        let n = count ?? songs.count
        guard n > 0 else { return "" }
        let label = n == 1 ? "1 song" : "\(n.formatted(.number.locale(Locale(identifier: "en_US")))) songs"
        let d = total(Int(songs.reduce(0) { $0 + $1.seconds }), count: n, approx: approx)
        return d.isEmpty ? label : "\(label), \(d)"
    }
}
