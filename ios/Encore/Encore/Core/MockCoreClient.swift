// DEV ONLY: a Swift port of the desktop devmock (`ui/src/lib/devmock`). Answers `CoreClient` from
// the captured YouTube Music fixtures (real data, bundled from the desktop's fixtures folder) and
// simulates the player clock, so the shell runs today without the Rust core.
import Foundation

final class MockCoreClient: CoreClient, @unchecked Sendable {
    let lock = NSLock()
    weak var listener: CoreEventListener?
    var timer: DispatchSourceTimer?
    let bundle: Bundle

    // world
    var fx: [String: Data] = [:]
    var pool: [SongItem] = []
    var liked: [(song: SongItem, addedAt: Double)] = []
    var playlists: [(meta: LibPlaylist, items: [SongItem])] = []
    /// Deleted playlists, for Undo (MockCoreClient+E2E.swift).
    var mockTrash: [String: (meta: LibPlaylist, items: [SongItem])] = [:]
    var mockHidden: Set<String> = []
    var saved: [SavedItem] = []
    var savedCards: [String: BrowseItem] = [:]
    var recents: [RecentContext] = []
    var pins: [String] = [likedPlaylistId, "LOCALPLAYLIST:1"]

    // player
    var items: [SongItem] = []
    var current = -1
    var paused = true
    var position: Double = 0
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var sourceName: String?
    var sourceId: String?

    /// Podcasts, audio, smart2, downloads, folders, settings, import (MockCoreClient+Features.swift).
    var fs = MockFeatureState()
    /// Device sync (Core/DeviceSync.swift).
    var sync = MockSyncState()

    /// `latency` simulates the core's round trip (0 in tests and screenshots).
    var latency: UInt64 = 0
    let now = Date().timeIntervalSince1970

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        loadFixtures()
        pool = buildPool()
        seedLibrary()
        seedFeatures()
    }

    // MARK: fixtures

    func loadFixtures() {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "fixtures") ?? []
        for u in urls { fx[u.deletingPathExtension().lastPathComponent] = try? Data(contentsOf: u) }
    }

    func get<T: Decodable>(_ name: String, as: T.Type = T.self) -> T? {
        guard let d = fx[name] else { return nil }
        do { return try JSONDecoder().decode(T.self, from: d) } catch {
            print("[mock] fixture \(name) failed: \(error)")
            return nil
        }
    }

    func index(_ name: String) -> [String: String] { get(name) ?? [:] }

    func buildPool() -> [SongItem] {
        var seen = Set<String>()
        var out: [SongItem] = []
        func add(_ list: [SongItem]?) {
            for var s in list ?? [] where !seen.contains(s.videoId) && s.thumbnail != nil {
                seen.insert(s.videoId)
                s.queued = nil; s.queuedEnd = nil; s.autoplay = nil
                out.append(s)
            }
        }
        for a in ["discovery", "ram", "ok_computer"] { add(get("album_\(a)", as: AlbumPage.self)?.items) }
        for a in ["daft_punk", "radiohead"] { add(get("artist_\(a)", as: ArtistPage.self)?.topSongs) }
        add(get("search_songs_daft_punk", as: [SongItem].self))
        for p in ["search_daft_punk", "rock", "chart_top"] { add(get("playlist_\(p)", as: PlaylistPage.self)?.items) }
        return out
    }

    func poolSlice(_ start: Int, _ n: Int) -> [SongItem] {
        guard !pool.isEmpty else { return [] }
        return (0..<min(n, pool.count)).map { pool[(start + $0) % pool.count] }
    }

    func seedLibrary() {
        let day = 86_400.0
        liked = poolSlice(0, 40).enumerated().map { ($1, now - Double($0) * 2 * day - 3600) }
        let seeds: [(String, String, Int, Int)] = [
            ("Late Night Drive", "Neon, synths and empty highways.", 30, 60), ("Discovery Deep Cuts", "", 0, 14),
            ("Rock Classics", "The 90s, loud.", 60, 25), ("Focus Flow", "Instrumental-ish things to work to.", 20, 18),
            ("Gym", "", 45, 22), ("Sunday Morning", "Coffee first.", 12, 12), ("Road Trip 2026", "", 80, 33),
            ("Robot Rock", "Helmets on.", 5, 9),
        ]
        playlists = seeds.enumerated().map { i, s in
            let songs = poolSlice(s.2, s.3)
            let id = "LOCALPLAYLIST:\(i + 1)"
            return (LibPlaylist(id: id, name: s.0, description: s.1, thumbnail: songs.first?.thumbnail, count: songs.count,
                                pinned: pins.contains(id), updatedAt: now - Double(i * 3 + 1) * day,
                                lastPlayedAt: now - Double(i * 2 + 1) * 3600), songs)
        }
        func albumCard(_ slug: String) -> BrowseItem? {
            guard let a = get("album_\(slug)", as: AlbumPage.self),
                  let id = index("album_index").first(where: { $0.value == slug })?.key else { return nil }
            return BrowseItem(kind: .album, id: id, title: a.title ?? "", subtitle: a.artist, thumbnail: a.thumbnail)
        }
        func artistCard(_ slug: String) -> BrowseItem? {
            guard let a = get("artist_\(slug)", as: ArtistPage.self) else { return nil }
            return BrowseItem(kind: .artist, id: a.channelId, title: a.name ?? "", subtitle: "Artist", thumbnail: a.thumbnail)
        }
        func playlistCard(_ slug: String) -> BrowseItem? {
            guard let p = get("playlist_\(slug)", as: PlaylistPage.self),
                  let id = index("playlist_index").first(where: { $0.value == slug })?.key else { return nil }
            return BrowseItem(kind: .playlist, id: id, title: p.title ?? "", subtitle: p.subtitle ?? "Playlist", thumbnail: p.thumbnail)
        }
        let savedSeed: [(BrowseItem?, Double)] = [
            (albumCard("discovery"), 3), (albumCard("ram"), 12), (albumCard("ok_computer"), 20),
            (artistCard("daft_punk"), 5), (artistCard("radiohead"), 30), (playlistCard("rock"), 15), (playlistCard("chart_top"), 40),
        ]
        for (c, days) in savedSeed {
            guard let c, let kind = SavedKind(rawValue: c.kind.rawValue) else { continue }
            saved.append(SavedItem(id: c.id, kind: kind, title: c.title, subtitle: c.subtitle, thumbnail: c.thumbnail, addedAt: now - days * day))
            savedCards[c.id] = c
        }
        let pl = playlists
        let recentSeed: [(BrowseItem?, String, Double)] = [
            (albumCard("discovery"), "album", 600),
            (BrowseItem(kind: .playlist, id: pl[0].meta.id, title: pl[0].meta.name, subtitle: "Playlist • You", thumbnail: pl[0].meta.thumbnail), "playlist", 3600),
            (BrowseItem(kind: .playlist, id: likedPlaylistId, title: "Liked Songs", subtitle: "Playlist"), "liked", 5 * 3600),
            (artistCard("radiohead"), "artist", 9 * 3600), (playlistCard("rock"), "playlist", day),
            (albumCard("ram"), "album", 2 * day), (albumCard("ok_computer"), "album", 3 * day),
            (BrowseItem(kind: .playlist, id: pl[2].meta.id, title: pl[2].meta.name, subtitle: "Playlist • You", thumbnail: pl[2].meta.thumbnail), "playlist", 4 * day),
            (artistCard("daft_punk"), "artist", 5 * day), (playlistCard("chart_top"), "playlist", 6 * day),
        ]
        recents = recentSeed.compactMap { c, kind, ago in c.map { RecentContext(itemId: $0.id, kind: kind, card: $0, playedAt: now - ago) } }
    }

    func pause() async { if latency > 0 { try? await Task.sleep(nanoseconds: latency) } }
    func withLock<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }
    func isLiked(_ id: String) -> Bool { liked.contains { $0.song.videoId == id } }
    func withRating(_ s: SongItem) -> SongItem {
        var s = s
        s.rating = isLiked(s.videoId) ? .like : (s.rating ?? .indifferent)
        return s
    }

    // MARK: browse

    func search(query: String) async throws -> [SongItem] {
        await pause()
        return get("search_songs_daft_punk") ?? []
    }

    func slug(_ q: String) -> String {
        q.range(of: "radio|ok comp", options: [.regularExpression, .caseInsensitive]) != nil ? "radiohead" : "daft_punk"
    }

    func searchAll(query: String, recordHistory: Bool) async throws -> SearchResults {
        await pause()
        return get("search_all_\(slug(query))") ?? .empty
    }

    /// The Videos chip reads the captured music-video search; the other chips come from `searchAll`.
    func searchPage(query: String, filter: String, continuation: String?) async throws -> SearchPage {
        guard filter == "videos" else { return try await searchPageFromAll(query: query, filter: filter, continuation: continuation) }
        await pause()
        var page = SearchPage(filter: filter, query: query, songs: [], items: [], shows: [], episodes: [], continuation: nil)
        if continuation == nil { page.songs = get("search_videos_daft_punk") ?? [] }
        return page
    }

    func searchSuggestions(query: String) async throws -> SearchSuggestions {
        await pause()
        return get("search_suggestions_daft_p") ?? SearchSuggestions(queries: [], items: [])
    }

    func getHome(params: String?) async throws -> HomePage {
        await pause()
        return get(params == nil ? "home" : "home_chip") ?? HomePage(chips: [], sections: [])
    }

    func shelfItem(_ c: BrowseItem) -> ShelfItem {
        ShelfItem(kind: c.kind.rawValue, id: c.id, title: c.title, subtitle: c.subtitle, thumbnail: c.thumbnail,
                  explicit: c.explicit ?? false, song: c.kind == .song ? c.asSong : nil)
    }

    func smartHome() async throws -> [Shelf] {
        await pause()
        return withLock {
            var shelves: [Shelf] = []
            let cards = recents.compactMap(\.card)
            shelves.append(Shelf(id: "shortcuts", title: "Shortcuts", layout: .shortcuts, source: "local",
                                 items: cards.prefix(8).map { $0.id == likedPlaylistId
                                     ? ShelfItem(kind: "liked", id: likedPlaylistId, title: "Liked Songs", explicit: false) : shelfItem($0) }))
            shelves.append(Shelf(id: "recently_played", title: "Recently played", layout: .cards, source: "local", items: cards.map(shelfItem)))
            if fs.dlNetwork.offline { return offlineHomeLocked(shelves) }
            if mockLiveMixes { shelves.append(mockDailyMixShelfLocked()) }
            let home: HomePage? = get("home")
            for (i, s) in (home?.sections ?? []).enumerated() {
                shelves.append(Shelf(id: "yt:\(s.kind ?? String(i))", title: s.title,
                                     layout: s.items.allSatisfy { $0.kind == .song } ? .songs : .cards, source: "youtube",
                                     items: s.items.map(shelfItem)))
                if i == 1, let dp: ArtistPage = get("artist_daft_punk"),
                   let more = dp.sections.first(where: { $0.items.first?.kind == .artist }) {
                    shelves.append(Shelf(id: "more_like:\(dp.channelId)", title: "More like Daft Punk", layout: .cards,
                                         source: "youtube", items: more.items.map(shelfItem)))
                }
            }
            let albums = saved.filter { $0.kind == .album }.compactMap { savedCards[$0.id] }
            shelves.append(Shelf(id: "jump_back_in", title: "Jump back in", layout: .cards, source: "local", items: albums.map(shelfItem)))
            struct NR: Decodable { var sections: [HomeSection] }
            if let nr: NR = get("new_releases"), let s = nr.sections.first {
                shelves.append(Shelf(id: "new_releases", title: "New releases for you", layout: .cards, source: "youtube", items: s.items.map(shelfItem)))
            }
            return shelves
        }
    }

    func getMoods() async throws -> [MoodSection] {
        await pause()
        return get("moods") ?? []
    }

    func getMoodArt(params: [String]) async throws -> [String: String] {
        let all: [String: String] = get("mood_art") ?? [:]
        return all.filter { params.contains($0.key) }
    }

    func getAlbum(id: String) async throws -> AlbumPage {
        await pause()
        let slug = index("album_index")[id] ?? "discovery"
        guard var page: AlbumPage = get("album_\(slug)") else { throw MockError.missing(id) }
        return withLock {
            page.items = page.items.map(withRating)
            // Signed in, the page answers for the account (like the core); signed out, for this phone.
            page.inLibrary = mockSignedIn ? fs.yt.likedPlaylists.contains(page.playlistId ?? "") : saved.contains { $0.id == id }
            return page
        }
    }

    func getArtist(id: String) async throws -> ArtistPage {
        await pause()
        let slug = index("artist_index")[id] ?? "daft_punk"
        guard var page: ArtistPage = get("artist_\(slug)") else { throw MockError.missing(id) }
        return withLock {
            page.topSongs = page.topSongs.map(withRating)
            page.subscribed = mockSignedIn ? fs.yt.subscribed.contains(page.channelId) : saved.contains { $0.id == id }
            return page
        }
    }

    func getPlaylist(id: String) async throws -> PlaylistPage {
        await pause()
        return try withLock {
            if let mfy = mfyPageLocked(id) { return mfy }
            if let yt = ytPageLocked(id) { return yt }
            if id == likedPlaylistId {
                return PlaylistPage(title: "Liked Songs", subtitle: "\(liked.count) songs",
                                    items: liked.map { var s = $0.song; s.rating = .like; return s }, owned: false, collaborative: false)
            }
            if let p = playlists.first(where: { $0.meta.id == id }) {
                return PlaylistPage(title: p.meta.name, subtitle: "\(p.items.count) songs", thumbnail: p.items.first?.thumbnail,
                                    description: p.meta.description.isEmpty ? nil : p.meta.description,
                                    items: p.items.map(withRating), owned: true, collaborative: false)
            }
            let slug = index("playlist_index")[id] ?? "rock"
            guard var page: PlaylistPage = get("playlist_\(slug)") else { throw MockError.missing(id) }
            page.items = page.items.map(withRating)
            return page
        }
    }

    func getLyrics(videoId: String, title: String, artists: String, duration: Double?) async throws -> Lyrics? {
        await pause()
        return get("lyrics_one_more_time")
    }

    // MARK: library

    func librarySnapshot() async throws -> LibrarySnapshot {
        withLock {
            LibrarySnapshot(likedIds: liked.map(\.song.videoId), playlists: playlists.map(\.meta), saved: saved,
                            pinnedIds: pins, lastPlayed: Dictionary(recents.map { ($0.itemId, $0.playedAt) }, uniquingKeysWith: max),
                            lastTouched: fs.yt.touched,
                            folders: fs.folders, privateSession: fs.smart.privateSession, hiddenIds: Array(mockHidden))
        }
    }

    func recentContexts(limit: Int) async throws -> [RecentContext] { withLock { Array(recents.prefix(limit)) } }

    func setLiked(_ song: SongItem, liked on: Bool) async throws {
        if mockSignedIn { try? await rate(videoId: song.videoId, rating: on ? .like : .indifferent) }
        withLock {
            liked.removeAll { $0.song.videoId == song.videoId }
            if on { liked.insert((song, Date().timeIntervalSince1970), at: 0) }
            for i in items.indices where items[i].videoId == song.videoId { items[i].rating = on ? .like : .indifferent }
        }
        struct R: Encodable { var videoId: String; var rating: Rating }
        emit("rating", R(videoId: song.videoId, rating: on ? .like : .indifferent))
        emit("library-changed", ["scope": "liked"])
    }

    func setSaved(_ item: BrowseItem, saved on: Bool) async throws {
        withLock {
            saved.removeAll { $0.id == item.id }
            if on, let kind = SavedKind(rawValue: item.kind.rawValue) {
                saved.insert(SavedItem(id: item.id, kind: kind, title: item.title, subtitle: item.subtitle,
                                       thumbnail: item.thumbnail, addedAt: Date().timeIntervalSince1970), at: 0)
                savedCards[item.id] = item
            }
        }
        emit("library-changed", ["scope": "saved"])
    }

    func createPlaylist(name: String) async throws -> LibPlaylist {
        let p = withLock { () -> LibPlaylist in
            let p = LibPlaylist(id: "LOCALPLAYLIST:\(playlists.count + 1)", name: name, description: "", thumbnail: nil,
                                count: 0, pinned: false, updatedAt: Date().timeIntervalSince1970, lastPlayedAt: nil)
            playlists.insert((p, []), at: 0)
            return p
        }
        emit("library-changed", ["scope": "playlists"])
        return p
    }

    // MARK: playback

    var nowSong: SongItem? { items.indices.contains(current) ? items[current] : nil }
    var duration: Double { let d = nowSong?.seconds ?? 0; return d > 0 ? d : 240 }

    func queuePayload() -> QueueState {
        QueueState(items: items, currentIndex: current, shuffle: shuffle, repeat: repeatMode, sourceName: sourceName, sourceId: sourceId,
                   skipReasons: skipReasonsLocked())
    }

    func nowPayload() -> NowPlaying? {
        nowSong.map { NowPlaying(videoId: $0.videoId, title: $0.title, artists: $0.artists, artistId: $0.artistId,
                                 thumbnail: $0.thumbnail, duration: $0.duration, album: $0.album,
                                 rating: isLiked($0.videoId) ? .like : .indifferent,
                                 artistRuns: $0.artistRuns, explicit: $0.explicit, isEpisode: $0.isEpisode,
                                 showsLyrics: $0.isEpisode != true) } // as the core's `lyrics::offered`
    }

    func getQueue() async throws -> QueueState { withLock { queuePayload() } }
    func getPlayback() async throws -> PlaybackSnapshot {
        withLock { PlaybackSnapshot(now: nowPayload(), paused: paused, position: position, duration: duration) }
    }

    /// Start (or restart) the current track: the events the desktop emits on a track change.
    ///
    /// stream: instant. With `-mockResolveMs <n>` the core's order is played out: the track shows at
    /// once with `loading` (state.rs `show_loading`) and starts `n` ms later, as a stream resolve
    /// would; a newer start cancels a pending one. Without it everything lands at once, as before.
    func startCurrent(_ at: Double = 0) {
        let resolveMs = UserDefaults.standard.integer(forKey: "mockResolveMs")
        let (np, dur, gen) = withLock { () -> (NowPlaying?, Double, Int) in
            // Episodes resume 5 s before the saved position (podcasts.md rules).
            position = at == 0 ? resumePositionLocked() : at; paused = resolveMs > 0
            resolving = resolveMs > 0
            loadGen += 1
            return (nowPayload(), duration, loadGen)
        }
        guard resolveMs > 0 else {
            if let np { emit("now-playing", np) }
            emit("duration", ["duration": dur])
            emit("position", ["position": withLock { position }])
            emit("playback-state", "playing")
            startTicker()
            return
        }
        if var np { np.loading = true; emit("now-playing", np) }
        emit("duration", ["duration": dur])
        emit("position", ["position": withLock { position }])
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(resolveMs)) { [self] in
            let np = withLock { () -> NowPlaying?? in
                guard gen == loadGen else { return .none } // the last tap wins
                paused = false
                resolving = false
                return .some(nowPayload())
            }
            guard let np else { return }
            if let np { emit("now-playing", np) }
            emit("playback-state", "playing")
            startTicker()
        }
    }
    var loadGen = 0
    /// stream: pod-fixes. A start waiting for its stream: mpv refuses a seek before the file is
    /// loaded (state.rs `start_current`), so this mock drops it too. A start offset has to ride
    /// on the play call.
    var resolving = false

    func jump(_ i: Int) {
        let ok = withLock { () -> Bool in
            guard !items.isEmpty else { return false }
            current = max(0, min(i, items.count - 1))
            return true
        }
        guard ok else { return }
        emit("queue-changed", withLock { queuePayload() })
        startCurrent()
    }

    func advance(auto: Bool) {
        let (cur, count, rep) = withLock { (current, items.count, repeatMode) }
        if auto, sleepAtTrackEnd() { return }
        if auto && rep == .one { return startCurrent() }
        if cur + 1 < count { return jump(cur + 1) }
        if rep == .all { return jump(0) }
        // No music radio after an episode (podcasts.md).
        if withLock({ nowSong?.isEpisode == true }) { return }
        // Autoplay: append a few pool tracks, as radio continuation would.
        withLock { items += poolSlice(Int.random(in: 0..<max(pool.count, 1)), 5).map { var s = $0; s.autoplay = true; return s } }
        jump(cur + 1)
    }

    func playPlaylist(items list: [SongItem], start: Int, context: PlayContext, shuffle shuf: Bool, startSecs: Double?) async throws {
        withLock {
            var l = list
            var at = start
            // Podcast up next, as the core builds it (podcasts/upnext.rs, simplified): the episode
            // that was playing, the one picked, and the next one from its list, with its reason.
            if l.indices.contains(start), l[start].isEpisode == true {
                let prior = items.indices.contains(current) ? items[current] : nil
                var q: [SongItem] = []
                if let p = prior, p.isEpisode == true, p.videoId != l[start].videoId { q.append(p) }
                at = q.count
                q.append(l[start])
                if l.indices.contains(start + 1) {
                    var next = l[start + 1]
                    next.reason = "From \(next.artists)"
                    q.append(next)
                }
                l = q
            }
            if shuf && l.first?.isEpisode != true {
                let head = l.indices.contains(start) && start > 0 ? [l.remove(at: start)] : []
                l = head + l.shuffled()
                at = 0
            }
            items = l.map { var s = $0; s.queued = nil; s.queuedEnd = nil; return s }
            shuffle = shuf
            sourceName = context.title
            sourceId = context.kind == .dailyMix || context.kind == .audiobook ? nil : context.id // as RealCoreClient sends it
            current = min(at, max(0, items.count - 1))
            recents.removeAll { $0.itemId == context.id }
            if let id = context.id, context.kind != .search, context.kind != .song {
                let card = BrowseItem(kind: context.kind == .album ? .album : context.kind == .artist ? .artist : .playlist,
                                      id: id, title: context.title, thumbnail: list.first?.thumbnail)
                recents.insert(RecentContext(itemId: id, kind: context.kind.rawValue, card: card, playedAt: Date().timeIntervalSince1970), at: 0)
            }
        }
        emit("queue-changed", withLock { queuePayload() })
        startCurrent(startSecs ?? 0)
    }

    /// A single pick: the song, the user's own queue, then a few Autoplay rows (no context).
    func playSingle(_ song: SongItem, from: String?) async throws {
        withLock {
            let mine = items.dropFirst(current + 1).filter { $0.queued == true || $0.queuedEnd == true }
            let auto = poolSlice(Int.random(in: 0..<max(pool.count, 1)), 10)
                .filter { $0.videoId != song.videoId }
                .map { var s = $0; s.autoplay = true; s.queued = nil; s.queuedEnd = nil; return s }
            items = [song] + mine + (song.isEpisode == true ? [] : auto)
            shuffle = false
            sourceName = from
            sourceId = nil
            current = 0
        }
        emit("queue-changed", withLock { queuePayload() })
        startCurrent()
    }

    func playIndex(_ index: Int) async throws { jump(index) }

    func startRadio(song: SongItem) async throws {
        let list = [song] + poolSlice(Int.random(in: 0..<max(pool.count, 1)), 25)
        try await playPlaylist(items: list, start: 0, context: PlayContext(kind: .radio, id: nil, title: "\(song.title) Radio"), shuffle: false)
    }

    func nextTrack() async throws { advance(auto: false) }
    func prevTrack() async throws {
        let (pos, cur) = withLock { (position, current) }
        if pos > 3 { startCurrent() } else { jump(cur - 1) }
    }

    func togglePause() async throws {
        let p = withLock { paused.toggle(); return paused }
        emit("playback-state", p ? "paused" : "playing")
        if !p { startTicker() }
    }

    func seek(position to: Double) async throws {
        guard let p = withLock({ () -> Double? in
            guard !resolving else { return nil }
            position = max(0, min(to, duration)); return position
        }) else { return }
        emit("position", ["position": p])
    }

    func toggleShuffle() async throws {
        withLock { shuffle.toggle() }
        emit("queue-changed", withLock { queuePayload() })
    }

    func setRepeat(_ mode: RepeatMode) async throws {
        withLock { repeatMode = mode }
        emit("queue-changed", withLock { queuePayload() })
    }

    func addToQueue(_ list: [SongItem], from: String?) async throws {
        withLock {
            var at = current + 1
            while at < items.count, items[at].queued == true { at += 1 }
            items.insert(contentsOf: list.map { var s = $0; s.queued = true; s.queuedEnd = true; s.queuedFrom = from; return s }, at: min(at, items.count))
        }
        emit("queue-changed", withLock { queuePayload() })
    }

    func playNext(_ list: [SongItem], from: String?) async throws {
        withLock {
            var at = current + 1
            while at < items.count, items[at].queued == true, items[at].queuedEnd != true { at += 1 }
            items.insert(contentsOf: list.map { var s = $0; s.queued = true; s.queuedFrom = from; return s }, at: min(at, items.count))
        }
        emit("queue-changed", withLock { queuePayload() })
    }

    func removeFromQueue(index: Int) async throws {
        withLock { if items.indices.contains(index), index != current { items.remove(at: index); if index < current { current -= 1 } } }
        emit("queue-changed", withLock { queuePayload() })
    }

    func moveInQueue(from: Int, to: Int) async throws {
        withLock {
            guard items.indices.contains(from), from > current, to > current else { return }
            let row = items.remove(at: from)
            items.insert(row, at: min(to, items.count))
        }
        emit("queue-changed", withLock { queuePayload() })
    }

    // MARK: events

    func setListener(_ listener: CoreEventListener?) { withLock { self.listener = listener } }

    func emit<T: Encodable>(_ name: String, _ payload: T) {
        guard let l = withLock({ listener }), let data = try? JSONEncoder().encode(payload) else { return }
        l.onEvent(name: name, json: data)
    }

    func startTicker() {
        guard withLock({ timer == nil }) else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        withLock { timer = t }
        t.resume()
    }

    func tick() {
        let (p, end) = withLock { () -> (Double?, Bool) in
            guard !paused, nowSong != nil else { return (nil, false) }
            position += 0.25 * (nowSong?.isEpisode == true ? fs.speed : 1)
            return (position, position >= duration)
        }
        guard let p else { return }
        featureTick(position: p)
        if end { advance(auto: true) } else { emit("position", ["position": p]) }
    }

    enum MockError: Error { case missing(String) }
}
