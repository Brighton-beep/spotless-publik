// The second parity audit's iPhone gaps: offline Home from the core, Home's loading / error /
// empty states and "Your shows", empty Liked Songs and playlists, the import's destination and
// rename, the first-run import rule, Made for you's shelves, the five streaming qualities, lyrics
// timing and attribution, Recently played's context grid, and the shared Browse tile colours.
import XCTest
import SwiftUI
@testable import Encore

final class ParityGaps2SnapshotTests: SnapshotCase {
    // 1. Offline Home: the core's notice, then only what's on the phone.
    func testHomeOfflineNotice() async {
        await snap("encore://download/LOCALPLAYLIST:1", "encore://home", "encore://offline?on=1", wait: 1.5)
    }

    func testHomeOfflineNothingDownloaded() async {
        await snap("encore://home", setup: { app in
            try? await app.core.downloadsRemove(id: "LOCALPLAYLIST:1")
            await app.downloads.refresh()
            app.router.handle(URL(string: "encore://offline?on=1")!, app: app)
            try? await Task.sleep(for: .milliseconds(600))
        }, wait: 1.5)
    }

    // 2. Home's states.
    func testHomeLoading() async {
        await snap("encore://home", setup: { app in app.home.shelves = []; app.home.loaded = false; app.home.failed = false })
    }

    func testHomeError() async {
        await snap("encore://home", setup: { app in app.home.shelves = []; app.home.loaded = false; app.home.failed = true })
    }

    func testHomeEmpty() async {
        await snap("encore://home", setup: { app in app.settings.madeForYou = []; app.home.shelves = []; app.home.loaded = true; app.home.failed = false })
    }

    // 3. Your shows, after the second shelf on All.
    func testHomeYourShows() async {
        await snap("encore://home", setup: { app in
            await app.podcasts.refresh()
            self.window.frame = CGRect(x: 0, y: 0, width: self.window.frame.width, height: 2300)
        }, wait: 1.5)
        XCTAssertFalse(app.podcasts.follows.isEmpty, "the mock follows shows")
    }

    // 4. Empty Liked Songs.
    func testLikedSongsEmpty() async {
        await snap("encore://home", setup: { app in
            let ids = Array(app.library.likedIds)
            for id in ids { try? await app.core.setLiked(SongItem(videoId: id, title: "", artists: ""), liked: false) }
            await app.library.refresh()
            app.router.handle(URL(string: "encore://liked")!, app: app)
            try? await Task.sleep(for: .milliseconds(800))
        }, wait: 1.2)
    }

    // 5. Import review, signed in, one playlist: the name and where it goes.
    func testImportReviewDestination() async {
        _ = try? await app.account.complete(with: [HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SAPISID", .value: "s"])!])
        await snap("encore://import", setup: { app in
            let f = ImportFlow.shared
            f.live = false
            await f.readFile(URL(fileURLWithPath: "/tmp/my_spotify_data.zip"), app)
            await f.start(app)
            for _ in 0..<40 where (try? await app.core.importStatus())?.phase != "review" {
                try? await Task.sleep(for: .milliseconds(150))
            }
            f.snapshot = try? await app.core.importStatus()
            if let first = f.snapshot?.lists.first(where: { $0.kind == "playlist" }) { f.snapshot?.lists = [first] }
            await f.openReview(app)
        }, wait: 1.2)
        XCTAssertTrue(app.account.signedIn)
        XCTAssertFalse(ImportFlow.shared.name.isEmpty, "a single playlist starts with its own name")
        ImportFlow.shared.reset()
    }

    // 7. Made for you's shelves.
    func testMadeForYouPage() async { await snap("encore://made-for-you", wait: 1.5) }

    // 11. Recently played: the context grid, then the songs.
    func testRecentlyPlayed() async {
        await snap("encore://history", setup: { _ in
            self.window.frame = CGRect(x: 0, y: 0, width: self.window.frame.width, height: 2600)
        }, wait: 1.5)
    }
}

@MainActor
final class ParityGaps2Tests: XCTestCase {
    private func mockApp() async -> AppModel {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)), prefs: .some(nil))
        await app.start()
        return app
    }

    /// 1. Offline, the (mock) core's Home is the notice and your downloads.
    func testOfflineHomeComesFromTheCore() async throws {
        let app = await mockApp()
        _ = try await app.core.downloadsSetSettings(DownloadSettingsPatch(offlineMode: true))
        await app.home.load { true }
        XCTAssertEqual(app.home.shelves.first?.layout, .notice)
        XCTAssertEqual(app.home.shelves.first?.title, "You're offline")
        XCTAssertFalse(app.home.shelves.contains { $0.source == "youtube" }, "nothing that needs YouTube")
        XCTAssertEqual(HomeStore.musicOnly(app.home.shelves).first?.layout, .notice, "Music keeps the notice")
    }

    /// 2. A load that answered stops the skeletons, even with nothing in it.
    func testHomeLoadMarksLoaded() async {
        let app = await mockApp()
        XCTAssertFalse(app.home.loaded)
        await app.home.load { true }
        XCTAssertTrue(app.home.loaded)
        XCTAssertFalse(app.home.failed)
    }

    /// 6. One rule: an empty library and an unanswered offer.
    func testImportOfferRule() async {
        let app = await mockApp()
        let offered = await app.shouldOfferImport()
        XCTAssertFalse(offered, "the mock library isn't empty")
        app.importOfferAnswered()
        try? await Task.sleep(for: .milliseconds(100))
        let settings = try? await app.core.getSettings()
        XCTAssertEqual(settings?[SettingKey.importDone], "true")
    }

    /// 9. The desktop's attribution line.
    func testLyricsAttribution() {
        let l = Lyrics(source: "Source: LRCLIB", provider: "lrclib", synced: true, instrumental: false, lines: [])
        XCTAssertEqual(lyricsAttribution(l), "Lyrics provided by LRCLIB")
        let bare = Lyrics(source: "", provider: "youtube", synced: false, instrumental: false, lines: [])
        XCTAssertEqual(lyricsAttribution(bare), "Lyrics provided by youtube")
    }

    /// 11. The context cards' second line (the desktop's `subtitleFor`).
    func testRecentContextSubtitles() {
        func c(_ kind: String, _ sub: String? = nil) -> RecentPlayContext {
            RecentPlayContext(kind: kind, id: "x", title: "T", subtitle: sub, thumbnail: nil, params: nil, plays: 1, playedAt: 0)
        }
        XCTAssertEqual(HistoryView.subtitle(c("liked")), "Playlist • You")
        XCTAssertEqual(HistoryView.subtitle(c("artist")), "Artist")
        XCTAssertEqual(HistoryView.subtitle(c("album")), "Album")
        XCTAssertEqual(HistoryView.subtitle(c("radio")), "Radio")
        XCTAssertEqual(HistoryView.subtitle(c("podcast", "NPR")), "Podcast • NPR")
    }

    /// 12. The tile colours are exactly `crates/core/browse_tiles.json`.
    func testBrowseTilesMatchTheSharedFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../crates/core/browse_tiles.json").standardized
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["palette"] as? [String], BrowseTiles.palette)
        XCTAssertEqual(json?["fixed"] as? [String: String], BrowseTiles.fixed)
    }
}
