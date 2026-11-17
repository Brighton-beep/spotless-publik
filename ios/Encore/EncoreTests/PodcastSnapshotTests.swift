// Snapshots of the podcast screens and the Now Playing episode / Smart Shuffle states.
import XCTest
@testable import Encore

final class PodcastSnapshotTests: SnapshotCase {
    let show = "MPSPPLPNW_gerXa4Pc8S2qoUQc5e8Ir97RLuVW"

    func testShow() async { await snap("encore://show/\(show)") }
    func testEpisode() async { await snap("encore://episode/1rn_Clc-MM0") }
    func testYourEpisodes() async { await snap("encore://your-episodes") }
    func testNewEpisodes() async { await snap("encore://new-episodes") }
    func testSearchPodcasts() async { await snap("encore://search?q=huberman&chip=podcasts", wait: 1.5) }
    func testHomePodcasts() async { await snap("encore://home?chip=podcasts", wait: 1.5) }
    /// stream: audiobooks — the Audiobooks chip: every chip stays, genre tiles carry their top book's cover.
    func testHomeAudiobooks() async { await snap("encore://home?chip=audiobooks", wait: 3.0, tolerant: true) }
    /// stream: home-tiles-pods — a podcast category tile's page.
    func testPodcastCategoryPage() async { await snap("encore://shelf/podcat:1303?title=Comedy", wait: 1) }
    func testNowPlayingEpisode() async { await snap("encore://play-episode/1rn_Clc-MM0?open=1&pause=1") }
    func testSpeedSheet() async { await snap("encore://play-episode/1rn_Clc-MM0?pause=1", "encore://speed") }
    /// Spotify's Chapters sheet: "auto-generated" under the title, a frame, two-line title and length
    /// per chapter, the playing one (the second) in accent.
    func testChaptersSheet() async {
        await snap("encore://play-episode/1rn_Clc-MM0?pause=1&open=1", setup: { app in
            await app.podcasts.loadChapters("1rn_Clc-MM0", duration: app.player.duration)
            let list = app.podcasts.chapters["1rn_Clc-MM0"] ?? []
            if list.count > 1 { app.player.seek(list[1].startSecs + 5) }
            try? await Task.sleep(for: .milliseconds(300))
            app.sheet = .chapters
        }, wait: 1.2, tolerant: true)
    }
    func testEpisodeSheet() async {
        await snap("encore://show/\(show)", setup: { app in
            if let e = try? await app.core.podcastEpisode(id: "wbJ_Q1xsDHg") { app.sheet = .episode(e) }
        })
    }
    /// stream: podcast-upnext — the queue after an episode: one "Next up" block (the show's next,
    /// then Autoplay's predictions), each row with the core's reason where the show name was.
    func testQueuePodcastUpNext() async {
        await snap("encore://play-episode/1rn_Clc-MM0?pause=1", setup: { app in
            var rows: [SongItem] = []
            for f in ((try? await app.core.podcastFollows()) ?? []).prefix(3) {
                if let p = try? await app.core.podcastShow(id: f.id, sort: .newest) { rows += p.episodes.prefix(2).map(\.song) }
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard let cur = app.player.current, rows.count >= 4 else { return XCTFail("no episode fixtures") }
            var next = rows[0]; next.reason = "From \(next.artists)"
            var follow = rows[2]; follow.reason = "Because you follow \(follow.artists)"; follow.autoplay = true
            var pop = rows[3]; pop.reason = "Popular in Business · \(pop.artists)"; pop.autoplay = true
            app.player.queue = QueueState(items: [rows[1], cur, next, follow, pop], currentIndex: 1, sourceName: cur.artists)
            if let u = URL(string: "encore://queue") { app.router.handle(u, app: app) }
        }, wait: 1.2)
    }

    /// Now Playing's ⋯ for an episode (the track sheet) offers Download too.
    func testNowPlayingEpisodeSheet() async {
        await snap("encore://play-episode/1rn_Clc-MM0?open=1&pause=1", setup: { app in
            if let s = app.player.current { app.sheet = .track(s, context: nil) }
        })
    }

    /// Downloading an episode saves it to Your Episodes (the core's rule; the mock mirrors it), the
    /// sheet then offers Remove download, and removing the download keeps it saved.
    @MainActor func testDownloadingAnEpisodeSavesIt() async throws {
        let page = try await app.core.podcastShow(id: show, sort: .newest)
        await app.podcasts.refresh()
        let e = try XCTUnwrap(page.episodes.first { !app.podcasts.isSaved($0) })
        XCTAssertEqual(episodeDownloadRow(app, song: e.song).title, "Download")
        toggleEpisodeDownload(app, e)
        XCTAssertTrue(app.podcasts.isSaved(e), "shown saved at once")
        _ = await app.downloads.actions.last?.value
        await app.podcasts.refresh()
        XCTAssertTrue(app.podcasts.isSaved(e), "saved by the core")
        XCTAssertTrue(app.downloads.isCollectionDownloaded(e.id))
        XCTAssertNotEqual(episodeDownloadRow(app, song: e.song).title, "Download")
        app.downloads.remove(e.id)
        _ = await app.downloads.actions.last?.value
        await app.podcasts.refresh()
        XCTAssertFalse(app.downloads.isCollectionDownloaded(e.id))
        XCTAssertTrue(app.podcasts.isSaved(e), "removing the download doesn't unsave")
    }
    func testSmartShuffle() async { await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1&smart=1&open=1", wait: 1.2) }

    /// Show notes: timestamps become seek links, other links stay links.
    func testShowNotesLinks() {
        let a = showNotes(##"Intro <a href="#t=90" data-seek="90">1:30</a> and <a href="https://x.com/a">site</a><br>Line &amp; more"##)
        let links = a.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["encore-seek://90", "https://x.com/a"])
        XCTAssertEqual(String(a.characters), "Intro 1:30 and site\nLine & more")
    }
}
