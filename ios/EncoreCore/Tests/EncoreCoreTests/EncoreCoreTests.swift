import XCTest
@testable import EncoreCore

/// Collects the core's events (the same names/JSON as the desktop UI receives).
final class Events: EventListener, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var names: [String] = []
    func onEvent(name: String, json: String) {
        lock.lock(); names.append(name); lock.unlock()
    }
}

/// Live: talks to YouTube. S2 gate (plan §6 step 1): search + a playable stream via VISIONOS,
/// from Swift, through the real core on the iOS simulator.
final class EncoreCoreTests: XCTestCase {
    static var core: EncoreCore!
    static let events = Events()

    override class func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("encore-core-test-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try! FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        core = try! EncoreCore(config: CoreConfig(dataDir: data.path, cacheDir: cache.path), listener: events)
    }

    func testSearchThenResolveVisionosStream() async throws {
        let t0 = Date()
        let songs = try await Self.core.search(query: "Rick Astley Never Gonna Give You Up", recordHistory: false)
        XCTAssertFalse(songs.isEmpty, "search returned nothing")
        let song = try XCTUnwrap(songs.first)
        print("search: \(songs.count) songs in \(Date().timeIntervalSince(t0))s; first: \(song.title) — \(song.artists) [\(song.videoId)]")
        XCTAssertEqual(song.videoId.count, 11)

        let t1 = Date()
        let stream = try await Self.core.resolveStream(videoId: song.videoId, client: "VISIONOS")
        print("resolve: \(stream.client) itag \(stream.itag) in \(Date().timeIntervalSince(t1))s, expires in \(stream.expiresInSeconds)s")
        XCTAssertEqual(stream.client, "VISIONOS")
        XCTAssertTrue(stream.url.contains("googlevideo.com"), stream.url)

        // Playable: googlevideo serves real audio bytes for a range in the middle of the file.
        var req = URLRequest(url: try XCTUnwrap(URL(string: stream.url)))
        for (k, v) in stream.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=1000000-1065535", forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        print("range GET: HTTP \(http.statusCode), \(data.count) bytes")
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data.count, 65536)

        // The normal chain on iOS tries the direct clients before WEB_REMIX (plan §3).
        let t2 = Date()
        let auto = try await Self.core.resolveStream(videoId: song.videoId, client: nil)
        print("resolve (chain): \(auto.client) itag \(auto.itag) in \(Date().timeIntervalSince(t2))s")
        XCTAssertEqual(auto.client, "VISIONOS")
    }

    func testPagesLibraryAndSettings() async throws {
        let songs = try await Self.core.search(query: "Daft Punk Get Lucky", recordHistory: false)
        let song = try XCTUnwrap(songs.first)
        if let albumId = song.albumId {
            let album = try await Self.core.albumJson(id: albumId)
            let obj = try JSONSerialization.jsonObject(with: Data(album.utf8)) as? [String: Any]
            XCTAssertNotNil(obj?["items"], "album page has no items")
        }
        if let artistId = song.artistId {
            let artist = try await Self.core.artistJson(id: artistId)
            XCTAssertTrue(artist.contains("\""), "artist page is not JSON")
        }

        // Local library: like → Liked Songs → unlike.
        let added = try await Self.core.like(songsJson: [song.json])
        XCTAssertEqual(added, [true])
        let liked = try await Self.core.likedSongsJson()
        XCTAssertTrue(liked.contains(song.videoId))
        let likedPage = try await Self.core.playlistJson(id: "VLLM")
        XCTAssertTrue(likedPage.contains(song.videoId), "Liked Songs page misses the like")
        try await Self.core.unlike(videoIds: [song.videoId])
        let likedAfter = try await Self.core.likedSongsJson()
        XCTAssertFalse(likedAfter.contains(song.videoId))

        // A library playlist.
        let created = try await Self.core.createPlaylist(name: "S2 test")
        let pl = try JSONSerialization.jsonObject(with: Data(created.utf8)) as! [String: Any]
        let plId = try XCTUnwrap(pl["id"] as? String)
        try await Self.core.addToPlaylist(playlistId: plId, songsJson: [song.json])
        let playlists = try await Self.core.playlistsJson()
        XCTAssertTrue(playlists.contains("S2 test"))

        // Settings round trip, and library edits were announced.
        try await Self.core.setSetting(key: "autoplay", value: "false")
        let settings = try await Self.core.settingsJson()
        XCTAssertTrue(settings.contains("\"autoplay\":\"false\""), settings)
        XCTAssertTrue(Self.events.names.contains("library-changed"))
        // The queue is reachable even with nothing playing.
        _ = try await Self.core.queueJson()
    }
}
