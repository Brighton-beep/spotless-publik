// Screen snapshots (pointfree swift-snapshot-testing): the whole app (RootView on the mock core)
// in a window on the test host's scene, driven to a screen by `encore://` deep links, with
// deterministic stub artwork. Run on the iPhone 17 Pro simulator; references live in
// `__Snapshots__/`. Record by deleting a reference (record mode `.missing`).
import XCTest
import SwiftUI
import SnapshotTesting
@testable import Encore

@MainActor
class SnapshotCase: XCTestCase {
    var app: AppModel!
    var window: UIWindow!

    override func setUp() async throws {
        try await super.setUp()
        ArtworkCache.stubbed = true
        UIView.setAnimationsEnabled(false)
        app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        await app.start()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: RootView().environment(app))
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        app = nil
        UIView.setAnimationsEnabled(true)
        try await super.tearDown()
    }

    /// Opens each link in order (like the `-deeplink` launch argument), waits, then snapshots the window.
    func snap(_ links: String..., setup: ((AppModel) async -> Void)? = nil, wait: Double = 1.0,
              tolerant: Bool = false,
              named name: String? = nil, file: StaticString = #filePath, testName: String = #function, line: UInt = #line) async {
        for l in links { if let u = URL(string: l) { app.router.handle(u, app: app) }; try? await Task.sleep(for: .milliseconds(450)) }
        if let setup { await setup(app) }
        try? await Task.sleep(for: .seconds(wait))
        // Render the window ourselves (the UIView strategy re-hosts the view, which breaks a window).
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: fmt).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        withSnapshotTesting(record: .missing) {
            assertSnapshot(of: image, as: tolerant ? .image(precision: 0.9, perceptualPrecision: 0.9)  // screens whose backdrop animates
                                       : .image(precision: 0.985, perceptualPrecision: 0.97),
                           named: name, file: file, testName: testName, line: line)
        }
    }
}
