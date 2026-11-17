// Stream ios-video: Now Playing's "Switch to video" / "Switch to audio" on the mock core (which
// swaps versions like the core and never draws a frame, so the video's poster frame shows).
import XCTest
import SwiftUI
import SnapshotTesting
@testable import Encore

/// Discovery: "One More Time" (track 1) pairs with its music video FGBhQbmPwH8 in the fixture.
private let discovery = "MPREb_7ltM34kr0mH"
private let oneMoreTimeVideo = "FGBhQbmPwH8"

@MainActor
private func playDiscovery(_ app: AppModel, paused: Bool = true) async {
    guard let a = try? await app.core.getAlbum(id: discovery) else { return XCTFail("no Discovery fixture") }
    app.player.play(a.items, at: 0, context: PlayContext(kind: .album, id: discovery, title: a.title ?? ""))
    try? await Task.sleep(for: .milliseconds(400))
    if paused { app.player.togglePause() }
    try? await Task.sleep(for: .milliseconds(200))
}

@MainActor
private func waitUntil(_ cond: () -> Bool, timeout: Double = 4) async {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
}

final class VideoSnapshotTests: SnapshotCase {
    /// A song with a music video: its cover, and the "Switch to video" pill under it.
    func testNowPlayingSwitchToVideo() async {
        await snap("encore://nowplaying", setup: { app in await playDiscovery(app); VideoStore.shared.attach(app) }, wait: 1.2)
    }

    /// Switched: the video's frame in a 16:9 box where the cover was, "Switch to audio" under it.
    func testNowPlayingVideo() async {
        await snap("encore://nowplaying", setup: { app in
            await playDiscovery(app)
            VideoStore.shared.attach(app)
            VideoStore.shared.pick(true)
            await waitUntil { app.player.current?.isVideo == true && VideoStore.shared.switching == nil }
            app.player.togglePause()
        }, wait: 1.2)
    }
}

final class VideoModelTests: XCTestCase {
    private var app: AppModel!

    @MainActor override func setUp() async throws {
        app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        VideoStore.shared.attach(app)
    }

    @MainActor override func tearDown() async throws { app = nil }

    /// The pill is offered only where the playing song has a music video (its `counterpart`).
    @MainActor func testSwitchOnlyWhereThereIsAVideo() async throws {
        let late = try await app.core.getPlaylist(id: "LOCALPLAYLIST:1")
        let plain = try XCTUnwrap(late.items.firstIndex { $0.counterpart == nil && $0.isVideo != true })
        app.player.play(late.items, at: plain, context: PlayContext(kind: .playlist, id: "LOCALPLAYLIST:1", title: "x"))
        await waitUntil { self.app.player.current?.videoId == late.items[plain].videoId }
        XCTAssertFalse(VideoStore.shared.canSwitch, "no music video: no pill")
        await playDiscovery(app)
        XCTAssertEqual(app.player.current?.counterpart, oneMoreTimeVideo)
        XCTAssertTrue(VideoStore.shared.canSwitch)
        XCTAssertFalse(VideoStore.shared.side, "the song plays first (Spotify), never the video")
    }

    /// Switch to video plays the video version from the same moment; Switch to audio goes back.
    @MainActor func testSwitchToVideoAndBack() async {
        await playDiscovery(app)
        let song = app.player.current?.videoId
        app.player.seek(42)
        VideoStore.shared.pick(true)
        XCTAssertTrue(VideoStore.shared.side, "the picked side holds while the video loads")
        XCTAssertTrue(VideoStore.shared.showsVideo)
        await waitUntil { self.app.player.current?.isVideo == true }
        XCTAssertEqual(app.player.current?.videoId, oneMoreTimeVideo)
        XCTAssertEqual(app.player.current?.counterpart, song, "the song stays the way back")
        XCTAssertEqual(app.player.position, 42, accuracy: 1)
        await waitUntil { VideoStore.shared.switching == nil }
        VideoStore.shared.pick(false)
        await waitUntil { self.app.player.current?.isVideo == false }
        XCTAssertEqual(app.player.current?.videoId, song)
        XCTAssertFalse(VideoStore.shared.showsVideo)
    }

    /// Spotify: no video in offline mode, with no connection, or on Data Saver.
    @MainActor func testNoVideoOfflineOrOnDataSaver() async {
        await playDiscovery(app)
        XCTAssertTrue(VideoStore.shared.canSwitch)
        app.settings.set(SettingKey.dataSaver, true)
        XCTAssertFalse(VideoStore.shared.canSwitch, "Data Saver")
        app.settings.set(SettingKey.dataSaver, false)
        app.downloads.snapshot.network.offline = true
        XCTAssertFalse(VideoStore.shared.canSwitch, "offline")
        VideoStore.shared.want = true
        XCTAssertFalse(VideoStore.shared.showsVideo)
        app.downloads.snapshot.network.offline = false
        XCTAssertTrue(VideoStore.shared.canSwitch)
    }

    /// A video with no song version: "Switch to audio" hides the picture (the sound is the video's).
    @MainActor func testVideoWithoutSongHidesPicture() async throws {
        let mock = try XCTUnwrap(app.core as? MockCoreClient)
        await playDiscovery(app)
        mock.withLock { mock.items[mock.current].isVideo = true; mock.items[mock.current].counterpart = nil }
        mock.emit("queue-changed", mock.withLock { mock.queuePayload() })
        await waitUntil { self.app.player.current?.isVideo == true }
        XCTAssertTrue(VideoStore.shared.showsVideo, "a video shows by default")
        VideoStore.shared.pick(false)
        XCTAssertFalse(VideoStore.shared.showsVideo)
        XCTAssertTrue(VideoStore.shared.canSwitch, "and can come back")
        VideoStore.shared.pick(true)
        XCTAssertTrue(VideoStore.shared.showsVideo)
    }
}

// MARK: stream video-pods: video podcasts

/// The first episode of the first followed show (the Huberman fixture: YouTube episodes, so each
/// one is a video upload and shows itself).
@MainActor
private func playEpisode(_ app: AppModel, paused: Bool = true) async {
    guard let show = try? await app.core.podcastFollows().first,
          let page = try? await app.core.podcastShow(id: show.id, sort: .newest),
          let e = page.episodes.first else { return XCTFail("no episode fixture") }
    app.player.play(page.episodes.map(\.song), at: 0, context: PlayContext(kind: .song, id: nil, title: e.showTitle))
    await waitUntil { app.player.current?.videoId == e.id }
    if paused { app.player.togglePause() }
    await waitUntil { VideoStore.shared.episodeSrc != nil }
}

final class EpisodeVideoTests: XCTestCase {
    private var app: AppModel!

    @MainActor override func setUp() async throws {
        app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        VideoStore.shared.attach(app)
    }

    @MainActor override func tearDown() async throws {
        app.settings.set(SettingKey.podcastAudioOnly, false)
        app = nil
    }

    /// A video podcast shows its video in place of the cover by default (Spotify), with the pill.
    @MainActor func testEpisodeShowsItsVideo() async throws {
        await playEpisode(app)
        let v = VideoStore.shared
        XCTAssertTrue(v.isEpisode)
        XCTAssertEqual(v.episodeSrc?.videoId, app.player.current?.videoId, "a YouTube episode is its own picture")
        XCTAssertTrue(v.hasPicture)
        XCTAssertTrue(v.canSwitch)
        XCTAssertTrue(v.side)
        XCTAssertTrue(v.showsVideo)
        // "Switch to audio" hides the picture; the episode keeps playing (same row, no version swap).
        let id = app.player.current?.videoId
        v.pick(false)
        XCTAssertFalse(v.showsVideo)
        XCTAssertTrue(v.canSwitch)
        XCTAssertEqual(app.player.current?.videoId, id)
        v.pick(true)
        XCTAssertTrue(v.showsVideo)
    }

    /// With Now Playing closed, the mini player has the live picture; open, Now Playing has it.
    @MainActor func testMiniPlayerShowsTheVideo() async {
        await playEpisode(app)
        let v = VideoStore.shared
        app.router.nowPlayingOpen = false
        XCTAssertTrue(v.miniShowsVideo)
        XCTAssertFalse(v.landscapeAllowed, "full screen only from Now Playing")
        app.router.nowPlayingOpen = true
        XCTAssertFalse(v.miniShowsVideo)
        XCTAssertTrue(v.landscapeAllowed, "turning the phone gives the full-screen video")
    }

    /// The setting starts video podcasts on the audio side; the pill still offers the video.
    @MainActor func testAudioOnlySetting() async {
        app.settings.set(SettingKey.podcastAudioOnly, true)
        await playEpisode(app)
        let v = VideoStore.shared
        await waitUntil { v.episodeSrc?.auto == false }
        XCTAssertFalse(v.side)
        XCTAssertFalse(v.showsVideo)
        XCTAssertTrue(v.canSwitch)
        v.pick(true)
        XCTAssertTrue(v.showsVideo)
    }

    /// No video podcast picture on Data Saver or offline (the music-video rule).
    @MainActor func testNoEpisodeVideoOnDataSaver() async {
        await playEpisode(app)
        XCTAssertTrue(VideoStore.shared.canSwitch)
        app.settings.set(SettingKey.dataSaver, true)
        XCTAssertFalse(VideoStore.shared.canSwitch, "Data Saver")
        XCTAssertFalse(VideoStore.shared.showsVideo)
        await waitUntil { VideoStore.shared.episodeSrc == nil }
        XCTAssertNil(VideoStore.shared.episodeSrc, "the core offers none either")
        app.settings.set(SettingKey.dataSaver, false)
        await waitUntil { VideoStore.shared.episodeSrc != nil }
        XCTAssertTrue(VideoStore.shared.canSwitch)
    }
}

final class EpisodeVideoSnapshotTests: SnapshotCase {
    /// A video podcast in Now Playing: the video box (its poster on the mock) and "Switch to audio".
    func testNowPlayingEpisodeVideo() async {
        await snap("encore://nowplaying", setup: { app in
            VideoStore.shared.attach(app)
            await playEpisode(app)
        }, wait: 1.2)
    }
}

// MARK: full-screen video and swiping the video (Spotify's video podcasts)

final class VideoFullscreenTests: XCTestCase {
    private var app: AppModel!

    @MainActor override func setUp() async throws {
        app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        VideoStore.shared.attach(app)
        await playEpisode(app)
        app.router.nowPlayingOpen = true
    }

    @MainActor override func tearDown() async throws {
        VideoStore.shared.exitFullscreen()
        app.router.nowPlayingOpen = false
        app = nil
    }

    /// A tap on the video: full screen, landscape only (the phone is upright); collapse: back to
    /// Now Playing, which may turn again.
    @MainActor func testTapIntoFullscreenAndCollapse() async {
        let v = VideoStore.shared
        await waitUntil { OrientationLock.mask == .allButUpsideDown }
        XCTAssertEqual(OrientationLock.mask, .allButUpsideDown, "a video in Now Playing may turn")
        v.enterFullscreen()
        XCTAssertTrue(v.fullscreen)
        XCTAssertTrue(v.fullscreenByTap)
        XCTAssertEqual(OrientationLock.mask, .landscape)
        v.exitFullscreen()
        XCTAssertFalse(v.fullscreen)
        XCTAssertTrue(app.router.nowPlayingOpen, "collapse returns to Now Playing, not further")
        XCTAssertEqual(OrientationLock.mask, .allButUpsideDown)
    }

    /// Turning the phone opens full screen, turning it back closes it; never on the audio side.
    @MainActor func testTurningThePhone() {
        let v = VideoStore.shared
        v.rotated(landscape: true)
        XCTAssertTrue(v.fullscreen)
        XCTAssertFalse(v.fullscreenByTap)
        v.rotated(landscape: false)
        XCTAssertFalse(v.fullscreen)
        v.pick(false)
        v.rotated(landscape: true)
        XCTAssertFalse(v.fullscreen, "no video showing: Now Playing stays")
        v.enterFullscreen()
        XCTAssertFalse(v.fullscreen)
        v.rotated(landscape: false)
        v.pick(true)
    }

    /// The video going away (Now Playing closed) collapses full screen and locks portrait again.
    @MainActor func testClosingNowPlayingCollapses() async {
        let v = VideoStore.shared
        v.enterFullscreen()
        XCTAssertTrue(v.fullscreen)
        app.router.nowPlayingOpen = false
        await waitUntil { !v.fullscreen }
        XCTAssertFalse(v.fullscreen)
        XCTAssertEqual(OrientationLock.mask, .portrait)
    }
}

final class VideoFullscreenSnapshotTests: SnapshotCase {
    /// Hosts one view in its own window, off the top inset (no safe area, like Now Playing's cover).
    private func snapView<V: View>(_ view: V, size: CGSize, insets: UIEdgeInsets = .zero, wait: Double = 1.2,
                                   file: StaticString = #filePath, testName: String = #function, line: UInt = #line) async {
        let w = UIWindow(windowScene: window.windowScene!)
        w.frame = CGRect(origin: CGPoint(x: 0, y: 200), size: size)
        let host = UIHostingController(rootView: view.environment(app))
        host.additionalSafeAreaInsets = insets
        w.rootViewController = host
        w.windowLevel = .alert + 2
        w.makeKeyAndVisible()
        try? await Task.sleep(for: .seconds(wait))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let image = UIGraphicsImageRenderer(bounds: w.bounds, format: fmt).image { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
        }
        w.isHidden = true
        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: image, as: .image(precision: 0.985, perceptualPrecision: 0.97), file: file, testName: testName, line: line)
        }
    }

    /// Full screen in landscape (iPhone 17 Pro, 874 × 402), overlay up: show name and ⋯, −15 /
    /// play / +15, title + show with collapse, the chaptered scrubber with the chapter's name.
    func testFullscreenOverlayLandscape() async {
        VideoStore.shared.attach(app)
        await playEpisode(app)
        guard let id = app.player.current?.videoId else { return XCTFail("no episode") }
        await app.podcasts.loadChapters(id, duration: max(app.player.duration, 3600))
        await snapView(VideoFullscreen(), size: CGSize(width: 874, height: 402))
    }

    /// A tap on the inline video (Spotify): the picture dims and the expand arrows show at the
    /// bottom right. No captions or quality buttons: the core has neither for these videos.
    func testInlineVideoControls() async {
        VideoStore.shared.attach(app)
        await playEpisode(app)
        await snapView(NPArtwork(fallback: nil, video: true, chrome: true)
                        .padding(.horizontal, Space.xl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: "#404040")),
                       size: CGSize(width: 402, height: 460), wait: 1.0)
    }

    /// Mid-swipe on the video: it slides left and the next episode's cover peeks in.
    func testSwipePeekOnVideo() async {
        VideoStore.shared.attach(app)
        await playEpisode(app)
        await snapView(NPArtwork(fallback: nil, video: true, peek: -130)
                        .padding(.horizontal, Space.xl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: "#404040")),
                       size: CGSize(width: 402, height: 460))
    }
}

// MARK: chapter detents on the scrubber

/// A 1000 s episode on a 1000 pt bar: 1 s = 1 pt, so the thresholds read directly.
final class ChapterDetentTests: XCTestCase {
    private let list = [0.0, 60, 300, 312].map { PodcastChapter(startSecs: $0, title: "c\($0)", startLabel: "") }
    private func settle(_ pos: Double, speed: Double = 0, width: Double = 1000) -> Double {
        chapterSettle(list, pos, duration: 1000, width: width, speed: speed)
    }
    private func detent(_ pos: Double) -> Double { chapterDetent(list, pos, duration: 1000, width: 1000) }

    /// Same cases as ui/src/lib/scrub.check.ts.
    func testSettlesOnlyASlowReleaseAFewPointsFromAStart() {
        XCTAssertEqual(settle(66), 60, "6 pt before or after a start, slow: onto it")
        XCTAssertEqual(settle(54), 60)
        XCTAssertEqual(settle(67), 60, "7 pt: the edge of the radius")
        XCTAssertEqual(settle(68), 68, "8 pt: exactly where released")
        XCTAssertEqual(settle(150), 150, "far from every start")
        XCTAssertEqual(settle(64, speed: 149), 60, "a slow drag still settles")
        XCTAssertEqual(settle(64, speed: 151), 64, "faster than 150 pt/s: never")
        XCTAssertEqual(settle(60.5, speed: 2000), 60.5, "a flick never snaps, even right on a start")
        XCTAssertEqual(settle(3), 3, "the 0:00 start is no detent")
        XCTAssertEqual(settle(307), 312, "two close starts: the nearest wins")
        XCTAssertEqual(settle(305), 300)
        // On screen, not a share of the episode: the same 6 s is 0.6 pt on a 100 pt bar (settles),
        // 60 pt on a 10 000 pt one (doesn't).
        XCTAssertEqual(settle(66, width: 100), 60)
        XCTAssertEqual(settle(66, width: 10_000), 66)
        XCTAssertEqual(chapterSettle(list, 64, duration: 0, width: 1000, speed: 0), 64, "no length")
        XCTAssertEqual(chapterSettle([], 64, duration: 1000, width: 1000, speed: 0), 64, "no chapters")
        // A settled position counts as the chapter it lands on (the tick and the live title).
        XCTAssertEqual(chapterAt(list, settle(56)), 1)
    }

    /// The thumb never jumps: it follows the finger 1:1 outside the zone, is held near a start, and
    /// keeps moving the same way through it.
    func testDetentDampsButNeverJumps() {
        XCTAssertEqual(detent(100), 100, "outside every zone: the finger")
        XCTAssertEqual(detent(72), 72, "12 pt from a start: the zone's edge")
        XCTAssertEqual(detent(60), 60, "on a start: on it")
        let u = 1 - 1.0 / 12
        XCTAssertEqual(detent(61) - 60, 1 - 0.85 * u * u, accuracy: 0.001)
        XCTAssertLessThan(abs(detent(61) - 60), 0.35, "1 pt of finger past a start: the thumb barely moves")
        XCTAssertLessThan(abs(detent(59) - 60), 0.35)
        // Monotonic, continuous, at most ~2 pt off the finger.
        var last = detent(0)
        for i in 1...4000 {
            let x = Double(i) / 10, y = detent(x)
            XCTAssertGreaterThanOrEqual(y, last, "never backwards at \(x)")
            XCTAssertLessThan(y - last, 0.2, "never jumps at \(x)")
            XCTAssertLessThan(abs(y - x), 2, "stays under the finger at \(x)")
            last = y
        }
        // Two starts 12 pt apart: the zones shrink to 6 pt each, so the midpoint is the finger.
        XCTAssertEqual(detent(306), 306, accuracy: 0.0001)
        XCTAssertEqual(chapterDetent(list, 64, duration: 0, width: 1000), 64, "no length")
    }

    func testReleaseSpeed() {
        let moving = (0..<10).map { (x: Double($0) * 5, t: Double($0) * 0.016) }  // 5 pt a frame
        XCTAssertEqual(releaseSpeed(moving, end: 0.15), 312.5, accuracy: 1, "lifted while moving")
        XCTAssertEqual(releaseSpeed(moving, end: 0.3), 0, "rested before lifting")
        let slow = (0..<20).map { (x: Double($0) * 0.5, t: Double($0) * 0.016) }
        XCTAssertEqual(releaseSpeed(slow, end: 0.31), 31.25, accuracy: 1)
        XCTAssertEqual(releaseSpeed([], end: 1), 0)
        XCTAssertEqual(releaseSpeed([(x: 4, t: 1)], end: 1), 0, "one touch: a tap")
    }
}

// MARK: one picture, moved between boxes

@MainActor
final class VideoHostTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows = []
    }

    private func box(in frame: CGRect) throws -> VideoBox {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let w = UIWindow(windowScene: scene)
        w.frame = frame
        w.isHidden = false
        windows.append(w)
        let b = VideoBox(frame: w.bounds)
        w.addSubview(b)
        return b
    }

    /// The newest active box gets the picture, sized to it; an old box going away late (SwiftUI
    /// tears down the full-screen view after Now Playing's box asked) can't take it back.
    func testNewestActiveBoxWinsWhateverTheOrder() throws {
        let inline = try box(in: CGRect(x: 0, y: 0, width: 360, height: 203))
        let full = try box(in: CGRect(x: 0, y: 0, width: 874, height: 402))
        inline.active = true
        XCTAssertTrue(VideoHost.shared.current === inline)
        full.active = true
        XCTAssertTrue(VideoHost.shared.current === full)
        full.layoutIfNeeded()
        assertLetterboxed(in: full)
        XCTAssertTrue(SampleBufferView.shared.superview === full, "PiP's layer goes along")
        // Back from full screen: the inline box asks first, the full-screen box leaves afterwards.
        inline.active = false
        inline.active = true
        full.active = false
        XCTAssertTrue(VideoHost.shared.current === inline, "the old box leaving keeps it where it is")
        inline.layoutIfNeeded()
        assertLetterboxed(in: inline)
        // And the other order: the full-screen box leaves first.
        full.active = true
        XCTAssertTrue(VideoHost.shared.current === full)
        full.active = false
        XCTAssertTrue(VideoHost.shared.current === inline, "back to the box still asking")
        inline.active = false
    }

    /// A box activated before it is in a window gets the picture once it joins one.
    func testBoxJoiningTheWindowLater() throws {
        let a = try box(in: CGRect(x: 0, y: 0, width: 360, height: 203))
        a.active = true
        let b = VideoBox(frame: CGRect(x: 0, y: 0, width: 200, height: 113))
        b.active = true
        XCTAssertTrue(VideoHost.shared.current === a, "not on screen yet")
        a.window?.addSubview(b)
        XCTAssertTrue(VideoHost.shared.current === b)
        b.active = false
        a.active = false
    }

    /// mpv's view in `box`: its fixed size, centred, scaled to fit (letterboxed, never stretched or
    /// in a corner), so MoltenVK never sees a new size.
    private func assertLetterboxed(in box: UIView, file: StaticString = #filePath, line: UInt = #line) {
        let v = MPVLayerView.shared
        XCTAssertEqual(v.bounds.size, MPVLayerView.fixedSize, "the layer's own size never changes", file: file, line: line)
        XCTAssertEqual(v.frame.midX, box.bounds.midX, accuracy: 0.5, "centred", file: file, line: line)
        XCTAssertEqual(v.frame.midY, box.bounds.midY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(v.frame.width / v.frame.height, 16 / 9, accuracy: 0.01, "16:9, unstretched", file: file, line: line)
        XCTAssertTrue(v.frame.width <= box.bounds.width + 0.5 && v.frame.height <= box.bounds.height + 0.5, "fits", file: file, line: line)
        XCTAssertTrue(abs(v.frame.width - box.bounds.width) < 0.5 || abs(v.frame.height - box.bounds.height) < 0.5, "fills one side", file: file, line: line)
        XCTAssertEqual(v.metal.drawableSize, MPVLayerView.drawablePixels, file: file, line: line)
    }

    /// The drawable never follows the box: one 16:9 size, MoltenVK's own size for the layer.
    func testFixedDrawable() {
        let px = MPVLayerView.drawablePixels
        XCTAssertEqual(px.width / px.height, 16 / 9, accuracy: 0.01)
        XCTAssertEqual(px.width, MPVLayerView.fixedSize.width * UIScreen.main.nativeScale, accuracy: 0.5)
    }
}
