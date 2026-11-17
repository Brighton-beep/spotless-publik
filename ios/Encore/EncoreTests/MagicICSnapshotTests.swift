// Lane magic-ic screens: Home's Music chip (every chip stays, Music filled), a shelf's "Show all" grid, Home and
// Library offline, and the playing Library row with its equaliser.
import XCTest
@testable import Encore

final class MagicICSnapshotTests: SnapshotCase {
    func testHomeMusicChip() async { await snap("encore://home?chip=music") }

    func testShelfShowAll() async {
        await snap("encore://home", setup: { app in
            try? await Task.sleep(for: .milliseconds(600))
            guard let s = app.home.shelves.first(where: { $0.layout == .cards && $0.items.count >= 3 }) else { return }
            // Same as tapping the shelf title.
            app.router.push(.shelf(s.id, s.title))
        }, wait: 1.5)
    }

    func testHomeOffline() async {
        await snap("encore://download/LOCALPLAYLIST:1", "encore://home", "encore://offline?on=1", wait: 1.5)
    }

    func testLibraryOfflineOpensOnDownloaded() async {
        await snap("encore://download/LOCALPLAYLIST:1", "encore://library", "encore://offline?on=1", wait: 1.5)
    }

    func testLibraryPlayingRow() async {
        await snap("encore://play/LOCALPLAYLIST:1?index=0&pause=1", "encore://library", wait: 1.5)
    }
}
