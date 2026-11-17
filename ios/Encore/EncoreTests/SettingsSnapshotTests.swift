// Snapshots of Settings and privacy, every sub-page, the equalizer, the side menu and the sleep timer.
import XCTest
@testable import Encore

final class SettingsSnapshotTests: SnapshotCase {
    func testSettings() async { await snap("encore://settings") }
    func testAccount() async { await snap("encore://settings/account") }
    func testContent() async { await snap("encore://settings/content") }
    func testPlayback() async { await snap("encore://settings/playback") }
    func testPrivacy() async { await snap("encore://settings/privacy") }
    func testQuality() async { await snap("encore://settings/quality") }
    func testStorage() async { await snap("encore://settings/storage") }
    func testDataSaver() async { await snap("encore://settings/datasaver") }
    // Stream ios-p2: the YouTube account signed in (mock), Recover playlists, and Recents.
    func testAccountSignedIn() async {
        await snap("encore://settings/account", setup: { app in
            let c = HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SAPISID", .value: "s"])!
            _ = try? await app.account.complete(with: [c])
        })
    }
    func testRecoverPlaylists() async {
        await snap("encore://home", setup: { app in
            try? await app.core.deletePlaylist(id: "LOCALPLAYLIST:2")
            await app.library.refresh()
            app.router.handle(URL(string: "encore://settings/recover")!, app: app)
        }, wait: 1.5)
    }
    func testRecents() async { await snap("encore://history", wait: 1.5) }
    func testAbout() async { await snap("encore://settings/about") }
    func testEqualizerOff() async { await snap("encore://settings/eq") }
    func testEqualizerRock() async {
        await snap("encore://settings/eq", setup: { app in
            app.settings.setEqPreset("Rock")
            try? await Task.sleep(for: .milliseconds(200))
        })
    }
    func testSideMenu() async { await snap("encore://home", "encore://menu-side") }
    func testSleepTimer() async { await snap("encore://play/LOCALPLAYLIST:1?pause=1&open=1", "encore://sleep", wait: 1.2) }
}
