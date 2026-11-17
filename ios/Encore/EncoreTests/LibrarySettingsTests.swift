// Stream ios-p2 (SYNC-GAPS lane P2): the YouTube account (cookie header, store, real core arms),
// streaming quality wired to the core, Show unplayable songs, Recover playlists, Recents and stats,
// folder rename/delete with Undo, the playlist image, and the episode tiles.
import XCTest
@testable import Encore
import EncoreCore

@MainActor
final class LibrarySettingsTests: XCTestCase {
    private func mockApp() async -> AppModel {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        return app
    }

    private func cookie(_ name: String, _ value: String, _ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value])!
    }

    // MARK: account

    func testCookieHeaderKeepsTheYouTubeJarOnly() {
        // The desktop's `youtube_cookie_header` cases (session.rs tests).
        let header = YouTubeCookies.header([
            cookie("SAPISID", "abc", ".youtube.com"),
            cookie("SID", "def", ".youtube.com"),
            cookie("VISITOR_INFO1_LIVE", "xyz", "music.youtube.com"),
            cookie("SAPISID", "notthisone", ".google.com"),
            cookie("NID", "g", "accounts.google.com"),
        ])
        XCTAssertEqual(header, "SAPISID=abc; SID=def; VISITOR_INFO1_LIVE=xyz")
        XCTAssertEqual(YouTubeCookies.sapisid(header), "abc")
    }

    func testMostSpecificDomainWinsANameClash() {
        let header = YouTubeCookies.header([cookie("PREF", "specific", "music.youtube.com"), cookie("PREF", "broad", ".youtube.com")])
        XCTAssertEqual(header, "PREF=specific")
    }

    func testSapisidMatchesTheCore() {
        XCTAssertNil(YouTubeCookies.sapisid("SID=a; HSID=b"))
        XCTAssertEqual(YouTubeCookies.sapisid("SID=a; __Secure-3PAPISID=z"), "z")
        XCTAssertEqual(YouTubeCookies.sapisid(" SAPISID = q ;SID=a"), "q")
        XCTAssertNil(YouTubeCookies.sapisid("SAPISID="))
    }

    func testSignInWithTheMockSetsTheAccountAndYourName() async throws {
        let app = await mockApp()
        XCTAssertFalse(app.account.signedIn)
        XCTAssertEqual(app.localUser, "You")
        // Back on music.youtube.com but not signed in yet: keep watching.
        let early = try await app.account.complete(with: [cookie("YSC", "x", ".youtube.com")])
        XCTAssertFalse(early)
        XCTAssertFalse(app.account.signedIn)

        let done = try await app.account.complete(with: [cookie("SAPISID", "s", ".youtube.com"), cookie("SID", "t", ".youtube.com")])
        XCTAssertTrue(done)
        XCTAssertTrue(app.account.signedIn)
        XCTAssertEqual(app.account.account.displayName, "Test Listener")
        XCTAssertEqual(app.localUser, "Test Listener", "your name across the app is the account's")
        XCTAssertEqual(profileSubtitle(app), "@testlistener")

        try await app.account.signOut()
        XCTAssertFalse(app.account.signedIn)
        XCTAssertEqual(app.localUser, "You")
        XCTAssertEqual(profileSubtitle(app), "Local profile")
    }

    func testMultiChannelSignInAsksForTheChannel() async throws {
        let app = await mockApp()
        _ = try await app.account.complete(with: [cookie("SAPISID", "multi", ".youtube.com")])
        XCTAssertFalse(app.account.signedIn, "not complete until a channel is picked")
        XCTAssertEqual(app.account.identities.count, 2)
        XCTAssertEqual(app.localUser, "You")
        try await app.account.pick(app.account.identities[1])
        XCTAssertTrue(app.account.signedIn)
        XCTAssertEqual(app.localUser, "Test Listener Music")
        XCTAssertTrue(app.account.identities.isEmpty)
    }

    func testAuthChangedEventRefreshesTheStore() async throws {
        let app = await mockApp()
        let mock = try XCTUnwrap(app.core as? MockCoreClient)
        _ = try await mock.accountSignIn(cookie: "SAPISID=a", expectAccount: nil) // emits auth-changed
        for _ in 0..<20 where !app.account.signedIn { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(app.account.signedIn)
    }

    func testRealCoreAccountArms() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("p2-account-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let core = try RealCoreClient(config: CoreConfig(dataDir: data.path, cacheDir: cache.path, exportDir: base.path),
                                      secrets: KeychainStore(service: "app.encore.ios.test"))
        let a = try await core.getAccount()
        XCTAssertFalse(a.signedIn)
        // No SAPISID: the core refuses it before any request (the same check the desktop's login makes).
        do {
            _ = try await core.accountSignIn(cookie: "SID=x; HSID=y", expectAccount: nil)
            XCTFail("a jar without SAPISID must not sign in")
        } catch {
            XCTAssertTrue((error as? CoreFailure)?.message.contains("Sign-in didn't complete") == true, "\(error)")
        }
        try await core.accountWatch()
        try await core.accountWatch() // idempotent
        let out = try await core.signOut()
        XCTAssertFalse(out.signedIn)
    }

    // MARK: streaming quality

    func testCoreQualityResolvesWifiCellularAndDataSaver() {
        // The desktop's five choices, the same values in the core's `quality`.
        XCTAssertEqual(StreamQuality.choices.map(\.title), ["Automatic", "Low", "Normal", "High", "Very high"])
        XCTAssertEqual(StreamQuality.coreQuality(cellular: false, wifi: "auto", cell: "auto", dataSaver: false), "AUTO")
        XCTAssertEqual(StreamQuality.coreQuality(cellular: true, wifi: "auto", cell: "auto", dataSaver: false), "LOW")
        XCTAssertEqual(StreamQuality.coreQuality(cellular: true, wifi: "low", cell: "high", dataSaver: false), "HIGH")
        XCTAssertEqual(StreamQuality.coreQuality(cellular: false, wifi: "low", cell: "high", dataSaver: false), "LOW")
        XCTAssertEqual(StreamQuality.coreQuality(cellular: false, wifi: "high", cell: "high", dataSaver: true), "LOW")
        XCTAssertEqual(StreamQuality.coreQuality(cellular: false, wifi: "very_high", cell: "normal", dataSaver: false), "VERY_HIGH")
        XCTAssertEqual(StreamQuality.coreQuality(cellular: true, wifi: "very_high", cell: "normal", dataSaver: false), "NORMAL")
        XCTAssertEqual(StreamQuality.normalized("bogus"), "auto")
        XCTAssertEqual(StreamQuality.normalized(nil), "auto")
    }

    func testQualityChoicesReachTheCoreSetting() async throws {
        let app = await mockApp()
        let wifi = !StreamQuality.shared.onCellular
        let key = wifi ? SettingKey.streamQuality : SettingKey.cellularQuality
        app.settings.set(key, "low")
        StreamQuality.shared.apply()
        try await Task.sleep(for: .milliseconds(100))
        var core = try await app.core.getSettings()
        XCTAssertEqual(core["quality"], "LOW", "the core's own `quality` is what playback reads")
        app.settings.set(key, "high")
        StreamQuality.shared.apply()
        try await Task.sleep(for: .milliseconds(100))
        core = try await app.core.getSettings()
        XCTAssertEqual(core["quality"], "HIGH")
        app.settings.set(SettingKey.dataSaver, true)
        StreamQuality.shared.apply()
        try await Task.sleep(for: .milliseconds(100))
        core = try await app.core.getSettings()
        XCTAssertEqual(core["quality"], "LOW", "Data Saver forces Low")
    }

    // MARK: show unplayable songs

    func testShowUnplayableHidesGreyedRows() async {
        let app = await mockApp()
        XCTAssertFalse(app.hidesUnplayable, "on by default: greyed rows are listed")
        app.settings.set(SettingKey.showUnplayable, false)
        XCTAssertTrue(app.hidesUnplayable)
        var song = SongItem(videoId: "u1", title: "Gone", artists: "Nobody")
        song.unavailable = true
        XCTAssertNotNil(app.rowBlock(song), "what the switch hides is exactly what's greyed")
    }

    // MARK: recover playlists

    func testRecoverMetaCountsDaysLeft() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let p = DeletedPlaylist(id: "p", name: "Gym", count: 1, thumbnail: nil, deletedAt: 999_000, purgeAt: 1_000_000 + 29 * 86_400 + 10)
        XCTAssertEqual(RecoverPlaylistsSettings.meta(p, now: now), "1 song • 30 days left")
        let q = DeletedPlaylist(id: "q", name: "Old", count: 12, thumbnail: nil, deletedAt: 0, purgeAt: 1_000_000 + 3_600)
        XCTAssertEqual(RecoverPlaylistsSettings.meta(q, now: now), "12 songs • 1 day left")
    }

    // MARK: recents and stats

    func testRecentsGroupUnderDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_763_200_000) // Sat 15 Nov 2025, 09:46 UTC
        let s = SongItem(videoId: "a", title: "A", artists: "X")
        let t = Int64(now.timeIntervalSince1970)
        let rows = [RecentTrack(song: s, playedAt: t - 60, plays: 1), RecentTrack(song: s, playedAt: t - 600, plays: 1),
                    RecentTrack(song: s, playedAt: t - 86_400, plays: 1), RecentTrack(song: s, playedAt: t - 5 * 86_400, plays: 1)]
        let days = HistoryView.days(rows, now: now, calendar: cal)
        XCTAssertEqual(days.map(\.title).prefix(2), ["Today", "Yesterday"])
        XCTAssertEqual(days.map(\.indices), [[0, 1], [2], [3]])
    }

    func testMinutesListened() {
        XCTAssertEqual(HistoryView.minutes(0), "0")
        XCTAssertEqual(HistoryView.minutes(20), "1")
        XCTAssertEqual(HistoryView.minutes(125), "2")
    }

    // MARK: folders

    func testFolderDeleteUndoAndRename() async throws {
        let app = await mockApp()
        let id = "FOLDER:1"
        await FolderActions.rename(id: id, to: "Lifting", app: app)
        XCTAssertEqual(app.library.snapshot.folders?.first { $0.id == id }?.name, "Lifting")

        var left = false
        await FolderActions.delete(id: id, name: "Lifting", app: app) { left = true }
        XCTAssertTrue(left, "the folder page closes")
        XCTAssertNil(app.library.snapshot.folders?.first { $0.id == id })
        let toast = try XCTUnwrap(app.toast)
        XCTAssertEqual(toast.text, "Deleted Lifting")
        XCTAssertEqual(toast.action, "Undo")
        toast.run?()
        for _ in 0..<20 where app.library.snapshot.folders?.contains(where: { $0.id == id }) != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(app.library.snapshot.folders?.first { $0.id == id }?.name, "Lifting", "Undo puts it back")
    }

    // MARK: playlist image

    func testCoverFileIsASquareJpegUnder1000px() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
        let url = try XCTUnwrap(EditPlaylistSheet.coverFile(big))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "jpg", "the core takes JPEG or PNG only")
        let img = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(img.size.width * img.scale, 1000)
        XCTAssertEqual(img.size.height * img.scale, 1000)
    }

    func testPickedCoverShowsInTheLibrary() async throws {
        let app = await mockApp()
        let pl = try await app.core.createPlaylist(name: "With cover")
        let img = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        let url = try XCTUnwrap(EditPlaylistSheet.coverFile(img))
        _ = try await app.core.setPlaylistCover(playlistId: pl.id, path: url.path)
        await app.library.refresh()
        let row = LibraryRows.all(app).first { $0.id == pl.id }
        XCTAssertEqual(row?.thumbnail, URL(fileURLWithPath: url.path).absoluteString)
    }

    // MARK: episode tiles

    func testEpisodeTilesDecodeAndDraw() throws {
        let json = #"{"kind":"episode","id":"MPEDx","title":"Ep","explicit":false,"progress":0.4}"#
        let started = try JSONDecoder().decode(ShelfItem.self, from: Data(json.utf8))
        XCTAssertEqual(started.progress, 0.4)
        XCTAssertEqual(HomeView.episodeTile(started, live: nil).progress, 0.4)
        XCTAssertFalse(HomeView.episodeTile(started, live: nil).isNew)

        let fresh = try JSONDecoder().decode(ShelfItem.self, from: Data(#"{"kind":"episode","id":"MPEDy","title":"New","explicit":false,"newEpisode":true}"#.utf8))
        XCTAssertNil(HomeView.episodeTile(fresh, live: nil).progress)
        XCTAssertTrue(HomeView.episodeTile(fresh, live: nil).isNew, "the blue dot")

        // Live progress wins: started now → bar, no dot; played → neither.
        let live = EpisodeProgress(positionSecs: 300, durationSecs: 1200, fraction: 0.25, played: false, updatedAt: 1)
        XCTAssertEqual(HomeView.episodeTile(fresh, live: live).progress, 0.25)
        XCTAssertFalse(HomeView.episodeTile(fresh, live: live).isNew)
        let played = EpisodeProgress(positionSecs: 1200, durationSecs: 1200, fraction: 1, played: true, updatedAt: 2)
        XCTAssertNil(HomeView.episodeTile(started, live: played).progress)
        XCTAssertFalse(HomeView.episodeTile(fresh, live: played).isNew)

        let song = ShelfItem(kind: "song", id: "s", title: "S", explicit: false)
        XCTAssertNil(HomeView.episodeTile(song, live: nil).progress)
    }
}
