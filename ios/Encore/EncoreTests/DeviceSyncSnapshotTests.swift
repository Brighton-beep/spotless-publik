// Snapshots of device sync: Settings › Devices (not linked, linked, linked with an error), the
// linking sheet (intro, showing a code, entering one, linked, every error), the first-run welcome
// and the Home hint. The mock shows the fixed code 482913.
import XCTest
@testable import Encore

final class DeviceSyncSnapshotTests: SnapshotCase {
    private var mock: MockCoreClient { app.core as! MockCoreClient }

    private func linked(pending: Int = 0, error: String? = nil, ago: Double = 5) -> (AppModel) async -> Void {
        { [m = mock] app in
            m.mockSyncLink(pending: pending, error: error, lastSyncAgo: ago)
            await app.devices.refresh()
        }
    }

    // Settings › Devices
    func testDevicesNotLinked() async { await snap("encore://settings") }
    func testDevicesLinked() async { await snap("encore://settings", setup: linked(ago: 120)) }
    func testDevicesLinkedPendingAndError() async {
        await snap("encore://settings", setup: linked(pending: 12, error: "relay: timeout", ago: 600))
    }
    func testSideMenuLinked() async { await snap("encore://home", "encore://menu-side", setup: linked()) }

    // the linking sheet
    func testLinkIntro() async { await snap("encore://settings", "encore://link-device") }
    func testShowCode() async {
        await snap("encore://settings", "encore://link-device?step=show", setup: { app in
            try? await Task.sleep(for: .milliseconds(200))
            app.devices.nowOverride = (app.devices.shown?.expiresAt ?? 0) - 299
        }, tolerant: true)
    }
    func testShowCodeExpired() async { await snap("encore://settings", "encore://link-device?step=show&end=expired") }
    func testShowCodeTooManyTries() async { await snap("encore://settings", "encore://link-device?step=show&end=tries") }
    func testEnterCode() async { await snap("encore://settings", "encore://link-device?step=enter&code=482") }
    func testLinked() async {
        await snap("encore://settings", setup: { app in
            await self.linked()(app)
            app.router.handle(URL(string: "encore://link-device?step=success")!, app: app)
        })
    }

    // errors
    func testErrorWrongCode() async { await snap("encore://settings", "encore://link-device?step=enter&error=wrong_code:2") }
    func testErrorExpired() async { await snap("encore://settings", "encore://link-device?step=enter&error=not_pairing") }
    func testErrorCantSeeEachOther() async {
        await snap("encore://settings", "encore://link-device?step=enter&code=482913&error=no_host")
    }
    func testErrorLocalNetwork() async {
        await snap("encore://settings", "encore://link-device?step=enter&code=482913&error=local_network")
    }

    // first run and Home
    func testWelcome() async { await snap("encore://home", "encore://link-welcome") }
    func testHomeHint() async { await snap("encore://home?synchint=1", wait: 1.5) }
}
