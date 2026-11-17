// stream: audiobooks — the book models decode the core's JSON, the saved-books store, the genre
// grid ids, and (with TEST_RUNNER_ENCORE_LIVE=1) the real core against the Internet Archive.
import XCTest
@testable import Encore
import EncoreCore

@MainActor
final class AudiobookTests: XCTestCase {
    /// The shape `audiobook_page` answers (crates/core/src/audiobooks): camelCase, nullable extras.
    func testPageDecodesCoreJson() throws {
        let json = """
        {"book":{"id":"pride_and_prejudice_librivox","title":"Pride and Prejudice","author":"Jane Austen","narrator":"Various narrators",
         "thumbnail":"https://archive.org/download/x/c.jpg","description":"A novel.","durationSecs":47204,"chapterCount":2,
         "genres":["Romance"],"language":"English","saved":true,"progress":0.25},
         "chapters":[{"id":"PODURL:https://archive.org/download/x/1.mp3","showId":"abook:pride_and_prejudice_librivox","showTitle":"Pride and Prejudice",
           "title":"Chapters 1-3","publishedAt":null,"durationSecs":1132,"description":null,"thumbnail":null,"videoId":null,
           "enclosureUrl":"https://archive.org/download/x/1.mp3","guid":null,"isVideo":false,
           "progress":{"positionSecs":300,"durationSecs":1132,"fraction":0.26,"played":false,"updatedAt":1700000000},"saved":false}],
         "resume":{"index":0,"started":true,"finished":false},"librivoxUrl":null}
        """
        let p = try JSONDecoder().decode(AudiobookPage.self, from: Data(json.utf8))
        XCTAssertEqual(p.book.narrator, "Various narrators")
        XCTAssertEqual(p.book.progress, 0.25)
        XCTAssertEqual(p.chapters.first?.song.isEpisode, true)
        XCTAssertEqual(audiobookId(fromShow: p.chapters.first?.showId), "pride_and_prejudice_librivox")
        XCTAssertNil(audiobookId(fromShow: "https://feed"))
        XCTAssertTrue(p.resume.started)
        XCTAssertEqual(p.book.card.kind, .audiobook)
    }

    func testSaveToggleAndGenreIds() async throws {
        let core = MockCoreClient()
        let store = AudiobookStore(core: core)
        let book = MockCoreClient.mockBooks[0]
        XCTAssertTrue(store.toggleSaved(book))
        try await Task.sleep(nanoseconds: 200_000_000)
        await store.refresh()
        XCTAssertEqual(store.saved.map(\.id), [book.id])
        XCTAssertFalse(store.toggleSaved(book))
        try await Task.sleep(nanoseconds: 200_000_000)
        await store.refresh()
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(ShelfGridView.audiobookGenre("abgenre:science fiction"), "science fiction")
        XCTAssertEqual(ShelfGridView.audiobookGenre("ab_genre:mystery"), "mystery")
        XCTAssertEqual(ShelfGridView.audiobookGenre("ab_popular"), "popular")
        XCTAssertNil(ShelfGridView.audiobookGenre("podcat:1303"))
        XCTAssertEqual(HomeStore.shortcut(for: PlayContext(kind: .audiobook, id: book.id, title: book.title), thumbnail: nil)?.kind, "audiobook")
    }

    /// Live: search, the book page with its chapters, the chapter → book lookup, save.
    func testRealCoreAudiobooks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENCORE_LIVE"] == "1", "live test: set TEST_RUNNER_ENCORE_LIVE=1")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("encore-books-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let core = try RealCoreClient(config: CoreConfig(dataDir: data.path, cacheDir: cache.path, exportDir: base.path),
                                      secrets: KeychainStore(service: "app.encore.ios.test"))
        let books = try await core.audiobookSearch(query: "Pride and Prejudice")
        XCTAssertEqual(books.first?.title, "Pride and Prejudice")
        XCTAssertEqual(books.first?.author, "Jane Austen")
        let page = try await core.audiobookPage(id: books[0].id)
        XCTAssertGreaterThan(page.chapters.count, 30)
        XCTAssertEqual(page.chapters[2].title, "Chapter 6")
        XCTAssertNotNil(page.book.narrator)
        let back = try await core.audiobookForChapter(id: page.chapters[2].id)
        XCTAssertEqual(back?.book.id, page.book.id)
        try await core.audiobookSave(page.book, saved: true)
        let saved = try await core.audiobookSaved()
        XCTAssertEqual(saved.first?.id, page.book.id)
        let home = try await core.audiobookHome()
        XCTAssertTrue(home.contains { $0.id == "ab_popular" && !$0.items.isEmpty })
        XCTAssertTrue(home.contains { $0.id == "ab_genres" })
        print("AUDIOBOOK live: \(page.book.title) by \(page.book.author), read by \(page.book.narrator ?? "-"), \(page.chapters.count) chapters; home: \(home.map(\.title))")
    }
}
