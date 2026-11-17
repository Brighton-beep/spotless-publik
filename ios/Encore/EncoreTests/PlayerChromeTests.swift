// Lane I-A (magic gaps 5, 8, 24, 30): offline bar, Now Playing art carousel, output-device line,
// marquee titles. Snapshots on the mock core plus the pure rules behind them.
import XCTest
import AVFoundation
@testable import Encore

final class PlayerChromeSnapshotTests: SnapshotCase {
    private let lateNightDrive = "encore://play/LOCALPLAYLIST:1?index=3&pause=1"
    /// "Get Lucky (Radio Edit - feat. Pharrell Williams and Nile Rodgers)": too long for one line.
    private let longTitle = "encore://play/LOCALPLAYLIST:1?index=9&pause=1"

    override func tearDown() async throws {
        AudioRoute.shared.fake = nil
        try await super.tearDown()
    }

    /// #5: Offline mode on: the bar sits above the mini player, Home stays put.
    func testOfflineBarOfflineMode() async {
        await snap(lateNightDrive, "encore://offline?on=1", wait: 1.2)
    }

    /// #5: No connection (the core's NWPathMonitor reports offline).
    func testOfflineBarNoConnection() async {
        await snap(lateNightDrive, setup: { app in
            app.downloads.snapshot.network.online = false
            app.downloads.snapshot.network.offline = true
        })
    }

    /// #24: AirPlay / Bluetooth: accent devices glyph, the device name in accent on the second line.
    func testMiniPlayerOnExternalDevice() async {
        await snap(lateNightDrive, setup: { _ in AudioRoute.shared.fake = "Kitchen Speaker" })
    }

    /// #24 + #30: Now Playing on an external device, with a title long enough to marquee (resting
    /// at its start, edge faded).
    func testNowPlayingDeviceAndLongTitle() async {
        await snap(longTitle, "encore://nowplaying", setup: { _ in AudioRoute.shared.fake = "Living Room" })
    }

    /// #30: the mini player with a long title (the first 2 s: at rest, trailing edge faded).
    func testMiniPlayerLongTitle() async {
        await snap(longTitle, wait: 2.5)
    }
}

final class PlayerChromeRuleTests: XCTestCase {
    /// #8: commit past 30 % of the width or on a flick; otherwise spring back; never past an end.
    func testArtSwipeCommitRule() {
        let w: CGFloat = 342
        func d(_ x: CGFloat, predicted: CGFloat? = nil, v: CGFloat = 0, prev: Bool = true, next: Bool = true) -> Int {
            NPArtwork.decide(translation: x, predicted: predicted ?? x, velocity: v, width: w, hasPrevious: prev, hasNext: next)
        }
        XCTAssertEqual(d(-110), 1, "past 30 % to the left: next")
        XCTAssertEqual(d(110), -1, "past 30 % to the right: previous track")
        XCTAssertEqual(d(-90), 0, "short of 30 %: spring back")
        XCTAssertEqual(d(90), 0)
        XCTAssertEqual(d(-40, v: -900), 1, "a fast flick commits early")
        XCTAssertEqual(d(40, v: 900), -1)
        XCTAssertEqual(d(-40, predicted: -300), 1, "a throw heading well past commits")
        XCTAssertEqual(d(-5, v: -900), 0, "a twitch isn't a flick")
        XCTAssertEqual(d(-200, next: false), 0, "end of the queue: rubber-band back")
        XCTAssertEqual(d(200, prev: false), 0, "start of the queue: rubber-band back")
        XCTAssertEqual(d(-60, v: 900), 0, "flicking back the other way cancels")
    }

    /// #24: only outputs that aren't the phone get a name.
    func testExternalRouteName() {
        XCTAssertNil(AudioRoute.externalName([(.builtInSpeaker, "Speaker")]))
        XCTAssertNil(AudioRoute.externalName([(.builtInReceiver, "Receiver")]))
        XCTAssertNil(AudioRoute.externalName([(.headphones, "Headphones")]))
        XCTAssertEqual(AudioRoute.externalName([(.airPlay, "Living Room")]), "Living Room")
        XCTAssertEqual(AudioRoute.externalName([(.bluetoothA2DP, "AirPods Pro")]), "AirPods Pro")
        XCTAssertEqual(AudioRoute.externalName([(.builtInSpeaker, "Speaker"), (.airPlay, "Kitchen")]), "Kitchen")
        XCTAssertEqual(AudioRoute.externalName([(.carAudio, " ")]), "CarPlay")
    }

    @MainActor func testFakeRouteOverridesAndClears() {
        let r = AudioRoute.shared
        r.fake = "Kitchen"
        XCTAssertEqual(r.externalName, "Kitchen")
        r.fake = nil
        XCTAssertNil(r.externalName, "the simulator plays on its speaker")
    }

    @MainActor func testOfflineBarText() {
        XCTAssertEqual(OfflineBanner.text(offlineMode: false), "No internet connection")
        XCTAssertEqual(OfflineBanner.text(offlineMode: true), "Offline mode is on")
    }
}
