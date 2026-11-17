// DEV ONLY: stream: audiobooks — the mock's LibriVox books (two fixture books, saved set and
// chapter progress in memory). Same shapes as `crates/core/src/audiobooks`.
import Foundation

private let mockBooksLock = NSLock()
nonisolated(unsafe) private var mockSavedBooks: [String] = []

extension MockCoreClient {
    static let mockBooks: [Audiobook] = [
        Audiobook(id: "pride_and_prejudice_librivox", title: "Pride and Prejudice", author: "Jane Austen", narrator: "Various narrators",
                  thumbnail: "https://archive.org/services/img/pride_and_prejudice_librivox",
                  description: "Pride and Prejudice is the most famous of Jane Austen's novels, and its opening is one of the most famous lines in English literature.",
                  durationSecs: 47204, chapterCount: 6, genres: ["Romance"], language: "English", saved: false),
        Audiobook(id: "adventures_holmes", title: "The Adventures of Sherlock Holmes", author: "Sir Arthur Conan Doyle", narrator: "Ruth Golding",
                  thumbnail: "https://archive.org/services/img/adventures_holmes",
                  description: "Twelve stories of the great detective.", durationSecs: 37800, chapterCount: 6, genres: ["Mystery"], language: "English", saved: false),
    ]

    private func mockChapters(_ b: Audiobook) -> [PodcastEpisode] {
        (1...6).map { i in
            let url = "https://archive.org/download/\(b.id)/chapter_\(i)_64kb.mp3"
            let id = "PODURL:\(url)"
            let p = withLock { fs.progress[id] } ?? EpisodeProgress(positionSecs: 0, durationSecs: 0, fraction: 0, played: false, updatedAt: 0)
            return PodcastEpisode(id: id, showId: "abook:\(b.id)", showTitle: b.title, title: "Chapter \(i)", publishedAt: nil,
                                  durationSecs: 900 + Double(i * 60), description: nil, thumbnail: b.thumbnail, videoId: nil,
                                  enclosureUrl: url, guid: nil, isVideo: false, progress: p, saved: false)
        }
    }

    /// Dev only, roughly the core's rule: the started chapter, else the first unheard one.
    private func mockResume(_ ch: [PodcastEpisode]) -> AudiobookResume {
        if let i = ch.firstIndex(where: { $0.progress.started }) { return AudiobookResume(index: i, started: true, finished: false) }
        let any = ch.contains { $0.progress.played }
        return AudiobookResume(index: any ? (ch.firstIndex { !$0.progress.played } ?? 0) : 0, started: any, finished: false)
    }

    private func savedFlag(_ b: Audiobook) -> Audiobook {
        var b = b
        b.saved = mockBooksLock.withLock { mockSavedBooks.contains(b.id) }
        return b
    }

    func audiobookSearch(query: String) async throws -> [Audiobook] {
        let q = query.lowercased()
        return Self.mockBooks.filter { $0.title.lowercased().contains(q) || $0.author.lowercased().contains(q) || q.isEmpty }.map(savedFlag)
    }

    func audiobookHome() async throws -> [Shelf] {
        let card = { (b: Audiobook) in ShelfItem(kind: "audiobook", id: b.id, title: b.title, subtitle: b.author, thumbnail: b.thumbnail, explicit: false) }
        let genres = [("mystery", "Mystery", "#8c1932"), ("romance", "Romance", "#e8115b"), ("adventure", "Adventure", "#27856a"), ("children", "Kids", "#e13300")]
        var out: [Shelf] = []
        let saved = try await audiobookSaved()
        if !saved.isEmpty { out.append(Shelf(id: "ab_saved", title: "Your audiobooks", layout: .cards, source: "local", items: saved.map(card))) }
        out.append(Shelf(id: "ab_popular", title: "Popular audiobooks", layout: .cards, source: "youtube", items: Self.mockBooks.map(card)))
        out.append(Shelf(id: "ab_genres", title: "Browse by genre", layout: .moods, source: "local",
                         items: genres.enumerated().map { i, g in
                             // The core's rule: a genre's top book is its tile's art.
                             ShelfItem(kind: "audiobook_genre", id: g.0, title: g.1, thumbnail: Self.mockBooks[i % Self.mockBooks.count].thumbnail,
                                       explicit: false, params: g.0, color: g.2)
                         }))
        out.append(Shelf(id: "ab_genre:mystery", title: "Mystery", subtitle: "Audiobooks", layout: .cards, source: "youtube", items: [card(Self.mockBooks[1])]))
        return out
    }

    func audiobookGenre(genre: String) async throws -> [Audiobook] { Self.mockBooks.map(savedFlag) }

    func audiobookPage(id: String) async throws -> AudiobookPage {
        guard let b = Self.mockBooks.first(where: { $0.id == id }) else { throw CoreFailure(message: "This audiobook has no chapters to play") }
        let ch = mockChapters(b)
        return AudiobookPage(book: savedFlag(b), chapters: ch, resume: mockResume(ch), librivoxUrl: "https://librivox.org/")
    }

    func audiobookForChapter(id: String) async throws -> AudiobookPage? {
        guard let b = Self.mockBooks.first(where: { id.contains("/\($0.id)/") }) else { return nil }
        return try await audiobookPage(id: b.id)
    }

    func audiobookSave(_ book: Audiobook, saved: Bool) async throws {
        mockBooksLock.withLock {
            mockSavedBooks.removeAll { $0 == book.id }
            if saved { mockSavedBooks.insert(book.id, at: 0) }
        }
    }

    func audiobookSaved() async throws -> [Audiobook] {
        let ids = mockBooksLock.withLock { mockSavedBooks }
        return ids.compactMap { id in Self.mockBooks.first { $0.id == id } }.map { var b = $0; b.saved = true; return b }
    }
}
