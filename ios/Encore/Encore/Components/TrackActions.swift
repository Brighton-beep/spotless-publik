// Lane P1 (SYNC-GAPS §2): the track and queue actions the desktop has and the phone was missing,
// as the menus call them. Each one confirms with a toast and offers Undo, as on the desktop
// (`kit/taste.svelte.ts`, `restoreorder.ts`, `QueuePanel.svelte`, `player.svelte.ts blockArtist`).
// The pure parts (`PlaylistUndo.order`, `QueueUndo.queuedRows`) are unit-tested in SyncActionsTests.
import SwiftUI
import Observation

// MARK: taste profile

/// Ids excluded from the taste profile (`taste_excluded`), for the menus' label. Loaded on first
/// ask (the sheet re-reads it when it lands), then kept in step by `toggle`.
@MainActor @Observable
final class TasteExclusions {
    static let shared = TasteExclusions()
    private(set) var excluded: Set<String> = []
    private(set) var loaded = false
    @ObservationIgnored private var loading: Task<Void, Never>?

    func isExcluded(_ id: String, core: CoreClient) -> Bool {
        if !loaded && loading == nil {
            loading = Task {
                if let ids = try? await core.tasteExcluded() { excluded = Set(ids) }
                loaded = true
                loading = nil
            }
        }
        return excluded.contains(id)
    }

    /// Tests: forget what was loaded (each test has its own mock core).
    func reset() { excluded = []; loaded = false; loading?.cancel(); loading = nil }

    /// Exclude a song or playlist (`kind`: song | playlist), or include it again, with an Undo toast.
    /// `tracks` lists a playlist's songs (the core snapshots them; a song is its own track).
    func toggle(_ app: AppModel, id: String, kind: String, title: String?, tracks: @escaping () async -> [String] = { [] }) {
        let on = !excluded.contains(id)
        let set: (Bool) async throws -> Void = { [weak self] excluded in
            let ids = excluded ? await tracks() : []
            try await app.core.tasteSetExcluded(id: id, kind: kind, title: title, videoIds: ids, excluded: excluded)
            if excluded { self?.excluded.insert(id) } else { self?.excluded.remove(id) }
        }
        Task {
            do {
                try await set(on)
                app.showToast(on ? "Excluded from your taste profile" : "Included in your taste profile", action: "Undo") {
                    Task {
                        do { try await set(!on) } catch { app.showToast("Couldn't update your taste profile") }
                    }
                }
            } catch {
                app.showToast("Couldn't update your taste profile")
            }
        }
    }
}

// MARK: remove from playlist, with Undo

enum PlaylistUndo {
    /// The row order that puts re-added songs back where they were. `current` is the playlist's
    /// rows after the re-add (the re-added rows are its last `restoredAt.count` rows, in the order
    /// they were added); `restoredAt` holds each removed row's old index, ascending.
    static func order(current: [Int64], restoredAt: [Int]) -> [Int64] {
        let n = min(restoredAt.count, current.count)
        guard n > 0 else { return current }
        var rows = Array(current.dropLast(n))
        let back = current.suffix(n)
        for (at, row) in zip(restoredAt.sorted(), back) { rows.insert(row, at: min(max(0, at), rows.count)) }
        return rows
    }

    /// "Remove from this playlist" on an own playlist: the song leaves, and Undo puts every removed
    /// copy back at its old position (the desktop's `restoreorder.ts`).
    @MainActor static func remove(_ app: AppModel, song: SongItem, playlistId: String, playlistName: String?) {
        guard isLocalPlaylistId(playlistId) else { return removeFromAccount(app, song: song, playlistId: playlistId, playlistName: playlistName) }
        Task {
            do {
                let before = try await app.core.playlistEntries(id: playlistId)
                let at = before.enumerated().filter { $0.element.song.videoId == song.videoId }.map(\.offset)
                try await app.core.removeFromPlaylist(id: playlistId, videoIds: [song.videoId])
                await app.library.refresh()
                app.showToast("Removed from \(playlistName ?? "playlist")", action: "Undo") {
                    Task { await restore(app, song: song, playlistId: playlistId, at: at.isEmpty ? [Int.max] : at) }
                }
            } catch {
                app.showToast("Couldn't remove it")
            }
        }
    }

    /// The same on a playlist of yours on YouTube: Undo adds it again and moves it back in front
    /// of the row that followed it (rows there are `setVideoId`s).
    @MainActor static func removeFromAccount(_ app: AppModel, song: SongItem, playlistId: String, playlistName: String?) {
        guard let yt = app.core as? YouTubeLibraryClient else { return }
        Task {
            do {
                let page = try await app.core.getPlaylist(id: playlistId)
                let at = page.items.firstIndex { $0.videoId == song.videoId }
                let next = at.flatMap { page.items.indices.contains($0 + 1) ? page.items[$0 + 1].setVideoId : nil }
                try await yt.removeFromYouTubePlaylist(playlistId, videoIds: [song.videoId], page: page)
                app.account.youtube.noteRemoved(playlistId, videoIds: [song.videoId])
                app.showToast("Removed from \(playlistName ?? "playlist")", action: "Undo") {
                    Task {
                        do {
                            try await yt.addToYouTubePlaylist(playlistId, songs: [song])
                            app.account.youtube.noteAdded(playlistId, videoIds: [song.videoId])
                            if let next, let row = try await app.core.getPlaylist(id: playlistId).items.last(where: { $0.videoId == song.videoId })?.setVideoId {
                                try await yt.moveInPlaylist(playlistId: playlistId, setVideoId: row, before: next)
                            }
                        } catch { app.showToast("Couldn't put it back") }
                    }
                }
            } catch {
                app.showToast("Couldn't remove it")
            }
        }
    }

    @MainActor static func restore(_ app: AppModel, song: SongItem, playlistId: String, at: [Int]) async {
        do {
            try await app.core.addToPlaylist(id: playlistId, songs: Array(repeating: song, count: at.count))
            let now = try await app.core.playlistEntries(id: playlistId)
            let want = order(current: now.map(\.rowId), restoredAt: at)
            if want != now.map(\.rowId) { try await app.core.setPlaylistOrder(id: playlistId, rowIds: want) }
            await app.library.refresh()
        } catch {
            app.showToast("Couldn't put it back")
        }
    }
}

// MARK: clear queue, with Undo

enum QueueUndo {
    /// The rows "Clear queue" drops: the songs you queued after the current one.
    static func queuedRows(_ q: QueueState) -> [SongItem] {
        q.items.enumerated().filter { $0.offset > q.currentIndex && $0.element.isQueued }.map(\.element)
    }

    /// Spotify's "Clear queue" (keeps the context), then "Queue cleared · Undo" (`restore_queued`).
    @MainActor static func clear(_ app: AppModel) {
        let rows = queuedRows(app.player.queue)
        Haptics.impact(.light)
        Task {
            do {
                try await app.core.clearQueued()
                guard !rows.isEmpty else { return }
                app.showToast("Queue cleared", action: "Undo") {
                    Task {
                        do { _ = try await app.core.restoreQueued(rows); await app.player.refresh() }
                        catch { app.showToast("Couldn't restore your queue") }
                    }
                }
            } catch {
                app.showToast("Couldn't clear the queue")
            }
        }
    }
}

// MARK: don't play this artist

enum ArtistBlock {
    /// The artist a song's "Don't play this artist" means: the byline's first run, id and text
    /// together (pairing run 1's text with `artistId` would block the wrong channel), else the song's.
    static func artist(of s: SongItem) -> (id: String?, name: String)? {
        if let first = s.artistRuns?.first, !first.text.trimmingCharacters(in: .whitespaces).isEmpty {
            return (first.id, first.text)
        }
        let name = s.artists.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (s.artistId, name)
    }

    /// Block an artist: the core drops their upcoming songs and skips off one that is playing.
    @MainActor static func block(_ app: AppModel, id: String?, name: String) {
        Task {
            do {
                let list = try await app.core.blockArtist(id: id, name: name)
                await app.player.refresh()
                let key = list.first { $0.name == name || ($0.id != nil && $0.id == id) }?.key ?? id ?? name
                app.showToast("You won't hear \(name)", action: "Undo") {
                    Task {
                        do { _ = try await app.core.unblockArtist(key: key); await app.player.refresh() }
                        catch { app.showToast("Couldn't unblock this artist") }
                    }
                }
            } catch {
                app.showToast("Couldn't block this artist")
            }
        }
    }
}
