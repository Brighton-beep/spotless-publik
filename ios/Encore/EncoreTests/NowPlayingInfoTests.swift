import MediaPlayer
import XCTest
@testable import Encore

/// Stream nowplaying-device: what the lock screen, Notification Center and Dynamic Island get.
final class NowPlayingInfoTests: XCTestCase {
    private func song(runs: [String]? = ["Kanye West", "PARTYNEXTDOOR"], explicit: Bool? = true,
                      live: Bool? = nil, album: String? = "The Life of Pablo") -> NowPlaying {
        NowPlaying(videoId: "abc", title: "Ultralight Beam", artists: "Kanye West & PARTYNEXTDOOR",
                   thumbnail: "https://lh3.googleusercontent.com/x=w120-h120-l90-rj", duration: "5:20", album: album,
                   artistRuns: runs?.map { ArtistRun(text: $0, id: "UC\($0)") }, explicit: explicit, live: live)
    }

    func testArtistsAreListedLikeSpotify() {
        XCTAssertEqual(NowPlayingInfo.artistLine(song()), "Kanye West, PARTYNEXTDOOR")
        // Whitespace and a repeated name (YouTube sometimes links the same channel twice).
        XCTAssertEqual(NowPlayingInfo.artistLine(song(runs: [" Future ", "Metro Boomin", "future"])), "Future, Metro Boomin")
        // No runs: the byline as YouTube wrote it (a duo stays one name).
        XCTAssertEqual(NowPlayingInfo.artistLine(song(runs: nil)), "Kanye West & PARTYNEXTDOOR")
        XCTAssertEqual(NowPlayingInfo.artistLine(song(runs: [])), "Kanye West & PARTYNEXTDOOR")
    }

    func testDictionaryCarriesTitleArtistsExplicitAndTimes() {
        let s = NowPlayingState(now: song(), paused: false, position: 42, duration: 320)
        let art = NowPlayingArtwork.artwork(UIImage(systemName: "music.note")!)
        let i = NowPlayingInfo.dictionary(s, artwork: art)
        XCTAssertEqual(i[MPMediaItemPropertyTitle] as? String, "Ultralight Beam")
        XCTAssertEqual(i[MPMediaItemPropertyArtist] as? String, "Kanye West, PARTYNEXTDOOR")
        XCTAssertEqual(i[MPMediaItemPropertyAlbumTitle] as? String, "The Life of Pablo")
        XCTAssertEqual(i[MPMediaItemPropertyIsExplicit] as? Bool, true)
        XCTAssertEqual(i[MPMediaItemPropertyPlaybackDuration] as? Double, 320)
        XCTAssertEqual(i[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(i[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(i[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)
        XCTAssertEqual(i[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, "abc")
        XCTAssertEqual(i[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.audio.rawValue)
        XCTAssertTrue(i[MPMediaItemPropertyArtwork] as AnyObject === art)
        XCTAssertNil(i[MPNowPlayingInfoPropertyIsLiveStream])
    }

    func testPausedIsRateZeroAndCleanSongHasNoBadge() {
        let s = NowPlayingState(now: song(explicit: nil, album: " "), paused: true, position: 10, duration: 320, speed: 1.5)
        let i = NowPlayingInfo.dictionary(s, artwork: nil)
        XCTAssertEqual(i[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(i[MPMediaItemPropertyIsExplicit] as? Bool, false)
        XCTAssertNil(i[MPMediaItemPropertyAlbumTitle])
        XCTAssertNil(i[MPMediaItemPropertyArtwork])
        // Playing at a podcast speed: the system extrapolates at that rate.
        let p = NowPlayingInfo.dictionary(NowPlayingState(now: song(), paused: false, position: 10, duration: 320, speed: 1.5), artwork: nil)
        XCTAssertEqual(p[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
    }

    func testElapsedIsClampedAndUnknownLengthIsLeftOut() {
        let over = NowPlayingInfo.dictionary(NowPlayingState(now: song(), paused: false, position: 400, duration: 320), artwork: nil)
        XCTAssertEqual(over[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 320)
        let neg = NowPlayingInfo.dictionary(NowPlayingState(now: song(), paused: false, position: -3, duration: 0), artwork: nil)
        XCTAssertEqual(neg[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        XCTAssertNil(neg[MPMediaItemPropertyPlaybackDuration])
    }

    func testLiveBroadcastHasNoScrubber() {
        let i = NowPlayingInfo.dictionary(NowPlayingState(now: song(live: true), paused: false, position: 99, duration: 320), artwork: nil)
        XCTAssertEqual(i[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertNil(i[MPMediaItemPropertyPlaybackDuration])
        XCTAssertEqual(i[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
    }

    func testClockAndArtURL() {
        XCTAssertEqual(NowPlayingInfo.parseClock("5:20"), 320)
        XCTAssertEqual(NowPlayingInfo.parseClock("1:02:03"), 3723)
        XCTAssertEqual(NowPlayingInfo.parseClock(nil), 0)
        XCTAssertEqual(NowPlayingInfo.artURL("https://lh3.googleusercontent.com/x=w120-h120-l90-rj"),
                       "https://lh3.googleusercontent.com/x=w720-h720-l90-rj")
        XCTAssertEqual(NowPlayingInfo.artURL("https://i.ytimg.com/vi/abc/hqdefault.jpg"), "https://i.ytimg.com/vi/abc/hqdefault.jpg")
        XCTAssertNil(NowPlayingInfo.artURL(""))
        XCTAssertNil(NowPlayingInfo.artURL(nil))
    }

    func testArtworkIsSquare() {
        func image(_ w: Int, _ h: Int) -> UIImage {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { c in
                UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        let wide = NowPlayingArtwork.squared(image(1280, 720)).cgImage!
        XCTAssertEqual([wide.width, wide.height], [720, 720])
        // 4:3 hqdefault: the 16:9 picture inside the letterbox bars.
        let hq = NowPlayingArtwork.squared(image(480, 360)).cgImage!
        XCTAssertEqual([hq.width, hq.height], [270, 270])
        let square = NowPlayingArtwork.squared(image(544, 544)).cgImage!
        XCTAssertEqual([square.width, square.height], [544, 544])
    }

    func testCoreEventDecodesTheNewFields() throws {
        let json = """
        {"videoId":"abc","title":"T","artists":"A & B","artistRuns":[{"text":"A","id":"UCa"},{"text":"B"}],
         "explicit":true,"isEpisode":false,"live":false,"duration":"3:00","streamClient":"current"}
        """.data(using: .utf8)!
        guard case .nowPlaying(let n) = CoreEvent.decode(name: "now-playing", json: json) else { return XCTFail("not decoded") }
        XCTAssertEqual(n.explicit, true)
        XCTAssertEqual(NowPlayingInfo.artistLine(n), "A, B")
        // An older payload without them still decodes.
        let old = #"{"videoId":"abc","title":"T","artists":"A"}"#.data(using: .utf8)!
        guard case .nowPlaying(let o) = CoreEvent.decode(name: "now-playing", json: old) else { return XCTFail("old not decoded") }
        XCTAssertNil(o.explicit)
    }
}
