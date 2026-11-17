// Stream ios-parity: the screens compared against the Spotify iOS spec (entity pages, Now Playing's
// details, the queue sheet, sheets, toasts, focused search, empty and error states).
import XCTest
@testable import Encore

final class ParitySnapshotTests: SnapshotCase {
    private let play = "encore://play/LOCALPLAYLIST:1?index=1&pause=1"
    func testArtist() async { await snap(play, "encore://artist/UCRr1xG_2WIDs18a6cIiCxeA") }
    func testEditorialPlaylist() async { await snap(play, "encore://playlist/VLPLhwykgk4XwFlhenPwRXKx3pcOmCYfNe0Q") }
    func testQueueSheet() async { await snap(play, "encore://queue", wait: 1.2) }
    func testLyricsFull() async { await snap(play, "encore://lyrics", wait: 1.2) }
    func testTrackSheet() async { await snap(play, "encore://playlist/LOCALPLAYLIST:1", "encore://menu", wait: 1.2) }
    func testToast() async { await snap(play, "encore://toast") }
    func testFocusedSearchResults() async { await snap("encore://search?q=daft%20punk", wait: 1.5) }
    func testLibraryNoMatches() async { await snap("encore://library?q=zzzz") }
}
