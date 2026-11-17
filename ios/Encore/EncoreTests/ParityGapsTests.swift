// The Mac features the parity audit found missing on iPhone: the Listening stats page, Speed &
// pitch for music, search suggestions and the Videos chip, a playlist's description and Public
// switch in Edit playlist, and About recommendations. Snapshots on the mock core, plus the logic.
import XCTest
import SwiftUI
@testable import Encore

final class ParityGapsSnapshotTests: SnapshotCase {
    // 1. Listening stats
    func testStatsPage() async { await snap("encore://stats", wait: 1.5) }

    /// The rest of the page (top tracks with play counts, top albums), in a tall window.
    func testStatsLowerPage() async {
        await snap("encore://stats", setup: { _ in
            self.window.frame = CGRect(x: 0, y: 0, width: self.window.frame.width, height: 1300)
        }, wait: 1.5)
    }

    /// The activity charts on fixed data and a fixed "now", so the dates on them never move.
    func testStatsActivity() async {
        window.rootViewController = UIHostingController(rootView:
            ScrollView { StatsActivity(stats: Self.fixedStats, range: .month, now: Self.fixedNow).padding(.vertical, 60) }
                .background(Palette.base).foregroundStyle(Palette.text).environment(app).preferredColorScheme(.dark))
        await snap(wait: 1.0)
    }

    // 2. Speed & pitch
    func testEffectsSheet() async { await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1", "encore://effects", wait: 1.2) }
    func testEffectsSheetSlowed() async {
        await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1", setup: { app in
            app.setEffects(PlaybackEffects.presets[1].effects)
            app.sheet = .effects
        }, wait: 1.2)
    }
    /// The playing song's ⋯ menu, in a tall window so the sheet shows down to Speed & pitch.
    func testTrackMenuHasSpeedAndPitch() async {
        window.frame = CGRect(x: 0, y: 0, width: window.frame.width, height: 2300)
        // Over Settings: a static page, so the glass behind the sheet is the same every run.
        await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1", "encore://settings", "encore://menu", wait: 1.5)
    }

    // 3-4. Search
    func testSearchSuggestions() async { await snap("encore://search?q=daft%20p&suggest=1", wait: 1.5) }
    func testSearchVideosChip() async { await snap("encore://search?q=daft%20punk&chip=videos", wait: 2) }

    // 5. Edit playlist
    func testEditPlaylistDescription() async {
        await snap("encore://library", setup: { app in app.sheet = .editPlaylist("LOCALPLAYLIST:1") }, wait: 1.5)
    }
    func testEditAccountPlaylistPublic() async {
        await snap("encore://library", setup: { app in
            _ = try? await app.account.complete(with: [HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SAPISID", .value: "s"])!])
            try? await Task.sleep(for: .milliseconds(600))
            app.sheet = .editPlaylist(MockYouTubeState.ownedId)
        }, wait: 1.5)
    }

    // 6. About recommendations
    func testAboutRecommendations() async { await snap("encore://made-for-you", "encore://about-recommendations", wait: 1.2) }

    static let fixedNow: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
    static var fixedStats: ListeningStats {
        let cal = Calendar.current
        let days = (0..<30).compactMap { back -> CorePair<String, Int>? in
            guard back % 7 != 3, let d = cal.date(byAdding: .day, value: -back, to: fixedNow) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return CorePair(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), 600 + (back * 53 % 13) * 300)
        }.reversed()
        let hours = (0..<168).map { i -> Int in
            let h = i % 24
            return (h >= 19 && h <= 23 ? 1200 : h >= 7 && h <= 9 ? 500 : h >= 13 && h <= 16 ? 300 : 0) + (i / 24 == 5 && h >= 19 ? 900 : 0)
        }
        return ListeningStats(secs: days.reduce(0) { $0 + $1.second }, prevSecs: 40_000, plays: 412, songs: 180, newSongs: 37, artists: 64,
                              days: Array(days), hours: hours, topSongs: [], topArtists: [], topAlbums: [], firstAt: 1_700_000_000, streak: 4, bestStreak: 21)
    }
}

@MainActor
final class ParityGapsTests: XCTestCase {
    private var core: MockCoreClient!
    private var app: AppModel!

    override func setUp() async throws {
        core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        app = AppModel(core: core)
        await app.start()
    }

    private func until(_ timeout: Double = 4, _ ok: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if await ok() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return false
    }

    // MARK: stats calendar (ui/src/lib/stats.ts)

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; return c }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }

    func testRangeStartCountsToday() {
        let now = date(2026, 3, 10)
        XCTAssertEqual(StatsMath.rangeStart(.week, now: now, calendar: cal), Int64(date(2026, 3, 4, 0).timeIntervalSince1970))
        XCTAssertEqual(StatsMath.rangeStart(.month, now: now, calendar: cal), Int64(date(2026, 2, 9, 0).timeIntervalSince1970))
        XCTAssertEqual(StatsMath.rangeStart(.year, now: now, calendar: cal), Int64(date(2025, 4, 1, 0).timeIntervalSince1970))
        XCTAssertEqual(StatsMath.rangeStart(.all, now: now, calendar: cal), 0)
    }

    func testBarsFillGapsAndGoMonthlyForAYear() {
        let now = date(2026, 1, 2)
        let week = StatsMath.bars([CorePair("2025-12-28", 60), CorePair("2026-01-02", 120)], .week, now: now, calendar: cal)
        XCTAssertEqual(week.map(\.key), ["2025-12-27", "2025-12-28", "2025-12-29", "2025-12-30", "2025-12-31", "2026-01-01", "2026-01-02"])
        XCTAssertEqual(week.map(\.secs), [0, 60, 0, 0, 0, 0, 120])
        let year = StatsMath.bars([CorePair("2025-12-28", 60), CorePair("2025-12-30", 40)], .year, now: now, calendar: cal)
        XCTAssertEqual(year.count, 12)
        XCTAssertEqual(year.first?.key, "2025-02")
        XCTAssertEqual(year.first { $0.key == "2025-12" }?.secs, 100)
        // All time: days while the history is short, months once it's past ~3 months.
        XCTAssertEqual(StatsMath.bars([CorePair("2025-12-30", 5)], .all, now: now, calendar: cal).first?.key, "2025-12-30")
        XCTAssertEqual(StatsMath.bars([CorePair("2025-06-30", 5)], .all, now: now, calendar: cal).first?.key, "2025-06")
    }

    func testListenedChangeBusiestHeatDayparts() {
        XCTAssertTrue(StatsMath.listened(0).contains("0"))
        XCTAssertFalse(StatsMath.listened(4 * 3600 + 12 * 60).isEmpty)
        XCTAssertNil(StatsMath.change(100, nil))
        XCTAssertNil(StatsMath.change(100, 0))
        XCTAssertEqual(StatsMath.change(150, 100), 50)
        XCTAssertEqual(StatsMath.change(50, 100), -50)
        var hours = Array(repeating: 0, count: 168)
        XCTAssertNil(StatsMath.busiest(hours))
        hours[5 * 24 + 22] = 2500 // Friday 10 pm
        hours[1 * 24 + 8] = 1000  // Monday 8 am
        hours[2 * 24 + 8] = 1000  // Tuesday 8 am
        hours[3 * 24 + 8] = 1000  // Wednesday 8 am: 8 am wins by hour, Friday by day
        let b = StatsMath.busiest(hours)
        XCTAssertEqual(b?.day, 5)
        XCTAssertEqual(b?.hour, 8)
        XCTAssertEqual(StatsMath.heat(0, 100), 0)
        XCTAssertEqual(StatsMath.heat(1, 100), 1)
        XCTAssertEqual(StatsMath.heat(100, 100), 4)
        let parts = StatsMath.dayparts(hours)
        XCTAssertEqual(parts[.night], 2500)
        XCTAssertEqual(parts[.morning], 3000)
        XCTAssertEqual(StatsMath.Daypart.of(hour: 2), .night)
        XCTAssertEqual(StatsMath.Daypart.of(hour: 17), .evening)
    }

    func testListeningStatsDecodesTheCoresShape() throws {
        let json = #"{"secs":120,"prevSecs":null,"plays":2,"songs":1,"newSongs":1,"artists":1,"days":[["2026-11-01",120]],"hours":[\#(Array(repeating: "0", count: 168).joined(separator: ","))],"topSongs":[],"topArtists":[],"topAlbums":[],"firstAt":1,"streak":1,"bestStreak":3}"#
        let s = try JSONDecoder().decode(ListeningStats.self, from: Data(json.utf8))
        XCTAssertEqual(s.hours.count, 168)
        XCTAssertEqual(s.bestStreak, 3)
        XCTAssertEqual(s.days.first?.second, 120)
    }

    /// Podcast time and shows (episodes count as listening, never as songs); older payloads
    /// without them still decode.
    func testListeningStatsDecodesPodcasts() throws {
        let json = #"{"secs":4000,"podcastSecs":3600,"episodes":1,"prevSecs":null,"plays":2,"songs":1,"newSongs":1,"artists":1,"days":[],"hours":[],"topSongs":[],"topArtists":[],"topAlbums":[],"topPodcasts":[{"id":"MPSPx","name":"The Show","thumbnail":null,"plays":1,"secs":3600}],"firstAt":1,"streak":1,"bestStreak":1}"#
        let s = try JSONDecoder().decode(ListeningStats.self, from: Data(json.utf8))
        XCTAssertEqual(s.podcastSecs, 3600)
        XCTAssertEqual(s.topPodcasts?.first?.id, "MPSPx")
        let r = try JSONDecoder().decode(Recommendation.self, from: Data(#"{"song":{"video_id":"a","title":"A","artists":"B"},"votes":1,"because":[],"basis":"listening"}"#.utf8))
        XCTAssertEqual(recommendedNote([r]), "Based on what you listen to")
    }

    // MARK: speed & pitch

    func testEffectsReachTheCoreAndStayForMusic() async throws {
        let page = try await core.getPlaylist(id: "LOCALPLAYLIST:1")
        app.player.play(page.items, at: 0, context: PlayContext(kind: .playlist, id: "LOCALPLAYLIST:1", title: "Mine"))
        _ = await until { self.app.player.now != nil }
        let slowed = PlaybackEffects.presets[1].effects
        app.setEffects(slowed)
        let reached = await until { self.core.withLock { self.core.fs.effects } == slowed }
        XCTAssertTrue(reached, "set_playback_params got speed, semitones and reverb")
        XCTAssertEqual(app.effects, slowed)
        XCTAssertTrue(slowed.sameSound(PlaybackEffects(speed: 0.85, semitones: -3, reverb: slowed.reverb)))
        XCTAssertFalse(app.effects.isOriginal)
    }

    func testEffectsEventDecodesOldAndNewPayloads() {
        guard case .playbackParams(let old) = CoreEvent.decode(name: "playback-params", json: Data(#"{"speed":1.5}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(old, PlaybackEffects(speed: 1.5))
        let full = #"{"speed":0.85,"semitones":-3,"reverb":{"enabled":true,"preset":4,"dry":100,"wet":40,"decay":1.8,"preDelay":0,"damping":8000,"reflections":100}}"#
        guard case .playbackParams(let e) = CoreEvent.decode(name: "playback-params", json: Data(full.utf8)) else { return XCTFail() }
        XCTAssertEqual(e, PlaybackEffects.presets[1].effects)
    }

    func testReverbEncodesTheCoresKeys() throws {
        let data = try JSONEncoder().encode(Reverb().inRoom(5))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["enabled", "preset", "dry", "wet", "decay", "preDelay", "damping", "reflections"])
        XCTAssertEqual(obj["decay"] as? Double, 3.2)
    }

    // MARK: search

    func testVideosChipPage() async throws {
        let p = try await core.searchPage(query: "daft punk", filter: "videos", continuation: nil)
        XCTAssertFalse(p.songs.isEmpty)
        XCTAssertTrue(p.songs.allSatisfy { $0.isVideo == true })
    }

    // MARK: edit playlist

    func testLocalPlaylistDescriptionSaves() async throws {
        try await app.core.updatePlaylist(id: "LOCALPLAYLIST:1", name: nil, description: "Songs for the drive")
        await app.library.refresh()
        XCTAssertEqual(app.library.snapshot.playlists.first { $0.id == "LOCALPLAYLIST:1" }?.description, "Songs for the drive")
    }

    func testAccountPlaylistGoesPublic() async throws {
        _ = try await app.account.complete(with: [HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SAPISID", .value: "s"])!])
        let owned = MockYouTubeState.ownedId
        _ = await until { self.app.account.youtube.loaded && !self.app.account.youtube.playlists.isEmpty }
        let before = try await core.getPlaylist(id: owned)
        XCTAssertEqual(before.privacy, "PRIVATE")
        try await core.editPlaylistDetails(playlistId: owned, name: nil, description: "Summer", public: true)
        let after = try await core.getPlaylist(id: owned)
        XCTAssertEqual(after.privacy, "PUBLIC")
        XCTAssertEqual(after.description, "Summer")
        let saved = try await core.getPlaylist(id: MockYouTubeState.savedId)
        XCTAssertNil(saved.privacy, "someone else's playlist has no switch")
    }
}
