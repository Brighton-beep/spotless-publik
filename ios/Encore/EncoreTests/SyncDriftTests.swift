// Stream ios-sync2: the six rules onecore found drifting between the iPhone and the desktop. Each
// case replays the desktop's own check (`*.check.ts`) or the core's rule.
import XCTest
@testable import Encore

final class SyncDriftTests: XCTestCase {
    private func song(_ id: String, _ duration: String? = "3:00") -> SongItem {
        SongItem(videoId: id, title: id, artists: "", duration: duration)
    }

    /// `smarttags.check.ts` / `smartshuffle::interleave`: one suggestion after every 2 songs, never
    /// after the last one.
    func testEnhanceInterleaveNeverAddsATrailingSuggestion() {
        XCTAssertEqual(PlaylistSmarts.interleave([1, 2, 3, 4, 5, 6, 7], [100, 200, 300, 400]), [1, 2, 100, 3, 4, 200, 5, 6, 300, 7])
        XCTAssertEqual(PlaylistSmarts.interleave([1, 2, 3, 4, 5], [100]), [1, 2, 100, 3, 4, 5])
        XCTAssertEqual(PlaylistSmarts.interleave([1, 2], [9]), [1, 2])
        XCTAssertEqual(PlaylistSmarts.interleave([1, 2, 3, 4], [8, 9]), [1, 2, 8, 3, 4])
    }

    /// `collections-format.check.ts`.
    func testCollectionLengthReadsLikeTheDesktop() {
        XCTAssertEqual(CollectionMeta.total(25 * 60 + 6, count: 7), "25 min 6 sec")
        XCTAssertEqual(CollectionMeta.total(92 * 60, count: 30), "1 hr 32 min")
        XCTAssertEqual(CollectionMeta.total(11 * 3600 + 5 * 60, count: 227), "about 11 hr")
        XCTAssertEqual(CollectionMeta.total(3 * 3600 + 30 * 60, count: 50, approx: true), "about 3 hr 30 min")
        XCTAssertEqual(CollectionMeta.total(3 * 3600 + 30 * 60, count: 50), "3 hr 30 min")
        XCTAssertEqual(CollectionMeta.total(25 * 60 + 6, count: 7, approx: true), "25 min 6 sec")
        XCTAssertEqual(CollectionMeta.total(0, count: 0), "")
        XCTAssertEqual(CollectionMeta.songs([song("a")]), "1 song, 3 min")
        XCTAssertEqual(CollectionMeta.songs((0..<1200).map { song("s\($0)") }, approx: true), "1,200 songs, about 60 hr")
        XCTAssertEqual(CollectionMeta.songs([]), "")
    }

    /// `smartshuffle.check.ts` `releaseWhen`, plus the weeks step and the year fallback.
    func testWhatsNewDatesHaveWeeksAndFallBackToTheYear() {
        let now = 1_800_000_000.0
        XCTAssertEqual(whatsNewWhen(now - 2 * 86_400, year: 2026, now: now), "2 days ago")
        XCTAssertEqual(whatsNewWhen(0, year: 2025, now: now), "2025")
        XCTAssertEqual(whatsNewWhen(now - 10, year: 2026, now: now), "Today")
        XCTAssertEqual(whatsNewWhen(now - 86_400, year: 2026, now: now), "Yesterday")
        XCTAssertEqual(whatsNewWhen(now - 8 * 86_400, year: 2026, now: now), "1 week ago")
        XCTAssertEqual(whatsNewWhen(now - 20 * 86_400, year: 2026, now: now), "2 weeks ago")
        XCTAssertEqual(whatsNewWhen(now - 40 * 86_400, year: 2026, now: now), "2026")
    }

    /// The desktop's `thumb`: `=sN` artwork is resized too.
    func testArtworkSizingHandlesBothSizeSuffixes() {
        XCTAssertEqual(sizedArt("https://lh3.googleusercontent.com/x=w544-h544-l90-rj", 120), "https://lh3.googleusercontent.com/x=w120-h120-l90-rj")
        XCTAssertEqual(sizedArt("https://yt3.googleusercontent.com/x=s1200", 240), "https://yt3.googleusercontent.com/x=s240")
        XCTAssertEqual(sizedArt("https://i.ytimg.com/vi/abc/hqdefault.jpg", 240), "https://i.ytimg.com/vi/abc/hqdefault.jpg")
        XCTAssertNil(sizedArt(nil, 240))
    }

    /// "Add to queue" rows (`queued_end`) are queued songs too: Clear queue takes them, as on the desktop.
    func testClearQueueTakesAddToQueueRows() {
        var playNext = song("next"); playNext.queued = true
        var addToQueue = song("end"); addToQueue.queuedEnd = true
        let q = QueueState(items: [song("now"), playNext, addToQueue, song("context")], currentIndex: 0)
        XCTAssertEqual(QueueUndo.queuedRows(q).map(\.videoId), ["next", "end"])
    }

    /// `activeLine(lines, pos − offset_ms)`: a positive offset shows each line later.
    func testActiveLyricLineAppliesTheOffset() throws {
        let json = #"{"source":"x","provider":"lrclib","synced":true,"instrumental":false,"offset_ms":500,"lines":[{"time_ms":1000,"text":"a"},{"time_ms":2000,"text":"b"}]}"#
        var l = try JSONDecoder().decode(Lyrics.self, from: Data(json.utf8))
        XCTAssertEqual(l.offsetMs, 500)
        XCTAssertNil(l.activeIndex(at: 1.2))
        XCTAssertEqual(l.activeIndex(at: 1.6), 0)
        XCTAssertEqual(l.activeIndex(at: 2.4), 0)
        XCTAssertEqual(l.activeIndex(at: 2.5), 1)
        l.offsetMs = -500
        XCTAssertEqual(l.activeIndex(at: 0.6), 0)
        l.offsetMs = nil
        XCTAssertEqual(l.activeIndex(at: 1.0), 0)
        l.synced = false
        XCTAssertNil(l.activeIndex(at: 5))
    }
}
