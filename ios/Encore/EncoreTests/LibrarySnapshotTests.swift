// Your Library: search, chips (second level), folders, podcasts, sort sheet, grid, Create sheet,
// naming screen.
import XCTest
@testable import Encore

final class LibrarySnapshotTests: SnapshotCase {
    func testSearch() async { await snap("encore://library?q=ro") }
    func testPlaylistsByYouAndSortSheet() async { await snap("encore://library?filter=Playlists&sub=By%20you", "encore://sort", tolerant: true) }
    func testPodcastsFilter() async { await snap("encore://library?filter=Podcasts") }
    func testDownloadedFilter() async { await snap("encore://library?filter=Downloaded") }
    func testGrid() async { await snap("encore://library?grid=1") }
    func testFolder() async { await snap("encore://folder/FOLDER:1") }
    func testCreateSheet() async { await snap("encore://library", "encore://create") }
    func testNameFolderSheet() async { await snap("encore://library", "encore://new-folder") }
    func testPinned() async {
        await snap("encore://library", setup: { app in
            app.library.setPinned(BrowseItem(kind: .album, id: app.library.snapshot.saved.first { $0.kind == .album }!.id, title: "Discovery"), true)
        })
    }
}
