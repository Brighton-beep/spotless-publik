// Downloads: downloaded playlist (accent toggle + row arrows), a download in flight (ring, row
// rings; state injected so the frame is deterministic), offline greying.
import XCTest
@testable import Encore

final class DownloadSnapshotTests: SnapshotCase {
    func testPlaylistDownloaded() async { await snap("encore://playlist/LOCALPLAYLIST:1") }

    func testDownloading() async {
        await snap("encore://liked", setup: { app in
            let liked = (try? await app.core.getPlaylist(id: likedPlaylistId).items) ?? []
            app.downloads.snapshot.collections.append(DownloadCollectionStatus(
                id: likedPlaylistId, kind: "liked", title: "Liked Songs", total: liked.count, done: 12, failed: 0, bytes: 0, addedAt: 0))
            app.downloads.done.formUnion(liked.prefix(2).map(\.videoId))
            for s in liked.dropFirst(2).prefix(2) { app.downloads.active[s.videoId] = DownloadProgress(videoId: s.videoId, done: 1, total: 3) }
        })
    }

    func testOfflineGreyed() async {
        await snap("encore://offline?on=1", "encore://playlist/LOCALPLAYLIST:2")
    }

    func testAlbumRemoveDownloadSheet() async {
        await snap("encore://playlist/LOCALPLAYLIST:1", setup: { app in
            app.sheet = .collection(BrowseItem(kind: .playlist, id: "LOCALPLAYLIST:1", title: "Late Night Drive", subtitle: "Playlist • Alex"))
        })
    }
}
