// Desktop features ported to iPhone (parity audit): Spotify links, Settings › Podcasts, the lyrics
// ⋯ menu's model, Export library.
import XCTest
@testable import Encore

@MainActor
final class ParityPortTests: XCTestCase {
    private func model() async -> AppModel {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        return app
    }

    func testResolvedDecodesTheCoresShapes() throws {
        let d = JSONDecoder()
        XCTAssertEqual(try d.decode(SpotifyResolved.self, from: Data(#"{"kind":"album","id":"MPREb_x"}"#.utf8)), .album("MPREb_x"))
        XCTAssertEqual(try d.decode(SpotifyResolved.self, from: Data(#"{"kind":"artist","id":"UCx"}"#.utf8)), .artist("UCx"))
        XCTAssertEqual(try d.decode(SpotifyResolved.self, from: Data(#"{"kind":"playlist"}"#.utf8)), .playlist)
        let song = try d.decode(SpotifyResolved.self, from: Data(#"{"kind":"song","song":{"video_id":"v1","title":"T","artists":"A"}}"#.utf8))
        guard case .song(let s) = song else { return XCTFail("not a song") }
        XCTAssertEqual(s.videoId, "v1")
    }

    func testSpotifyTrackLinkPlaysTheMatch() async throws {
        let app = await model()
        app.router.openWebLink(URL(string: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")!, app: app)
        for _ in 0..<40 where !app.router.nowPlayingOpen { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(app.router.nowPlayingOpen)
        XCTAssertFalse(app.importOpen)
    }

    func testSpotifyAlbumAndArtistLinksOpenPages() async throws {
        let app = await model()
        app.router.openWebLink(URL(string: "https://open.spotify.com/album/abc")!, app: app)
        for _ in 0..<40 where app.router.paths[app.router.tab]?.last != .album("MPREb_mock") { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(app.router.paths[app.router.tab]?.last, .album("MPREb_mock"))
        app.router.openWebLink(URL(string: "https://open.spotify.com/artist/xyz")!, app: app)
        for _ in 0..<40 where app.router.paths[app.router.tab]?.last != .artist("UCmock") { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(app.router.paths[app.router.tab]?.last, .artist("UCmock"))
        XCTAssertFalse(app.importOpen)
    }

    func testSpotifyPlaylistLinkStillImports() async throws {
        let app = await model()
        app.router.openWebLink(URL(string: "https://open.spotify.com/playlist/37i9")!, app: app)
        for _ in 0..<40 where !app.importOpen { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(app.importOpen)
    }

    func testPodcastSettingsPatchAndOpml() async throws {
        let core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        let s = try await core.podcastSetSettings(sponsorblock: true, categories: ["intro", "outro"])
        XCTAssertEqual(s, PodcastSettings(sponsorblock: true, sponsorblockCategories: ["intro", "outro"]))
        let s2 = try await core.podcastSetSettings(sponsorblock: false, categories: nil)
        XCTAssertEqual(s2.sponsorblockCategories, ["intro", "outro"], "nil leaves the categories alone")
        let twins = try await core.podcastSetYouTubeMatch(false)
        let read = try await core.podcastYouTubeMatch()
        XCTAssertFalse(twins || read)
        let r = try await core.podcastOpmlImport(xml: #"<opml><body><outline xmlUrl="https://a/f.xml"/></body></opml>"#)
        XCTAssertEqual(r.added, 1)
        do { _ = try await core.podcastOpmlImport(xml: "nope"); XCTFail("no feeds should throw") } catch {}
    }

    func testLyricsPickAndNudge() async throws {
        let app = await model()
        app.player.playSingle(SongItem(videoId: "v1", title: "One More Time", artists: "Daft Punk"))
        for _ in 0..<40 where app.player.current == nil { try await Task.sleep(for: .milliseconds(50)) }
        let m = LyricsModel()
        await m.load(app)
        guard m.lyrics != nil else { return XCTFail("mock lyrics missing") }
        await m.pickSource("lrclib", app)
        XCTAssertEqual(m.lyrics?.provider, "lrclib")
        XCTAssertEqual(m.lyrics?.pinned, true)
        await m.nudge(500, app)
        await m.nudge(500, app)
        XCTAssertEqual(m.lyrics?.offsetMs, 1000)
        await m.nudge(-(m.lyrics?.offsetMs ?? 0), app)
        XCTAssertEqual(m.lyrics?.offsetMs, 0)
        XCTAssertEqual(LyricsMenu.secs(500), "+0.5 s")
        XCTAssertEqual(LyricsMenu.secs(-1500), "-1.5 s")
    }

    func testLyricsDecodePinned() throws {
        let l = try JSONDecoder().decode(Lyrics.self, from: Data(#"{"source":"LRCLIB","provider":"lrclib","synced":true,"instrumental":false,"lines":[],"pinned":true,"offset_ms":250}"#.utf8))
        XCTAssertEqual(l.pinned, true)
        XCTAssertEqual(l.offsetMs, 250)
    }

    func testLibraryExportWritesTheZip() async throws {
        let core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("export-test.zip").path
        let r = try await core.libExport(path: path)
        XCTAssertEqual(r.path, path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}

final class ParityPortSnapshotTests: SnapshotCase {
    func testPodcastsSettings() async { await snap("encore://settings/podcasts") }
    func testPodcastsSettingsAllCategories() async {
        await snap(setup: { app in
            _ = try? await app.core.podcastSetSettings(sponsorblock: true, categories: sponsorBlockCategories.map(\.id))
            app.router.push(.settings)
            app.router.push(.settingsPage(.podcasts))
        }, wait: 1.2)
    }
}
