// Lane P3 (docs/compare/SYNC-GAPS.md §3, docs/streams/ios-p3.md): the friendly-error mapping (a
// replay of the desktop's `ui/src/lib/neterr.check.ts`), no silent mock fallback (the error
// screen), and every user action that fails reverts its optimistic UI and toasts.
import XCTest
import SwiftUI
import SnapshotTesting
@testable import Encore

// MARK: friendly errors (same cases as neterr.check.ts)

final class FriendlyErrorTests: XCTestCase {
    private let W = FriendlyError.words
    private let REQWEST = "http: error sending request for url (https://music.youtube.com/youtubei/v1/browse)"

    func testWordingMatchesTheDesktop() {
        // ui/src/lib/neterr.ts DEFAULT_ERROR_WORDS, word for word.
        XCTAssertEqual(W.unreachable, "Can't reach YouTube Music. Check your connection.")
        XCTAssertEqual(W.rateLimited, "YouTube is busy right now. Try again in a moment.")
        XCTAssertEqual(W.signIn, "Sign in to do that.")
        XCTAssertEqual(W.forbidden, "YouTube didn't allow that.")
        XCTAssertEqual(W.notFound, "That isn't available any more.")
        XCTAssertEqual(W.generic, "Something went wrong. Try again.")
    }

    func testTheNetworkIsRecognised() {
        XCTAssertTrue(FriendlyError.isUnreachable(REQWEST))
        XCTAssertTrue(FriendlyError.isUnreachable("http: request or response body error for url (https://music.youtube.com/)"))
        XCTAssertTrue(FriendlyError.isUnreachable("could not reach YouTube. Check your connection and try again (no client answered)"))
        for other in [
            "Your YouTube Music session expired, open the account menu and sign in again.",
            "This track is already in the playlist.",
            "http: HTTP status client error (404 Not Found) for url (https://music.youtube.com/)",
            "json: invalid type: null, expected a string at line 1 column 8",
            "Couldn't load this track. The stream link was refused.",
            "this file is no longer on your disk: /home/me/gone.flac",
        ] {
            XCTAssertFalse(FriendlyError.isUnreachable(other), other)
        }
    }

    func testFriendlySentencesPassThrough() {
        for fine in [
            "This album has no radio.",
            "YouTube has no radio for this.",
            "Couldn't load this track. The stream link was refused.",
            "Your YouTube Music session expired, open the account menu and sign in again.",
        ] {
            XCTAssertTrue(FriendlyError.looksFriendly(fine), fine)
            XCTAssertEqual(friendlyError(fine, "Couldn't start radio"), fine)
        }
    }

    func testRawTextNeverReachesTheToast() {
        for raw in [
            "http: HTTP status client error (404 Not Found) for url (https://music.youtube.com/)",
            "json: invalid type: null, expected a string at line 1 column 8",
            "DataCloneError: Failed to execute 'structuredClone' on 'Window': #<Object> could not be cloned.",
            "no metadata client",
            "unknown radio kind: banana",
            "[object Object]",
            "TypeError: Cannot read properties of undefined (reading 'id')",
        ] {
            XCTAssertFalse(FriendlyError.looksFriendly(raw), raw)
            XCTAssertEqual(friendlyError(raw, "Couldn't start radio"), "Couldn't start radio. Try again.", raw)
            XCTAssertFalse(friendlyError(raw).contains(":"), "no raw text without a context either: \(raw)")
        }
    }

    func testFailureFamilies() {
        XCTAssertEqual(friendlyError(REQWEST, "Couldn't start radio"), W.unreachable, "the network wins over the context")
        XCTAssertEqual(friendlyError("HTTP 429 Too Many Requests"), W.rateLimited)
        XCTAssertEqual(friendlyError("http: HTTP status client error (401 Unauthorized)"), W.signIn)
        XCTAssertEqual(friendlyError("http: HTTP status client error (403 Forbidden)"), W.forbidden)
        XCTAssertEqual(friendlyError("http: HTTP status client error (404 Not Found) for url (x)"), W.notFound, "404 without context")
        XCTAssertEqual(friendlyError("oops", "Couldn't save."), "Couldn't save. Try again.", "no double full stop")
    }

    func testSwiftErrorsAndTheCoresOwnMessage() {
        struct Boom: Error {}
        XCTAssertEqual(friendlyError(Boom()), W.generic, "a Swift error with no context is the generic sentence")
        XCTAssertTrue(FriendlyError.raw(Boom()).hasPrefix("Boom: "), "the raw text keeps the type for the log")
        XCTAssertEqual(FriendlyError.raw(CoreFailure(message: "nope")), "nope", "the core's message as is")
        XCTAssertEqual(friendlyError(CoreFailure(message: "This album has no radio.")), "This album has no radio.")
        XCTAssertEqual(friendlyError(CoreFailure(message: REQWEST), "Couldn't play this"), W.unreachable)
        XCTAssertTrue(FriendlyError.isCancellation(CancellationError()))
    }
}

// MARK: no silent mock fallback

@MainActor
final class CoreBootTests: XCTestCase {
    func testAFailedStartIsAnErrorScreenNeverTheMock() {
        var tries = 0
        let boot = CoreBoot { tries += 1; throw CoreFailure(message: "database: unable to open database file (code 14)") }
        XCTAssertNil(boot.app, "no app, so no fixtures dressed up as your library")
        XCTAssertEqual(boot.failure?.raw, "database: unable to open database file (code 14)")
        boot.retry()
        XCTAssertEqual(tries, 2, "Try again starts the core again")
        XCTAssertNotNil(boot.failure)
    }

    func testRetryRecovers() {
        var fail = true
        let boot = CoreBoot {
            if fail { throw CoreFailure(message: "locked") }
            return MockCoreClient()
        }
        XCTAssertNotNil(boot.failure)
        fail = false
        boot.retry()
        XCTAssertNotNil(boot.app)
        XCTAssertNil(boot.failure)
        boot.retry()
        XCTAssertEqual(boot.attempts, 2, "a running app is never restarted")
    }

    func testTestsGetTheMock() {
        XCTAssertTrue(CoreBoot.usesMock, "hosted unit tests run on the mock")
    }

    func testDiagnosticsCarryTheError() throws {
        let f = CoreStartFailure(raw: "database: disk I/O error")
        let report = Diagnostics.report(f)
        XCTAssertTrue(report.contains("database: disk I/O error"))
        XCTAssertTrue(report.contains("iOS:"))
        let url = Diagnostics.write(f)
        XCTAssertEqual(url.lastPathComponent, "diagnostics.txt")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("disk I/O error"))
    }

    func testErrorScreenSnapshot() async throws {
        ArtworkCache.stubbed = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CoreStartFailedView(failure: CoreStartFailure(raw: "x")) {})
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: fmt).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: image, as: .image(precision: 0.985, perceptualPrecision: 0.97))
        }
    }
}

// MARK: revert and toast

@MainActor
final class RevertAndToastTests: XCTestCase {
    private var app: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        CoreFaults.failing = []
        app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
    }

    override func tearDown() async throws {
        CoreFaults.failing = []
        app = nil
        try await super.tearDown()
    }

    private func failing(_ actions: String...) { CoreFaults.failing = Set(actions) }
    private var toast: String? { app.toast?.text }
    private func settle(_ a: CoreActions) async { _ = await a.last?.value; for _ in 0..<3 { await Task.yield() } }
    private func song(_ id: String) -> SongItem { SongItem(videoId: id, title: "Song \(id)", artists: "A") }

    func testFaultsAreScopedToTheNamedAction() async {
        failing("like")
        let real = CoreActions(core: app.core)
        let e = await real.attempt("like") {}
        XCTAssertNotNil(e, "the mock honours an injected fault")
        let other = await real.attempt("other") {}
        XCTAssertNil(other, "only for the named action")
    }

    func testLikeRevertsTheHeart() async {
        failing("like")
        let s = song("p3-like")
        app.toggleLike(s)
        XCTAssertTrue(app.library.isLiked(s.videoId), "optimistic: the heart fills at once")
        await settle(app.library.actions)
        XCTAssertFalse(app.library.isLiked(s.videoId), "and empties again when the core refuses")
        XCTAssertEqual(toast, "Couldn't update Liked Songs. Try again.")
    }

    func testLikeThatWorksStays() async {
        let s = song("p3-like-ok")
        app.toggleLike(s)
        await settle(app.library.actions)
        XCTAssertTrue(app.library.isLiked(s.videoId))
        XCTAssertEqual(toast, "Added to Liked Songs")
    }

    func testPinReverts() async {
        failing("pin")
        let before = app.library.snapshot.pinnedIds
        let item = BrowseItem(kind: .playlist, id: "LOCALPLAYLIST:p3", title: "P3")
        app.library.setPinned(item, true)
        XCTAssertEqual(app.library.snapshot.pinnedIds.first, item.id)
        await settle(app.library.actions)
        XCTAssertEqual(app.library.snapshot.pinnedIds, before)
        XCTAssertEqual(toast, "Couldn't pin this. Try again.")
    }

    func testSaveReports() async {
        failing("save")
        let item = BrowseItem(kind: .album, id: "MPREb_p3", title: "Album")
        app.library.toggleSaved(item)
        await settle(app.library.actions)
        XCTAssertFalse(app.library.isSaved(item.id))
        XCTAssertEqual(toast, "Couldn't update Your Library. Try again.")
    }

    func testPlayReports() async {
        failing("play")
        app.player.play([song("a")], at: 0, context: PlayContext(kind: .song, id: nil, title: "x"))
        await settle(app.player.actions)
        XCTAssertEqual(toast, "Couldn't play this. Try again.")
        app.player.playSingle(song("b"))
        await settle(app.player.actions)
        XCTAssertEqual(toast, "Couldn't play this song. Try again.")
    }

    func testPauseReverts() async {
        failing("pause")
        let was = app.player.paused
        app.player.togglePause()
        XCTAssertNotEqual(app.player.paused, was)
        await settle(app.player.actions)
        XCTAssertEqual(app.player.paused, was)
        XCTAssertNotNil(toast)
    }

    func testQueueNeverSaysAddedWhenItWasnt() async {
        failing("queue")
        app.queue([song("q")])
        await settle(app.player.actions)
        XCTAssertEqual(toast, "Couldn't add to queue. Try again.")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(toast, "Couldn't add to queue. Try again.", "no late \"Added to queue\"")
    }

    func testQueueThatWorksSaysSo() async {
        app.queue([song("q2")])
        await settle(app.player.actions)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(toast, "Added to queue")
    }

    func testPlaybackErrorIsFriendly() {
        app.apply(.playbackError("http: HTTP status client error (403 Forbidden) for url (https://rr1---sn.googlevideo.com/x)"))
        XCTAssertEqual(toast, "YouTube didn't allow that.")
        app.apply(.playbackError("mpv: loading failed (code -13)"))
        XCTAssertEqual(toast, "Couldn't play this song. Try again.")
    }

    // MARK: Add to playlist

    private var ownPlaylist: LibPlaylist { app.library.snapshot.playlists.first! }

    func testAddToPlaylistFailureSaysSoNotAdded() async {
        failing("addToPlaylist")
        let pl = ownPlaylist
        let ok = await AddToPlaylistSave.apply(app, songs: [song("p3-add")], added: [pl.id], removed: [], names: [pl.id: pl.name])
        XCTAssertFalse(ok)
        XCTAssertEqual(toast, "Couldn't add to \(pl.name). Try again.")
        XCTAssertFalse(toast?.hasPrefix("Added") ?? false)
    }

    func testAddToPlaylistSuccess() async {
        let pl = ownPlaylist
        let ok = await AddToPlaylistSave.apply(app, songs: [song("p3-add-ok")], added: [pl.id], removed: [], names: [pl.id: pl.name])
        XCTAssertTrue(ok)
        XCTAssertEqual(toast, "Added to \(pl.name)")
    }

    func testPickerLikeFailurePutsTheHeartBack() async {
        failing("like")
        let s = song("p3-pick-like")
        let ok = await AddToPlaylistSave.apply(app, songs: [s], added: [likedPlaylistId], removed: [], names: [likedPlaylistId: "Liked Songs"])
        XCTAssertFalse(ok)
        XCTAssertFalse(app.library.isLiked(s.videoId))
        XCTAssertEqual(toast, "Couldn't add to Liked Songs. Try again.")
    }

    func testSeveralChangesFailingSayTheSaveFailed() async {
        failing("addToPlaylist", "removeFromPlaylist")
        let pl = ownPlaylist
        let other = app.library.snapshot.playlists.dropFirst().first?.id ?? "LOCALPLAYLIST:none"
        let ok = await AddToPlaylistSave.apply(app, songs: [song("p3-many")], added: [pl.id], removed: [other], names: [:])
        XCTAssertFalse(ok)
        XCTAssertEqual(toast, "Couldn't save all your changes. Try again.")
    }

    func testCreatePlaylistFailure() async {
        failing("createPlaylist")
        let ok = await AddToPlaylistSave.create(app, name: "P3 New", songs: [song("p3-new")])
        XCTAssertFalse(ok)
        XCTAssertEqual(toast, "Couldn't create the playlist. Try again.")
        XCTAssertFalse(app.library.snapshot.playlists.contains { $0.name == "P3 New" })
    }

    // MARK: podcasts, downloads, settings

    func testFollowAndSaveEpisodeRevert() async throws {
        failing("follow", "saveEpisode")
        let show = try XCTUnwrap(app.podcasts.follows.first, "the mock follows some shows")
        XCTAssertFalse(app.podcasts.toggleFollow(show))
        XCTAssertFalse(app.podcasts.isFollowed(show.id))
        await settle(app.podcasts.actions)
        XCTAssertTrue(app.podcasts.isFollowed(show.id), "unfollow refused: still followed")
        XCTAssertEqual(toast, "Couldn't unfollow this show. Try again.")

        let ep = try XCTUnwrap(app.podcasts.saved.first, "the mock saves some episodes")
        app.podcasts.toggleSaved(ep)
        await settle(app.podcasts.actions)
        XCTAssertTrue(app.podcasts.isSaved(ep))
        XCTAssertEqual(toast, "Couldn't update Your Episodes. Try again.")
    }

    func testDownloadAddReverts() async {
        failing("download")
        let c = DownloadCollection(id: "MPREb_p3dl", kind: "album", title: "P3")
        app.downloads.add(c, songs: [song("d1")])
        XCTAssertTrue(app.downloads.isCollectionDownloaded(c.id))
        await settle(app.downloads.actions)
        XCTAssertFalse(app.downloads.isCollectionDownloaded(c.id))
        XCTAssertEqual(toast, "Couldn't download this. Try again.")
    }

    func testDownloadRetry() async {
        failing("download")
        let failed = await app.downloads.retry().value
        XCTAssertFalse(failed)
        XCTAssertEqual(toast, "Couldn't retry the downloads. Try again.")
        CoreFaults.failing = []
        let ok = await app.downloads.retry().value
        XCTAssertTrue(ok)
    }

    func testFailedCollectionOffersRetry() {
        app.downloads.snapshot.collections = [DownloadCollectionStatus(id: "X", kind: "album", title: "X", subtitle: nil, thumbnail: nil,
                                                                       total: 10, done: 7, failed: 3, bytes: 0, addedAt: 0)]
        app.downloads.active = [:]
        XCTAssertEqual(app.downloads.state("X"), .failed(3))
        app.downloads.snapshot.collections[0].failed = 0
        guard case .downloading = app.downloads.state("X") else { return XCTFail("still going: a progress ring, not Retry") }
    }

    func testSettingWriteReverts() async {
        failing("setting")
        let before = app.settings.values["p3_test"]
        app.settings.set("p3_test", true)
        XCTAssertEqual(app.settings.values["p3_test"], "true")
        await settle(app.settings.actions)
        XCTAssertEqual(app.settings.values["p3_test"], before)
        XCTAssertEqual(toast, "Couldn't save that setting. Try again.")

        let priv = app.settings.smart.privateSession
        app.settings.setPrivateSession(!priv)
        await settle(app.settings.actions)
        XCTAssertEqual(app.settings.smart.privateSession, priv)

        let fade = app.settings.audio?.crossfadeSecs
        app.settings.setCrossfade(9)
        await settle(app.settings.actions)
        XCTAssertEqual(app.settings.audio?.crossfadeSecs, fade)
    }

    func testSpeedReverts() async {
        failing("speed")
        let was = app.settings.speed
        app.settings.setSpeed(1.5)
        await settle(app.settings.actions)
        XCTAssertEqual(app.settings.speed, was)
        XCTAssertEqual(toast, "Couldn't change the speed. Try again.")
    }

    // MARK: import cancel

    func testImportCancel() async {
        let flow = ImportFlow()
        flow.live = false
        flow.link = "https://open.spotify.com/playlist/x"
        await flow.read(app)
        await flow.start(app)
        XCTAssertEqual(flow.step, .progress)

        failing("importCancel")
        let refused = await flow.cancel(app)
        XCTAssertFalse(refused)
        XCTAssertEqual(flow.step, .progress, "a refused cancel stays put")
        XCTAssertEqual(flow.error, "Couldn't stop the import. Try again.")

        CoreFaults.failing = []
        let ok = await flow.cancel(app)
        XCTAssertTrue(ok)
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(flow.snapshot?.phase, "cancelled", "the done step says it stopped")
        let status = try? await app.core.importStatus()
        XCTAssertNil(status ?? nil, "the mock dropped the job")
    }
}
