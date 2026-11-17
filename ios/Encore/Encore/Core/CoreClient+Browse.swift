// Stream ios-sync2: Search › Browse's Charts and New releases pages, a genre/mood page as titled
// shelves, and the artist page's Appears on (`get_charts`, `get_new_releases`,
// `get_browse_sections`, `get_artist_appears_on`), real and mock. Models mirror api.ts.
import Foundation

struct ChartCountry: Codable, Hashable { var code: String; var name: String }

/// A card on a chart shelf, with its place (`rank`) and movement (`trend`: up | down | new | neutral).
struct ChartEntry: Codable, Hashable, Identifiable {
    var item: BrowseItem
    var rank: Int?
    var trend: String?
    var id: String { item.id }

    private enum K: String, CodingKey { case rank, trend }
    init(from decoder: Decoder) throws {
        item = try BrowseItem(from: decoder)
        let c = try decoder.container(keyedBy: K.self)
        rank = try c.decodeIfPresent(Int.self, forKey: .rank)
        trend = try c.decodeIfPresent(String.self, forKey: .trend)
    }
    func encode(to encoder: Encoder) throws {
        try item.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(rank, forKey: .rank)
        try c.encodeIfPresent(trend, forKey: .trend)
    }
}

/// `kind`: video_charts | genres | top_artists | top_podcasts | other.
struct ChartSection: Codable, Hashable { var kind: String; var title: String; var items: [ChartEntry] }
struct ChartHighlights: Codable, Hashable { var topSongs: BrowseItem?; var topVideos: BrowseItem?; var trending: BrowseItem? }

struct ChartsPage: Codable {
    var country: ChartCountry?
    var countries: [ChartCountry]
    var highlights: ChartHighlights
    var sections: [ChartSection]
    /// Top songs · Top videos · Trending: the page's first shelf.
    var featured: [BrowseItem] { [highlights.topSongs, highlights.topVideos, highlights.trending].compactMap { $0 } }
}

/// `sections[].kind`: albums | videos.
struct NewReleasesPage: Codable { var mix: BrowseItem?; var sections: [HomeSection] }
struct SectionsPage: Codable { var title: String?; var sections: [HomeSection] }

extension RealCoreClient {
    /// `country`: ISO alpha-2 (`ZZ` = Global), remembered by the core once picked; nil = the last one.
    func getCharts(country: String?) async throws -> ChartsPage { try await call("get_charts", ["country": country]) }
    func getNewReleases() async throws -> NewReleasesPage { try await call("get_new_releases") }
    func getBrowseSections(browseId: String, params: String?) async throws -> SectionsPage {
        try await call("get_browse_sections", ["browseId": browseId, "params": params])
    }
    func getArtistAppearsOn(id: String, songsId: String) async throws -> [BrowseItem] {
        try await call("get_artist_appears_on", ["id": id, "songsId": songsId], as: Lossy<BrowseItem>.self).items
    }
}

extension MockCoreClient {
    func getCharts(country: String?) async throws -> ChartsPage {
        await pause()
        guard var page: ChartsPage = get("charts") else { throw MockError.missing("charts") }
        if let c = page.countries.first(where: { $0.code == country?.uppercased() }) { page.country = c }
        return page
    }
    func getNewReleases() async throws -> NewReleasesPage {
        await pause()
        guard let page: NewReleasesPage = get("new_releases") else { throw MockError.missing("new_releases") }
        return page
    }
    func getBrowseSections(browseId: String, params: String?) async throws -> SectionsPage {
        await pause()
        guard let page: SectionsPage = get("genre_sections") else { throw MockError.missing("genre_sections") }
        return page
    }
    /// The captured artists appear on nothing, so the mock lends a few albums from search.
    func getArtistAppearsOn(id: String, songsId: String) async throws -> [BrowseItem] {
        let fixed: [BrowseItem] = get("artist_appears_on_\(index("artist_index")[id] ?? "daft_punk")") ?? []
        return fixed.isEmpty ? Array(((get("search_all_radiohead") as SearchResults?)?.albums ?? []).prefix(4)) : fixed
    }
}

/// YouTube's moods & genres category: what a Browse all tile opens.
let moodsCategoryId = "FEmusic_moods_and_genres_category"
