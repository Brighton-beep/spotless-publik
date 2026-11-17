// The Spotify import onboarding, step by step (stream ios-screens2, fork D; redesigned by stream onboard).
import XCTest
@testable import Encore

final class ImportSnapshotTests: SnapshotCase {
    private let link = "https://open.spotify.com/user/alex"

    override func setUp() async throws {
        try await super.setUp()
        ImportFlow.shared.reset()
    }

    func testWelcome() async { await snap("encore://import") }

    func testLinkStep() async {
        await snap("encore://import?step=link", setup: { _ in ImportFlow.shared.link = self.link })
        XCTAssertEqual(ImportFlow.shared.step, .link)
        XCTAssertEqual(ImportFlow.shared.back, .welcome)
    }

    /// "Show me how": the four-step sheet on copying your profile link in Spotify.
    func testLinkGuide() async {
        await snap("encore://import?step=link", setup: { _ in ImportFlow.shared.guide = true })
    }

    func testLinkError() async {
        await snap("encore://import?step=link", setup: { app in
            let f = ImportFlow.shared
            f.link = "not a link"
            f.error = "That link didn't work. In Spotify, use Share › Copy link."
        })
    }

    /// The data-file guide: three numbered steps and Choose file.
    func testExportStep() async {
        await snap("encore://import?step=export")
        XCTAssertEqual(ImportFlow.shared.step, .export)
    }

    func testProfilePreview() async {
        await snap("encore://import", setup: { app in
            let f = ImportFlow.shared
            f.link = self.link
            await f.read(app)
        })
        XCTAssertEqual(ImportFlow.shared.step, .preview)
        XCTAssertEqual(ImportFlow.shared.picked.count, 10)
    }

    func testExportPreview() async {
        await snap("encore://import", setup: { app in
            await ImportFlow.shared.readFile(URL(fileURLWithPath: "/tmp/my_spotify_data.zip"), app)
        })
        XCTAssertNotNil(ImportFlow.shared.preview?.history)
    }

    func testProgress() async {
        await snap("encore://import", setup: { app in
            let f = ImportFlow.shared
            f.link = self.link
            f.live = false // freeze a mid-import state (and skip step animations)
            await f.read(app)
            await f.start(app)
            f.snapshot?.done = 120; f.snapshot?.matched = 112; f.snapshot?.check = 5; f.snapshot?.missing = 3
            f.snapshot?.recent = [.init(title: "One More Time", artists: "Daft Punk", tier: "matched", thumbnail: nil),
                                  .init(title: "Karma Police", artists: "Radiohead", tier: "check", thumbnail: nil)]
        }, wait: 0.2)
    }

    func testDone() async {
        await snap("encore://import", setup: { app in
            let f = ImportFlow.shared
            f.link = self.link
            await f.read(app)
            f.live = false
            await f.start(app)
            guard var snap = f.snapshot else { return XCTFail("no import snapshot") }
            snap.phase = "done"
            snap.results = snap.lists.map {
                ImportResult(kind: $0.kind, name: $0.name, id: "LOCALPLAYLIST:1", local: true, added: 25, missing: 1, removed: 0)
            }
            f.snapshot = snap
            f.step = .done
        })
    }

    func testNotNowMarksDone() async {
        app.router.handle(URL(string: "encore://import")!, app: app)
        XCTAssertTrue(app.importOpen)
        app.importOfferAnswered()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let offer = await app.shouldOfferImport()
        XCTAssertFalse(offer)
    }
}
