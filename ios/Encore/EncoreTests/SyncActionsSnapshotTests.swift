// Lane P1 screens: the radio page, the track sheet with its new rows, the credits sheet, and the
// Now Playing credits card (shown on its own until its one-line hook lands in NowPlaying.swift).
import XCTest
import SwiftUI
@testable import Encore

final class SyncActionsSnapshotTests: SnapshotCase {
    override func setUp() async throws {
        try await super.setUp()
        TasteExclusions.shared.reset()
        CreditsCache.shared.reset()
    }

    private func firstSong(_ app: AppModel) async -> SongItem? {
        try? await app.core.getPlaylist(id: "LOCALPLAYLIST:1").items.first
    }

    func testRadioPage() async {
        await snap("encore://play/LOCALPLAYLIST:1?index=1&pause=1", "encore://home", setup: { app in
            guard let s = await self.firstSong(app) else { return }
            app.router.push(.radio("song", s.videoId, s.title))
        }, wait: 2)
    }

    func testTrackSheetRows() async {
        await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1", "encore://home", "encore://menu", setup: { _ in
            try? await Task.sleep(for: .milliseconds(400))
            // The sheet's own detent is medium: show it all, as dragging it up would.
            if let sv = self.window.rootViewController?.presentedViewController?.sheetPresentationController {
                sv.animateChanges { sv.selectedDetentIdentifier = .large }
            }
        }, wait: 1.5)
    }

    func testCreditsSheet() async {
        await snap("encore://home", setup: { app in
            guard let s = await self.firstSong(app) else { return }
            CreditsPresenter.present(s, app: app, afterSheet: false)
        }, wait: 1.5)
    }

    func testCreditsCard() async {
        await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1", setup: { app in
            try? await Task.sleep(for: .milliseconds(400))
            let card = VStack { Spacer(); CreditsCard(); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.base)
                .environment(app)
                .preferredColorScheme(.dark)
            self.window.rootViewController = UIHostingController(rootView: card)
        }, wait: 1.5)
    }
}
