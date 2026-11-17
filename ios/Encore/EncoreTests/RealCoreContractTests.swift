// Live contract test: every `CoreClient` method on the REAL core (UniFFI → crates/core → YouTube),
// decoded through the app's models. Catches drift between api.ts-shaped JSON and the Swift models,
// and wrong command/argument names in RealCoreClient. Needs the network, so it only runs with
//   TEST_RUNNER_ENCORE_LIVE=1 xcodebuild test ... -only-testing:EncoreTests/RealCoreContractTests
import XCTest
@testable import Encore
import EncoreCore

final class RealCoreContractTests: XCTestCase {
    func testEveryCallDecodes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENCORE_LIVE"] == "1", "live test: set TEST_RUNNER_ENCORE_LIVE=1")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("encore-contract-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let core = try RealCoreClient(config: CoreConfig(dataDir: data.path, cacheDir: cache.path, exportDir: base.path),
                                      secrets: KeychainStore(service: "app.encore.ios.test"))
        var failures: [String] = []
        var passed = 0
        func step<T>(_ name: String, _ f: () async throws -> T) async -> T? {
            do { let v = try await f(); passed += 1; return v } catch {
                failures.append("\(name): \(error)")
                return nil
            }
        }

        let songs = await step("search") { try await core.search(query: "Daft Punk One More Time") } ?? []
        XCTAssertFalse(songs.isEmpty)
        let all = await step("searchAll") { try await core.searchAll(query: "Daft Punk", recordHistory: true) }
        _ = await step("searchSuggestions") { try await core.searchSuggestions(query: "daft p") }
        _ = await step("getHome") { try await core.getHome(params: nil) }
        _ = await step("smartHome") { try await core.smartHome() }
        let moods = await step("getMoods") { try await core.getMoods() } ?? []
        _ = await step("getMoodArt") { try await core.getMoodArt(params: Array(moods.flatMap(\.items).prefix(3).map(\.params))) }
        if let album = all?.albums.first { _ = await step("getAlbum") { try await core.getAlbum(id: album.id) } }
        if let artist = all?.artists.first {
            _ = await step("getArtist") { try await core.getArtist(id: artist.id) }
            _ = await step("startRadio(artist)") { try await core.startRadio(kind: "artist", id: artist.id, name: artist.title) }
        }
        if let pl = all?.playlists.first { _ = await step("getPlaylist") { try await core.getPlaylist(id: pl.id) } }
        if let s = songs.first {
            _ = await step("getLyrics") { try await core.getLyrics(videoId: s.videoId, title: s.title, artists: s.artists, duration: s.seconds) }
            _ = await step("setLiked on") { try await core.setLiked(s, liked: true) }
            _ = await step("liked playlist") { try await core.getPlaylist(id: likedPlaylistId) }
            _ = await step("setLiked off") { try await core.setLiked(s, liked: false) }
            _ = await step("addToQueue") { try await core.addToQueue([s], from: "test") }
        }
        if let album = all?.albums.first { _ = await step("setSaved on") { try await core.setSaved(album, saved: true) } }
        let pl = await step("createPlaylist") { try await core.createPlaylist(name: "Contract") }
        if let pl, let s = songs.first {
            _ = await step("addToPlaylist") { try await core.addToPlaylist(id: pl.id, songs: [s]) }
            _ = await step("setPinned") { try await core.setPinned(id: pl.id, kind: "playlist", pinned: true) }
            if let f = await step("createFolder", { try await core.createFolder(name: "Box") }) {
                _ = await step("moveToFolder") { try await core.moveToFolder(itemId: pl.id, folderId: f.id) }
            }
        }
        let snap = await step("librarySnapshot") { try await core.librarySnapshot() }
        XCTAssertEqual(snap?.playlists.first?.name, "Contract")
        XCTAssertEqual(snap?.folders?.first?.items, pl.map { [$0.id] })
        _ = await step("recentContexts") { try await core.recentContexts(limit: 10) }
        _ = await step("getQueue") { try await core.getQueue() }
        _ = await step("getPlayback") { try await core.getPlayback() }
        _ = await step("setPrivateSession on") { try await core.setPrivateSession(true) }
        _ = await step("setPrivateSession off") { try await core.setPrivateSession(false) }

        // stream: audiobooks — LibriVox through the Internet Archive.
        let books = await step("audiobookSearch") { try await core.audiobookSearch(query: "Pride and Prejudice") } ?? []
        if books.first?.title != "Pride and Prejudice" { failures.append("audiobookSearch: top result \(books.first?.title ?? "-")") }
        _ = await step("audiobookHome") { try await core.audiobookHome() }
        _ = await step("audiobookGenre") { try await core.audiobookGenre(genre: "mystery") }
        if let b = books.first {
            let page = await step("audiobookPage") { try await core.audiobookPage(id: b.id) }
            if (page?.chapters.count ?? 0) < 10 { failures.append("audiobookPage: \(page?.chapters.count ?? 0) chapters") }
            if let c = page?.chapters.dropFirst(2).first {
                _ = await step("audiobookForChapter") { try await core.audiobookForChapter(id: c.id) }
            }
            if let pb = page?.book {
                _ = await step("audiobookSave") { try await core.audiobookSave(pb, saved: true) }
                let saved = await step("audiobookSaved") { try await core.audiobookSaved() }
                if saved?.first?.id != pb.id { failures.append("audiobookSaved: \(saved?.map(\.id) ?? [])") }
            }
        }
        let pod = await step("podcastSearch") { try await core.podcastSearch(query: "Lex Fridman") }
        if let show = pod?.shows.first {
            let page = await step("podcastShow") { try await core.podcastShow(id: show.id, sort: .newest) }
            if let token = page?.continuation { _ = await step("podcastShowMore") { try await core.podcastShowMore(id: show.id, continuation: token, sort: .newest) } }
            if let e = page?.episodes.first {
                _ = await step("podcastEpisode") { try await core.podcastEpisode(id: e.id) }
                // stream: chapters — a YouTube episode (Lex Fridman: markers from his description).
                let ch = await step("podcastChapters") { try await core.podcastChapters(id: e.id, durationSecs: e.durationSecs) }
                print("CHAPTERS youtube \(e.id): \(ch?.source ?? "-") \(ch?.chapters.count ?? 0): \(ch?.chapters.prefix(3).map { "\($0.startLabel) \($0.title)" } ?? [])")
                if (ch?.chapters.count ?? 0) < 2 { failures.append("podcastChapters: no chapters for YouTube episode \(e.id)") }
                _ = await step("podcastSaveEpisode") { try await core.podcastSaveEpisode(e, saved: true) }
                _ = await step("podcastMarkPlayed") { try await core.podcastMarkPlayed(id: e.id, played: true) }
            }
            _ = await step("podcastFollow") { try await core.podcastFollow(show, follow: true) }
            _ = await step("podcastFollows") { try await core.podcastFollows() }
            _ = await step("podcastUnfollow") { try await core.podcastFollow(show, follow: false) }
        }
        // stream: chapters — an RSS episode with Podcasting 2.0 JSON chapters (The Changelog).
        let feed = await step("podcastShow(rss)") { try await core.podcastShow(id: "https://changelog.com/podcast/feed", sort: .newest) }
        if let e = feed?.episodes.first {
            let ch = await step("podcastChapters(rss)") { try await core.podcastChapters(id: e.id, durationSecs: e.durationSecs) }
            print("CHAPTERS rss \(e.title): \(ch?.source ?? "-") \(ch?.chapters.count ?? 0): \(ch?.chapters.prefix(3).map { "\($0.startLabel) \($0.title)" } ?? [])")
            if ch?.source != "feed" { failures.append("podcastChapters(rss): expected feed chapters, got \(ch?.source ?? "none")") }
        }
        _ = await step("podcastSavedEpisodes") { try await core.podcastSavedEpisodes() }
        _ = await step("podcastNewEpisodes") { try await core.podcastNewEpisodes(limit: 10) }
        _ = await step("podcastContinueListening") { try await core.podcastContinueListening(limit: 10) }

        _ = await step("audioSettings") { try await core.audioSettings() }
        let eq = await step("eqInfo") { try await core.eqInfo() }
        _ = await step("setEq") { try await core.setEq(enabled: true, gains: Array(repeating: 1, count: eq?.bands.count ?? 6), commit: true) }
        if let p = eq?.presets.first { _ = await step("setEqPreset") { try await core.setEqPreset(p.name) } }
        _ = await step("setCrossfade") { try await core.setCrossfade(seconds: 0) }
        _ = await step("setNormalize") { try await core.setNormalize(true) }
        _ = await step("setVolumeLevel") { try await core.setVolumeLevel(.normal) }
        _ = await step("setSleepTimer") { try await core.setSleepTimer(minutes: 15, endOfTrack: false) }
        _ = await step("cancelSleepTimer") { try await core.cancelSleepTimer() }

        _ = await step("smartSettings") { try await core.smartSettings() }
        _ = await step("smartSetSetting") { try await core.smartSetSetting(key: "explicit_filter", value: "false") }
        _ = await step("madeForYou") { try await core.madeForYou() }
        _ = await step("whatsNew") { try await core.whatsNew() }
        _ = await step("whatsNewMarkSeen") { try await core.whatsNewMarkSeen() }
        _ = await step("smartShuffleState") { try await core.smartShuffleState() }

        _ = await step("downloadsSnapshot") { try await core.downloadsSnapshot() }
        _ = await step("downloadsSetSettings") { try await core.downloadsSetSettings(DownloadSettingsPatch(allowMetered: false)) }

        _ = await step("setSetting (iOS key)") { try await core.setSetting(key: SettingKey.dataSaver, value: "true") }
        let settings = await step("getSettings") { try await core.getSettings() }
        XCTAssertEqual(settings?[SettingKey.dataSaver], "true")
        _ = await step("cacheSize") { try await core.cacheSize() }
        _ = await step("clearCaches") { try await core.clearCaches() }
        _ = await step("importStatus") { try await core.importStatus() }

        print("CONTRACT \(passed) passed, \(failures.count) failed")
        for f in failures { print("CONTRACT FAIL \(f)") }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
