// DEV ONLY: the feature-stream half of the mock, ported from the desktop devmock (`devmock/state.ts`
// podcasts, `devmock/smart2.ts`, `devmock/downloads.ts`) plus the audio, folders, settings and import
// commands. Same rules as the Rust side where they matter to the UI: episode resume/played rules,
// Smart Shuffle's suggestion after every 3 songs, the 3-at-a-time download queue.
import Foundation

struct MockFeatureState {
    // podcasts
    var showPage: PodcastShowPage?
    var searchResults: PodcastSearchResults = .empty
    var fullEpisode: PodcastEpisode?
    var follows: [PodcastShow] = []
    var savedEpisodes: Set<String> = []
    var progress: [String: EpisodeProgress] = [:]
    var lastProgressSave: Double = 0
    // playback / audio
    var speed: Double = 1
    var effects = PlaybackEffects()
    var eq = EqState(enabled: false, gains: [0, 0, 0, 0, 0, 0], preset: "Flat", preamp: 0)
    var normalize = true
    var level: VolumeLevel = .normal
    var crossfade = 0
    var sleep: SleepState = .off
    // smart
    var smart = SmartSettings(shuffleMode: "standard", explicitFilter: false, privateSession: false)
    var mfy: [(card: MfyCard, tracks: [SongItem])] = []
    var whatsNewSeenAt: Double = 0
    var smartShuffle: SmartShuffleState = .off
    // downloads
    var dlTracks: [String: (song: SongItem, state: Int, done: Double, total: Double)] = [:] // state 0 queued, 1 running, 2 done
    var dlCollections: [(c: DownloadCollection, addedAt: Double, members: [String])] = []
    var dlNetwork = DownloadNetwork(online: true, metered: false, offline: false, offlineMode: false, allowMetered: false, paused: false)
    var dlQuality = "HIGH"
    var dlTimer: DispatchSourceTimer?
    // library extras
    var folders: [Folder] = []
    // settings
    var settings: [String: String] = [:]
    // import
    var importSnap: ImportSnapshot?
    var importPreview: ImportPreview?
    var importRows: [ImportRow] = []
    // stream magic-ib, I-B2
    var enhance: [String: EnhanceState] = [:]
    var blocked: [BlockedArtist] = []
    var historyCleared = false
    // stream ios-sync2: the signed-in account's library (YouTubeLibraryClient.swift)
    var yt = MockYouTubeState()
}

/// Every Made for you card's cover is drawn natively (`MfyCoverArt`); the mock hands out this scheme.
func mfyCoverURL(_ title: String, _ n: Int) -> String {
    "mfy:\(title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title)#\(n)"
}

extension MockCoreClient {
    // MARK: seed

    func seedFeatures() {
        let day = 86_400.0
        fs.showPage = get("podcast_show_huberman")
        fs.searchResults = get("podcast_search_huberman") ?? .empty
        fs.fullEpisode = get("podcast_episode_huberman")
        var shows: [PodcastShow] = []
        if var s = fs.showPage?.show { s.followed = true; shows.append(s) }
        for var s in fs.searchResults.shows where shows.count < 4 {
            if !shows.contains(where: { $0.id == s.id }) && (s.title + s.author).range(of: "podcast", options: .caseInsensitive) != nil {
                s.followed = true; shows.append(s)
            }
        }
        fs.follows = shows
        let eps = fs.showPage?.episodes ?? []
        for (i, e) in eps.dropFirst().prefix(2).enumerated() {
            let dur = e.durationSecs ?? 3600
            let pos = (dur * (i == 0 ? 0.25 : 0.62)).rounded()
            fs.progress[e.id] = EpisodeProgress(positionSecs: pos, durationSecs: dur, fraction: pos / dur, played: false, updatedAt: now - Double(i + 1) * day)
        }
        if eps.count > 4 {
            let d = eps[4].durationSecs ?? 3600
            fs.progress[eps[4].id] = EpisodeProgress(positionSecs: d, durationSecs: d, fraction: 1, played: true, updatedAt: now - 6 * day)
        }
        for e in eps.prefix(2) { fs.savedEpisodes.insert(e.id) }

        // Made for you (smart2.ts build()).
        let related: [BrowseItem] = ["daft_punk", "radiohead"].compactMap { (get("artist_\($0)") as ArtistPage?)?.sections.first { $0.items.first?.kind == .artist }?.items }.flatMap { $0 }
        for i in 0..<6 {
            let x = related.indices.contains(i * 2) ? related[i * 2].title : "Daft Punk"
            let y = related.indices.contains(i * 2 + 1) ? related[i * 2 + 1].title : "Radiohead"
            let title = "Your Mix \(i + 1)"
            fs.mfy.append((MfyCard(id: "MFY_DAILY_\(i + 1)", kind: .daily, title: title, description: "\(x), \(y) and more",
                                   thumbnail: mfyCoverURL(title, i), trackCount: 50, generatedAt: now - 3600, nextRefresh: now + day),
                           poolSlice(i * 7, 50)))
        }
        let extra: [(String, MfyKind, String, String, Int, Int)] = [
            ("MFY_DISCOVER_WEEKLY", .discoverWeekly, "Weekly Discoveries", "Music new to you, picked from what you play. New every Monday.", 30, 6),
            ("MFY_RELEASE_RADAR", .releaseRadar, "New Release Mix", "The latest from artists you follow and play most. New every Friday.", 24, 7),
            ("LIMUSIC_ON_REPEAT", .onRepeat, "Your Rotation", "The songs you can't stop playing right now.", 25, 9),
            ("MFY_REPEAT_REWIND", .repeatRewind, "Throwback Mix", "Past favourites you haven't played in a while.", 30, 8),
        ]
        for (id, kind, title, desc, n, c) in extra {
            fs.mfy.append((MfyCard(id: id, kind: kind, title: title, description: desc, thumbnail: mfyCoverURL(title, c),
                                   trackCount: n, generatedAt: now - 3600, nextRefresh: now + 7 * day), poolSlice(c * 5, n)))
        }
        fs.whatsNewSeenAt = now - 2 * day
        fs.settings = [SettingKey.streamQuality: "auto", SettingKey.cellularQuality: "normal", SettingKey.dataSaver: "false",
                       SettingKey.gapless: "true", SettingKey.canvas: "true", SettingKey.youtubeAccount: "",
                       SettingKey.downloadCellular: "false"]
        // The onboarding flag outlives the mock (the real core persists every setting).
        if let done = UserDefaults.standard.string(forKey: "mock." + SettingKey.importDone) { fs.settings[SettingKey.importDone] = done }
        // Downloads: Late Night Drive starts out downloaded (devmock/downloads.ts).
        if let p = playlists.first {
            addDownloadLocked(DownloadCollection(id: p.meta.id, kind: "playlist", title: p.meta.name, thumbnail: p.meta.thumbnail), p.items, instant: true)
        }
        fs.folders = [Folder(id: "FOLDER:1", name: "Workout", parentId: nil, position: 0, createdAt: now - 20 * day, updatedAt: now - 2 * day,
                             items: ["LOCALPLAYLIST:5", "LOCALPLAYLIST:7"])]
        for i in playlists.indices where ["LOCALPLAYLIST:5", "LOCALPLAYLIST:7"].contains(playlists[i].meta.id) {
            playlists[i].meta.folderId = "FOLDER:1"
        }
    }

    // MARK: playback hooks (called from the main mock file)

    /// Resume point for the current row: 5 s before the saved position, none under 10 s or once played.
    func resumePositionLocked() -> Double {
        guard let s = nowSong, s.isEpisode == true, let p = fs.progress[s.videoId], p.positionSecs >= 10, !p.played else { return 0 }
        return max(0, p.positionSecs - 5)
    }

    func skipReasonsLocked() -> [String: String]? {
        var out: [String: String] = [:]
        if fs.smart.explicitFilter { for s in items where s.explicit == true { out[s.videoId] = "explicit" } }
        if fs.dlNetwork.offline {
            let done = Set(fs.dlTracks.filter { $0.value.state == 2 }.keys)
            for s in items where !done.contains(s.videoId) { out[s.videoId] = "offline" }
        }
        return out.isEmpty ? nil : out
    }

    /// Sleep "end of track": pause instead of advancing. Returns true when it fired.
    func sleepAtTrackEnd() -> Bool {
        let fire = withLock { () -> Bool in
            guard fs.sleep.mode?.kind == "endOfTrack" else { return false }
            fs.sleep = .off; paused = true; position = 0
            return true
        }
        if fire { emit("sleep-timer", SleepState.off); emit("playback-state", "paused") }
        return fire
    }

    func featureTick(position p: Double) {
        // Episode progress, saved every 5 s like the Rust tracker.
        let saved = withLock { () -> (String, EpisodeProgress)? in
            guard let s = nowSong, s.isEpisode == true, abs(p - fs.lastProgressSave) >= 5 else { return nil }
            fs.lastProgressSave = p
            let d = duration
            let played = d - p <= 30 || p / d >= 0.95
            let pr = EpisodeProgress(positionSecs: p, durationSecs: d, fraction: played ? 1 : p / d, played: played, updatedAt: Date().timeIntervalSince1970)
            fs.progress[s.videoId] = pr
            return (s.videoId, pr)
        }
        if let (id, pr) = saved {
            struct P: Encodable { var id: String; var progress: EpisodeProgress }
            emit("podcasts:progress", P(id: id, progress: pr))
        }
        // Timed sleep.
        let stop = withLock { () -> Bool in
            guard fs.sleep.mode?.kind == "at", let end = fs.sleep.mode?.endsAt, Date().timeIntervalSince1970 >= end else { return false }
            fs.sleep = .off; paused = true
            return true
        }
        if stop { emit("sleep-timer", SleepState.off); emit("playback-state", "paused") }
    }

    func setSpeed(_ rate: Double) async throws {
        let r = min(3, max(0.5, rate))
        withLock { fs.speed = r; fs.settings[SettingKey.speed] = String(r) }
        emit("playback-params", ["speed": r])
    }

    func setPlaybackParams(_ e: PlaybackEffects) async throws {
        var e = e
        e.speed = min(2, max(0.5, e.speed))
        withLock { fs.speed = e.speed; fs.effects = e }
        emit("playback-params", e)
    }

    func seekRelative(_ seconds: Double) async throws {
        let p = withLock { position = max(0, min(position + seconds, duration)); return position }
        emit("position", ["position": p])
    }

    // MARK: podcasts

    private func decorate(_ e: PodcastEpisode) -> PodcastEpisode {
        var e = e
        e.progress = fs.progress[e.id] ?? EpisodeProgress(positionSecs: 0, durationSecs: e.durationSecs ?? 0, fraction: 0, played: false, updatedAt: 0)
        e.saved = fs.savedEpisodes.contains(e.id)
        return e
    }

    func allEpisodesLocked() -> [PodcastEpisode] {
        var list = fs.showPage?.episodes ?? []
        for e in fs.searchResults.episodes where !list.contains(where: { $0.id == e.id }) { list.append(e) }
        if let f = fs.fullEpisode, !list.contains(where: { $0.id == f.id }) { list.append(f) }
        return list.map(decorate)
    }

    func podcastSearch(query: String) async throws -> PodcastSearchResults {
        await pause()
        return withLock {
            PodcastSearchResults(shows: fs.searchResults.shows.map { s in var s = s; s.followed = fs.follows.contains { $0.id == s.id }; return s },
                                 episodes: fs.searchResults.episodes.map(decorate))
        }
    }

    func podcastShow(id: String, sort: EpisodeSort) async throws -> PodcastShowPage {
        await pause()
        return try withLock {
            guard var p = fs.showPage else { throw MockError.missing(id) }
            if id != p.show.id, let other = fs.follows.first(where: { $0.id == id }) ?? fs.searchResults.shows.first(where: { $0.id == id }) {
                p.show = other // the fixture holds one show's episodes; other shows reuse them, retitled
                p.episodes = p.episodes.map { var e = $0; e.showTitle = other.title; e.showId = other.id; return e }
            }
            p.show.followed = fs.follows.contains { $0.id == p.show.id }
            p.episodes = p.episodes.map(decorate)
            if sort == .oldest { p.episodes.reverse() }
            p.sort = sort
            p.continuation = nil
            return p
        }
    }

    func podcastEpisode(id: String) async throws -> PodcastEpisode {
        await pause()
        return try withLock {
            guard var e = allEpisodesLocked().first(where: { $0.id == id }) ?? fs.fullEpisode.map(decorate) else { throw MockError.missing(id) }
            if e.description == nil || e.id == fs.fullEpisode?.id { e.description = fs.fullEpisode?.description ?? e.description }
            return e
        }
    }

    /// stream: video-pods. The core's rule (`podcasts::video`) over the fixtures: a YouTube episode
    /// shows itself, an RSS one only a video enclosure; none offline or on Data Saver.
    func podcastEpisodeVideo(id: String) async throws -> EpisodeVideo? {
        withLock {
            if fs.dlNetwork.offline || fs.settings[SettingKey.dataSaver] == "true" { return nil }
            let auto = fs.settings[SettingKey.podcastAudioOnly] != "true"
            if !id.hasPrefix("PODURL:") { return EpisodeVideo(videoId: id, url: nil, auto: auto) }
            let video = allEpisodesLocked().first { $0.id == id }?.isVideo == true
            return video ? EpisodeVideo(videoId: nil, url: String(id.dropFirst(7)), auto: auto) : nil
        }
    }

    /// stream: chapters. Five chapters for every episode (the devmock's set), spread over the
    /// fixture's own length so snapshots don't depend on when the player learnt the duration.
    func podcastChapters(id: String, durationSecs: Double?) async throws -> PodcastChapters {
        let known = withLock { allEpisodesLocked().first { $0.id == id }?.durationSecs ?? fs.fullEpisode?.durationSecs }
        let d = (known ?? 0) > 0 ? known! : 3600
        let at = [0, 0.08, 0.31, 0.55, 0.8].map { ($0 * d).rounded() }
        let titles = ["Introduction", "How sleep works", "Light in the morning", "Caffeine timing", "Listener questions"]
        // YouTube's automatic chapters (the fixture's episodes are YouTube videos); lengths in the
        // core's "2min" / "1hr 5min" wording.
        func length(_ s: Double) -> String {
            let m = max(1, Int((s / 60).rounded()))
            return m < 60 ? "\(m)min" : m % 60 == 0 ? "\(m / 60)hr" : "\(m / 60)hr \(m % 60)min"
        }
        return PodcastChapters(source: "youtube", chapters: at.indices.map { i in
            let end = i + 1 < at.count ? at[i + 1] : d
            return PodcastChapter(startSecs: at[i], endSecs: end, title: titles[i], startLabel: timecode(at[i]), durationLabel: length(end - at[i]))
        }, autoGenerated: true)
    }

    func podcastFollow(_ show: PodcastShow, follow: Bool) async throws {
        withLock {
            fs.follows.removeAll { $0.id == show.id }
            if follow { var s = show; s.followed = true; fs.follows.insert(s, at: 0) }
        }
        emit("library-changed", ["scope": "podcasts"])
    }

    func podcastFollows() async throws -> [PodcastShow] { withLock { fs.follows } }

    // stream: home-tiles-pods — the core's Podcasts chip (smart::podhome) from the podcast fixtures.
    func podcastHome() async throws -> [Shelf] {
        withLock {
            let eps = allEpisodesLocked()
            func ep(_ e: PodcastEpisode) -> ShelfItem {
                ShelfItem(kind: "episode", id: e.id, title: e.title, subtitle: e.showTitle, thumbnail: e.thumbnail, explicit: false,
                          song: e.song, params: e.showId)
            }
            func show(_ s: PodcastShow) -> ShelfItem {
                ShelfItem(kind: "podcast", id: s.id, title: s.title, subtitle: s.author, thumbnail: s.thumbnail, explicit: false)
            }
            let fresh = eps.filter { !$0.progress.played }
            let started = eps.filter { $0.progress.fraction > 0 && !$0.progress.played }
            var tiles: [ShelfItem] = started.map { var i = ep($0); i.progress = $0.progress.fraction; return i }
            for e in fresh where !tiles.contains(where: { $0.id == e.id }) { var i = ep(e); i.newEpisode = true; tiles.append(i) }
            let shows = fs.searchResults.shows.filter { s in !fs.follows.contains { $0.title == s.title } }
            let cats = [("1303", "Comedy", "#e13300"), ("1489", "News", "#1e3264"), ("1488", "True Crime", "#8c1932"),
                        ("1324", "Society & Culture", "#477d95"), ("1545", "Sports", "#27856a"), ("1321", "Business", "#503750")]
            let shelves = [
                Shelf(id: "shortcuts", title: "", layout: .shortcuts, source: "local", items: Array(tiles.prefix(8))),
                Shelf(id: "pod_new", title: "New episodes", layout: .cards, source: "local", items: fresh.prefix(12).map(ep)),
                Shelf(id: "pod_for_you", title: "Episodes for you", layout: .cards, source: "apple", items: fs.searchResults.episodes.prefix(12).map(ep)),
                Shelf(id: "pod_shows", title: "Your shows", layout: .cards, source: "local", items: fs.follows.map(show)),
                Shelf(id: "pod_like", title: "Shows you might like", layout: .cards, source: "apple", items: shows.prefix(10).map(show)),
                Shelf(id: "pod_because", title: "Because you listened to \(fs.follows.first?.title ?? "Huberman Lab")", layout: .cards,
                      source: "apple", items: shows.dropFirst(5).prefix(10).map(show)),
                Shelf(id: "pod_top", title: "Top podcasts", layout: .cards, source: "apple", items: shows.reversed().map(show)),
                Shelf(id: "pod_categories", title: "Podcast categories", layout: .moods, source: "apple",
                      items: cats.enumerated().map { i, c in
                          ShelfItem(kind: "podcast_category", id: "podcat:\(c.0)", title: c.1, thumbnail: shows.isEmpty ? nil : shows[i % shows.count].thumbnail,
                                    explicit: false, params: c.0, color: c.2)
                      }),
            ]
            return shelves.filter { !$0.items.isEmpty }
        }
    }
    func podcastCategory(genre: String) async throws -> [ShelfItem] {
        withLock { fs.searchResults.shows.map { ShelfItem(kind: "podcast", id: $0.id, title: $0.title, subtitle: $0.author, thumbnail: $0.thumbnail, explicit: false) } }
    }
    func podcastSavedEpisodes() async throws -> [PodcastEpisode] { withLock { allEpisodesLocked().filter(\.saved) } }
    func podcastNewEpisodes(limit: Int) async throws -> [PodcastEpisode] {
        withLock { Array(allEpisodesLocked().filter { !$0.progress.played }.prefix(limit)) }
    }
    func podcastContinueListening(limit: Int) async throws -> [PodcastEpisode] {
        withLock { Array(allEpisodesLocked().filter { $0.progress.fraction > 0 && !$0.progress.played }.prefix(limit)) }
    }

    func podcastSaveEpisode(_ episode: PodcastEpisode, saved on: Bool) async throws {
        withLock { if on { fs.savedEpisodes.insert(episode.id) } else { fs.savedEpisodes.remove(episode.id) } }
        emit("library-changed", ["scope": "episodes"])
    }

    func podcastMarkPlayed(id: String, played: Bool) async throws -> EpisodeProgress {
        let p = withLock { () -> EpisodeProgress in
            let d = allEpisodesLocked().first { $0.id == id }?.durationSecs ?? 0
            let p = EpisodeProgress(positionSecs: played ? d : 0, durationSecs: d, fraction: played ? 1 : 0, played: played, updatedAt: Date().timeIntervalSince1970)
            fs.progress[id] = p
            return p
        }
        struct P: Encodable { var id: String; var progress: EpisodeProgress }
        emit("podcasts:progress", P(id: id, progress: p))
        return p
    }

    // MARK: audio

    func audioSettings() async throws -> AudioSettings {
        withLock { AudioSettings(eq: fs.eq, normalize: fs.normalize, level: fs.level, crossfadeSecs: fs.crossfade, device: "auto", sleep: sleepNowLocked()) }
    }

    private func sleepNowLocked() -> SleepState {
        var s = fs.sleep
        if let end = s.mode?.endsAt { s.remaining = max(0, end - Date().timeIntervalSince1970) }
        return s
    }

    func eqInfo() async throws -> EqInfo {
        EqInfo(bands: EQ.bands.map { EqBandInfo(kind: $0.kind.rawValue, freq: $0.freq, q: $0.q) },
               presets: EQ.presets.map { EqPreset(name: $0.0, gains: $0.1) }, maxDb: EQ.maxDb)
    }

    func setEq(enabled: Bool, gains: [Double], commit: Bool) async throws -> EqState {
        withLock {
            let g = gains.map(EQ.clamp)
            fs.eq = EqState(enabled: enabled, gains: g, preset: EQ.presetName(g), preamp: EQ.autoPreamp(g))
            return fs.eq
        }
    }

    func setEqPreset(_ name: String) async throws -> EqState {
        let g = EQ.presets.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 ?? Array(repeating: 0, count: 6)
        return try await setEq(enabled: true, gains: g, commit: true)
    }

    func setCrossfade(seconds: Int) async throws -> Int { withLock { fs.crossfade = max(0, min(12, seconds)); return fs.crossfade } }
    func setNormalize(_ on: Bool) async throws { withLock { fs.normalize = on } }
    func setVolumeLevel(_ level: VolumeLevel) async throws { withLock { fs.level = level } }

    func setSleepTimer(minutes: Int?, endOfTrack: Bool) async throws -> SleepState {
        let s = withLock { () -> SleepState in
            if endOfTrack { fs.sleep = SleepState(mode: SleepMode(kind: "endOfTrack", endsAt: nil), remaining: nil, fadeSecs: 8) }
            else if let m = minutes {
                let end = Date().timeIntervalSince1970 + Double(m * 60)
                fs.sleep = SleepState(mode: SleepMode(kind: "at", endsAt: end), remaining: Double(m * 60), fadeSecs: 8)
            } else { fs.sleep = .off }
            return fs.sleep
        }
        emit("sleep-timer", s)
        return s
    }

    func cancelSleepTimer() async throws -> SleepState { try await setSleepTimer(minutes: nil, endOfTrack: false) }

    // MARK: smart

    func smartSettings() async throws -> SmartSettings { withLock { fs.smart } }

    func smartSetSetting(key: String, value: String) async throws {
        withLock {
            if key == "shuffle_mode" { fs.smart.shuffleMode = value }
            if key == "explicit_filter" { fs.smart.explicitFilter = value == "true" }
        }
        emit("queue-changed", withLock { queuePayload() })
    }

    /// `-mockLiveMixes 1`: before Made for you's first build, as the core is then: no stored mixes,
    /// and Home's "Made for you" shelf holds the live Your Mix tiles (`mockDailyMixShelf`).
    var mockLiveMixes: Bool { UserDefaults.standard.bool(forKey: "mockLiveMixes") }

    func madeForYou() async throws -> [MfyCard] { mockLiveMixes ? [] : withLock { fs.mfy.map(\.card) } }

    /// The core's live Your Mix tiles (home.rs: kind `daily_mix`, id `dailymix:<artist keys>`).
    func mockDailyMixShelfLocked() -> Shelf {
        let tiles = (0..<3).map { i -> ShelfItem in
            let songs = poolSlice(i * 7, 20)
            let artists = songs.map(\.artists).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3)
            return ShelfItem(kind: "daily_mix", id: "dailymix:mock\(i + 1)a,mock\(i + 1)b", title: "Your Mix \(i + 1)",
                             subtitle: artists.joined(separator: ", ") + " and more",
                             thumbnail: songs.first?.thumbnail, explicit: false)
        }
        return Shelf(id: "made_for_you", title: "Made for you", layout: .cards, source: "local", items: tiles)
    }

    func smartMix(id: String, size: Int?) async throws -> [SongItem] {
        await pause()
        guard id.hasPrefix("dailymix:") else { throw MockError.missing(id) }
        let n = Int(id.dropFirst("dailymix:mock".count).prefix(1)) ?? 1
        return withLock { poolSlice((n - 1) * 7, min(max(size ?? 50, 10), 100) / 2).map(withRating) }
    }

    func mfyPageLocked(_ id: String) -> PlaylistPage? {
        guard let m = fs.mfy.first(where: { $0.card.id == id }) else { return nil }
        return PlaylistPage(title: m.card.title, subtitle: "Made for you • \(m.tracks.count) songs", thumbnail: m.card.thumbnail,
                            description: m.card.description, cover: m.card.thumbnail, items: m.tracks.map(withRating), owned: false, collaborative: false)
    }

    func whatsNew() async throws -> WhatsNew {
        await pause()
        return withLock {
            struct NR: Decodable { var sections: [HomeSection] }
            let albums = ((get("new_releases") as NR?)?.sections ?? []).flatMap(\.items).filter { $0.kind == .album }
            let seen = fs.whatsNewSeenAt
            let music: [WhatsNewRelease] = albums.prefix(8).enumerated().map { i, al in
                let firstSeen = i < 3 ? now - Double(i) * 20_000 : i < 6 ? now - Double(i + 2) * 86_400 : 0
                let run = al.artistRuns?.first { $0.id != nil }
                let sub = al.subtitle ?? ""
                let type = sub.range(of: "single", options: .caseInsensitive) != nil ? "Single" : sub.contains("EP") ? "EP" : "Album"
                return WhatsNewRelease(id: al.id, title: al.title, subtitle: al.subtitle, thumbnail: al.thumbnail,
                                       artist: run?.text ?? sub.components(separatedBy: " • ").last ?? "", artistId: run?.id ?? "UCdaftpunk",
                                       year: 2026, firstSeen: firstSeen, followed: true, ytNew: i < 3, position: i, releaseType: type,
                                       isNew: firstSeen > seen)
            }
            let pods = allEpisodesLocked().prefix(6).map { WhatsNewEpisode(episode: $0, isNew: ($0.publishedAt ?? 0) > seen) }
            return WhatsNew(music: music, podcasts: Array(pods), seenAt: seen,
                            newCount: music.filter(\.isNew).count + pods.filter(\.isNew).count)
        }
    }

    func whatsNewMarkSeen() async throws {
        withLock { fs.whatsNewSeenAt = now + 1 }
        emit("whats-new-changed", ["newCount": 0])
    }

    func smartShuffleState() async throws -> SmartShuffleState { withLock { fs.smartShuffle } }

    /// On: shuffle + a suggestion after every 3 songs (own playlists / Liked Songs only).
    func smartShuffleSet(_ on: Bool) async throws -> SmartShuffleState {
        let s = try withLock { () -> SmartShuffleState in
            let recSet = Set(fs.smartShuffle.recIds)
            items = items.enumerated().filter { $0.offset <= current || !recSet.contains($0.element.videoId) }.map(\.element)
            if !on {
                shuffle = false
                fs.smartShuffle = .off
                return fs.smartShuffle
            }
            let src = sourceId ?? ""
            guard src.hasPrefix("LOCALPLAYLIST:") || src == likedPlaylistId else { throw MockError.missing("Smart Shuffle works in your own playlists") }
            shuffle = true
            let have = Set(items.map(\.videoId))
            var recs = ((get("search_songs_daft_punk") as [SongItem]?) ?? []).filter { !have.contains($0.videoId) }
            if recs.count < 10 { recs = poolSlice(7, 20).map { var s = $0; s.videoId += "~rec"; return s } }
            var ids: [String] = []
            var at = current + 1, run = 0, r = 0
            while at < items.count && r < recs.count {
                run += 1; at += 1
                if run == 3 { items.insert(recs[r], at: min(at, items.count)); ids.append(recs[r].videoId); at += 1; r += 1; run = 0 }
            }
            fs.smartShuffle = SmartShuffleState(on: true, sourceId: src, recIds: ids)
            return fs.smartShuffle
        }
        emit("queue-changed", withLock { queuePayload() })
        emit("smart-shuffle-changed", s)
        return s
    }

    // MARK: downloads

    private func listFor(_ c: DownloadCollection) -> [SongItem] {
        if c.id == likedPlaylistId { return liked.map(\.song) }
        if let p = playlists.first(where: { $0.meta.id == c.id }) { return p.items }
        if let m = fs.mfy.first(where: { $0.card.id == c.id }) { return m.tracks }
        if c.kind == "album", let slug = index("album_index")[c.id], let a: AlbumPage = get("album_\(slug)") { return a.items }
        if c.kind == "playlist", let slug = index("playlist_index")[c.id], let p: PlaylistPage = get("playlist_\(slug)") { return p.items }
        return []
    }

    func addDownloadLocked(_ c: DownloadCollection, _ songs: [SongItem], instant: Bool) {
        var seen = Set<String>()
        let ids = songs.map(\.videoId).filter { seen.insert($0).inserted }
        fs.dlCollections.removeAll { $0.c.id == c.id }
        fs.dlCollections.append((c, Date().timeIntervalSince1970, ids))
        for s in songs where fs.dlTracks[s.videoId] == nil {
            let total = 3_000_000 + Double((Int(s.videoId.unicodeScalars.first?.value ?? 7) * 7919) % 4_000_000)
            fs.dlTracks[s.videoId] = (s, instant ? 2 : 0, instant ? total : 0, total)
        }
    }

    private func statusLocked() -> [DownloadCollectionStatus] {
        fs.dlCollections.map { c in
            let ts = c.members.compactMap { fs.dlTracks[$0] }
            let done = ts.filter { $0.state == 2 }
            return DownloadCollectionStatus(id: c.c.id, kind: c.c.kind, title: c.c.title, subtitle: c.c.subtitle, thumbnail: c.c.thumbnail,
                                            total: ts.count, done: done.count, failed: 0, bytes: done.reduce(0) { $0 + $1.total }, addedAt: c.addedAt)
        }
    }

    private func snapshotLocked() -> DownloadsSnapshot {
        let all = Array(fs.dlTracks.values)
        let done = all.filter { $0.state == 2 }
        return DownloadsSnapshot(collections: statusLocked(), count: done.count, bytes: done.reduce(0) { $0 + $1.total },
                                 queued: all.count - done.count, failed: 0, done: done.map(\.song.videoId),
                                 active: all.filter { $0.state == 1 }.map { DownloadProgress(videoId: $0.song.videoId, done: $0.done, total: $0.total) },
                                 network: fs.dlNetwork, dir: "Application Support/Downloads", quality: fs.dlQuality)
    }

    func downloadsSnapshot() async throws -> DownloadsSnapshot { withLock { snapshotLocked() } }

    func downloadsAdd(_ collection: DownloadCollection, songs: [SongItem]?) async throws {
        let list = songs ?? listFor(collection)
        withLock {
            addDownloadLocked(collection, list, instant: false)
            // The core's rule: a downloaded episode is saved to Your Episodes.
            if collection.kind == "episode" { fs.savedEpisodes.insert(collection.id) }
        }
        emit("downloads:changed", ["changed": true])
        startDownloadTicker()
    }

    private func pruneLocked() {
        let held = Set(fs.dlCollections.flatMap(\.members))
        for id in fs.dlTracks.keys where !held.contains(id) { fs.dlTracks[id] = nil }
    }

    func downloadsRemove(id: String) async throws {
        withLock { fs.dlCollections.removeAll { $0.c.id == id }; pruneLocked() }
        emit("downloads:changed", ["changed": true])
    }

    func downloadsRemoveAll() async throws {
        withLock { fs.dlCollections = []; fs.dlTracks = [:] }
        emit("downloads:changed", ["changed": true])
    }

    func downloadsSetSettings(_ patch: DownloadSettingsPatch) async throws -> DownloadsSnapshot {
        let s = withLock { () -> DownloadsSnapshot in
            if let o = patch.offlineMode { fs.dlNetwork.offlineMode = o }
            if let m = patch.allowMetered { fs.dlNetwork.allowMetered = m; fs.settings[SettingKey.downloadCellular] = String(m) }
            if let q = patch.quality { fs.dlQuality = q }
            fs.dlNetwork.offline = fs.dlNetwork.offlineMode || !fs.dlNetwork.online
            fs.dlNetwork.paused = fs.dlNetwork.offline || (fs.dlNetwork.metered && !fs.dlNetwork.allowMetered)
            return snapshotLocked()
        }
        emit("downloads:network", s.network)
        emit("queue-changed", withLock { queuePayload() })
        return s
    }

    /// The fake queue: 3 tracks at a time, ~1 MB/s each (devmock/downloads.ts).
    private func startDownloadTicker() {
        guard withLock({ fs.dlTimer == nil }) else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 0.33, repeating: 0.33)
        t.setEventHandler { [weak self] in self?.downloadTick() }
        withLock { fs.dlTimer = t }
        t.resume()
    }

    private func downloadTick() {
        let (live, finished, idle) = withLock { () -> ([DownloadProgress], Int, Bool) in
            if fs.dlNetwork.paused { return ([], 0, false) }
            var running = fs.dlTracks.filter { $0.value.state == 1 }.map(\.key)
            for id in fs.dlTracks.filter({ $0.value.state == 0 }).map(\.key).sorted().prefix(max(0, 3 - running.count)) {
                fs.dlTracks[id]?.state = 1; running.append(id)
            }
            var finished = 0
            for id in running {
                guard var t = fs.dlTracks[id] else { continue }
                t.done = min(t.total, t.done + 330_000)
                if t.done >= t.total { t.state = 2; finished += 1 }
                fs.dlTracks[id] = t
            }
            let live = fs.dlTracks.values.filter { $0.state == 1 }.map { DownloadProgress(videoId: $0.song.videoId, done: $0.done, total: $0.total) }
            return (live, finished, running.isEmpty)
        }
        if !live.isEmpty || finished > 0 { emit("downloads:progress", live) }
        if finished > 0 { emit("downloads:changed", ["changed": true]) }
        if idle { withLock { fs.dlTimer?.cancel(); fs.dlTimer = nil } }
    }

    // MARK: library extras

    func setPinned(id: String, kind: String, pinned on: Bool) async throws {
        withLock {
            pins.removeAll { $0 == id }
            if on { pins.insert(id, at: 0) }
            for i in playlists.indices where playlists[i].meta.id == id { playlists[i].meta.pinned = on }
        }
        emit("library-changed", ["scope": "pins"])
    }

    func createFolder(name: String) async throws -> Folder {
        let f = withLock { () -> Folder in
            let t = Date().timeIntervalSince1970
            let f = Folder(id: "FOLDER:\(fs.folders.count + 1)", name: name, parentId: nil, position: fs.folders.count, createdAt: t, updatedAt: t, items: [])
            fs.folders.insert(f, at: 0)
            return f
        }
        emit("library-changed", ["scope": "folders"])
        return f
    }

    func setPrivateSession(_ on: Bool) async throws {
        withLock { fs.smart.privateSession = on }
        emit("library-changed", ["scope": "private"])
    }

    // MARK: settings

    func getSettings() async throws -> [String: String] { withLock { fs.settings } }
    func setSetting(key: String, value: String) async throws {
        withLock { fs.settings[key] = value }
        if key == SettingKey.importDone { UserDefaults.standard.set(value, forKey: "mock." + key) }
    }

    // MARK: import (canned answers in the shapes import2.md documents)

    func importRead(link: String) async throws -> ImportPreview {
        await pause()
        let l = link.lowercased()
        guard l.contains("spotify.com") || l.hasPrefix("spotify:") else { throw MockError.missing("not a Spotify link") }
        let p = withLock { () -> ImportPreview in
            let covers = poolSlice(3, 10).map(\.thumbnail)
            let names = ["Running 2026", "Chill Evenings", "Throwbacks", "Indie Finds", "Dinner Jazz", "Focus", "Summer '25", "Car Singalongs", "Rainy Days", "Party Starters"]
            if l.contains("/user/") {
                let profile = SpotifyProfile(id: "you", name: "Alex", avatar: nil,
                                             playlists: names.enumerated().map { SpotifyProfile.P(id: "sp\($0.offset)", name: $0.element, cover: covers[$0.offset]) }, total: 23)
                return ImportPreview(lists: names.enumerated().map { ImportListPreview(kind: "playlist", name: $0.element, owner: "Alex", cover: covers[$0.offset], count: 0, skipped: 0, truncated: false, lazy: true) },
                                     profile: profile)
            }
            return ImportPreview(lists: [ImportListPreview(kind: "playlist", name: "Indie Finds", owner: "Alex", cover: covers[0], count: 42, skipped: 1, truncated: false)])
        }
        withLock { fs.importPreview = p }
        return p
    }

    func importReadFile(url: URL) async throws -> ImportPreview {
        await pause()
        let p = withLock { () -> ImportPreview in
            let covers = poolSlice(11, 6).map(\.thumbnail)
            let lists = [ImportListPreview(kind: "liked", name: "Liked Songs", count: 812, skipped: 0, truncated: false)]
                + ["Running 2026", "Chill Evenings", "Throwbacks", "Indie Finds", "Dinner Jazz"].enumerated().map {
                    ImportListPreview(kind: "playlist", name: $0.element, owner: "Alex", cover: covers[$0.offset], count: 20 + $0.offset * 9, skipped: 0, truncated: false)
                }
            return ImportPreview(lists: lists, albums: 64, artists: 31,
                                 history: url.pathExtension.lowercased() == "csv" ? nil : ImportHistorySummary(plays: 18_402, songs: 3_211, from: now - 365 * 86_400, to: now - 86_400))
        }
        withLock { fs.importPreview = p }
        return p
    }

    func importStart(lists: [Int]) async throws -> ImportSnapshot {
        let snap = withLock { () -> ImportSnapshot in
            let picked = lists.compactMap { fs.importPreview?.lists.indices.contains($0) == true ? fs.importPreview!.lists[$0] : nil }
            let total = max(1, picked.reduce(0) { $0 + max($1.count, 25) })
            fs.importSnap = ImportSnapshot(phase: "matching", total: total, done: 0, matched: 0, check: 0, missing: 0,
                                           lists: picked.map { .init(kind: $0.kind, name: $0.name, count: $0.count, cover: $0.cover) },
                                           recent: [], step: [0, picked.count], message: nil, results: [])
            return fs.importSnap!
        }
        // Simulated matching: ~3 s to done.
        Task.detached { [weak self] in
            guard let self else { return }
            for i in 1...12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let s = self.withLock { () -> ImportSnapshot? in
                    guard var s = self.fs.importSnap else { return nil }
                    s.done = s.total * i / 12
                    s.matched = Int(Double(s.done) * 0.94); s.check = Int(Double(s.done) * 0.04); s.missing = s.done - s.matched - s.check
                    let song = self.poolSlice(i * 3, 1).first
                    if let song { s.recent.insert(.init(title: song.title, artists: song.artists, tier: "matched", thumbnail: song.thumbnail), at: 0) }
                    s.recent = Array(s.recent.prefix(4))
                    // Matched: the review step waits for `importCreate` (stream ios-import-review).
                    if i == 12 { s = self.mockReview(s) }
                    self.fs.importSnap = s
                    return s
                }
                if let s { self.emit("import-progress", s) }
            }
        }
        return snap
    }

    func importStatus() async throws -> ImportSnapshot? { withLock { fs.importSnap } }
}

// MARK: entity pages (stream magic-ib)

extension MockCoreClient {
    /// Ten songs from the pool that aren't in the playlist; each Refresh moves to the next ten
    /// (the core's seed voting moves to the next seeds the same way).
    func playlistRecommendations(playlistId: String, n: Int, refresh: Int) async throws -> [Recommendation] {
        await pause()
        return withLock {
            let inList = Set((playlists.first { $0.meta.id == playlistId }?.items ?? []).map(\.videoId))
            let candidates = pool.filter { !inList.contains($0.videoId) }
            guard !candidates.isEmpty else { return [] }
            let start = (refresh * n + 7) % candidates.count
            // Like the core: an empty playlist is seeded from your listening.
            let basis = inList.isEmpty ? "listening" : "playlist"
            return (0..<min(n, candidates.count)).map { i in
                let s = candidates[(start + i) % candidates.count]
                return Recommendation(song: withRating(s), votes: 3 - i % 3, because: [], basis: basis)
            }
        }
    }

    func getPlaylist(id: String, sort: String?, desc: Bool) async throws -> PlaylistPage {
        var page = try await getPlaylist(id: id)
        if sort == "newest" { page.items.reverse() }
        return page
    }

    /// Like the core: a playlist on this phone has no YouTube order to write.
    func setPlaylistSort(playlistId: String, sort: String) async throws {
        if playlistId.hasPrefix("LOCALPLAYLIST:") || playlistId == likedPlaylistId { throw MockError.missing(playlistId) }
        withLock { fs.settings["ytsort.\(playlistId)"] = sort }
    }

    func artistDiscography(id: String) async throws -> Discography {
        Discography.of(try await getArtist(id: id))
    }

    func smartHomeLocal() async throws -> [Shelf] { try await smartHome().filter { $0.source == "local" } }

    /// 50 pool songs starting from the seed (the core's radio + finishing pass, in miniature).
    func radioTracks(kind: String, id: String, name: String?) async throws -> RadioPage {
        await pause()
        return withLock {
            let start = pool.firstIndex { $0.videoId == id } ?? abs(id.hashValue) % max(pool.count, 1)
            let items = poolSlice(start, 50)
            let artists = Array(NSOrderedSet(array: items.map(\.artists)).array.prefix(3)) as? [String] ?? []
            return RadioPage(title: "\(name ?? items.first?.title ?? "Song") Radio", playlistId: "RDAMVM\(id)",
                             seed: kind == "song" ? items.first : nil, thumbnail: items.first?.thumbnail,
                             description: artists.isEmpty ? nil : "With " + artists.joined(separator: ", "), items: items)
        }
    }
    func playSingleAt(_ song: SongItem, from: String?, start: Double?) async throws {
        try await playPlaylist(items: [song], start: 0, context: PlayContext(kind: .song, id: nil, title: from ?? song.title), shuffle: false,
                               startSecs: start)
    }
    func songCredits(_ song: SongItem) async throws -> SongCredits {
        let names = song.artists.components(separatedBy: ", ")
        let first = names.first ?? song.artists
        // `people` is what the core derives from the sections (`credits::credit_people`).
        return SongCredits(sections: [
            .init(title: "Performed by", people: names.map { .init(name: $0, artistId: song.artistId) }),
            .init(title: "Written by", people: [.init(name: first, artistId: nil)]),
        ], source: "Mock Records",
           people: names.enumerated().map { i, n in .init(name: n, artistId: song.artistId, roles: i == 0 ? ["Main Artist", "Writer"] : ["Main Artist"]) })
    }
    func tasteSetExcluded(id: String, kind: String, title: String?, videoIds: [String], excluded: Bool) async throws {
        withLock {
            var ids = Set((fs.settings["taste_excluded"] ?? "").split(separator: ",").map(String.init))
            if excluded { ids.insert(id) } else { ids.remove(id) }
            fs.settings["taste_excluded"] = ids.sorted().joined(separator: ",")
        }
    }
    func tasteExcluded() async throws -> [String] {
        withLock { (fs.settings["taste_excluded"] ?? "").split(separator: ",").map(String.init) }
    }

    func playableFlags(_ items: [SongItem]) async throws -> [String: Bool] {
        withLock {
            Dictionary(items.map { s in (s.videoId, !(mockHidden.contains(s.videoId) || (fs.smart.explicitFilter && s.explicit == true))) },
                       uniquingKeysWith: { a, _ in a })
        }
    }
}

// MARK: SYNC-GAPS bridge (stream magic-ib, I-B2)

extension MockCoreClient {
    /// The mock's genre/mood for an artist (the core looks tags up on MusicBrainz / Last.fm).
    static func mockTags(_ artists: String) -> [(String, SmartChip.Kind)] {
        let a = artists.lowercased()
        if a.contains("daft punk") { return [("Electronic", .genre), ("Dance", .genre), ("Energetic", .mood)] }
        if a.contains("radiohead") { return [("Alternative", .genre), ("Rock", .genre), ("Melancholic", .mood)] }
        if a.contains("pearl jam") || a.contains("blink") || a.contains("kravitz") || a.contains("nirvana") { return [("Rock", .genre), ("Energetic", .mood)] }
        return [("Pop", .genre), ("Chill", .mood)]
    }

    func restoreQueued(_ rows: [SongItem]) async throws -> Int {
        withLock {
            let at = min(items.count, current + 1)
            items.insert(contentsOf: rows.map { var s = $0; s.queued = true; return s }, at: at)
        }
        emit("queue-changed", withLock { queuePayload() })
        return rows.count
    }

    /// Chips with at least 5 liked tracks, most tracks first (the core's rule), at most 8.
    func smartTagsLiked() async throws -> LikedChips {
        withLock { () -> LikedChips in
            var kinds: [String: SmartChip.Kind] = [:]
            var ids: [String: [String]] = [:]
            for l in liked {
                for (t, k) in Self.mockTags(l.song.artists) { kinds[t] = k; ids[t, default: []].append(l.song.videoId) }
            }
            var chips: [SmartChip] = []
            for (label, v) in ids where v.count >= 5 { chips.append(SmartChip(label: label, kind: kinds[label] ?? .genre, videoIds: v)) }
            chips.sort { (a: SmartChip, b: SmartChip) -> Bool in
                a.videoIds.count == b.videoIds.count ? a.label < b.label : a.videoIds.count > b.videoIds.count
            }
            return LikedChips(chips: Array(chips.prefix(8)), done: liked.count, total: liked.count)
        }
    }

    func enhanceState(playlistId: String) async throws -> EnhanceState {
        withLock { fs.enhance[playlistId] ?? EnhanceState(playlistId: playlistId, on: false, recs: [], at: 0) }
    }
    /// One suggestion per two songs (the core's ratio), from songs not in the playlist.
    func enhanceSet(playlistId: String, on: Bool, len: Int) async throws -> EnhanceState {
        let e = withLock { () -> EnhanceState in
            let have = Set((playlists.first { $0.meta.id == playlistId }?.items ?? []).map(\.videoId))
            let recs = on ? Array(pool.filter { !have.contains($0.videoId) }.prefix(max(1, len / 2))) : []
            let e = EnhanceState(playlistId: playlistId, on: on, recs: recs, at: Int64(Date().timeIntervalSince1970))
            fs.enhance[playlistId] = e
            return e
        }
        emit("enhance-changed", e)
        return e
    }
    func enhanceRemove(playlistId: String, videoId: String) async throws -> EnhanceState { enhanceDrop(playlistId, videoId) }
    func enhanceKeep(playlistId: String, videoId: String) async throws -> EnhanceState { enhanceDrop(playlistId, videoId) }
    private func enhanceDrop(_ playlistId: String, _ videoId: String) -> EnhanceState {
        let e = withLock { () -> EnhanceState in
            var e = fs.enhance[playlistId] ?? EnhanceState(playlistId: playlistId, on: false, recs: [], at: 0)
            e.recs.removeAll { $0.videoId == videoId }
            fs.enhance[playlistId] = e
            return e
        }
        emit("enhance-changed", e)
        return e
    }

    func deletedPlaylists() async throws -> [DeletedPlaylist] {
        withLock {
            let t = Int64(now)
            return mockTrash.values.map { p in
                DeletedPlaylist(id: p.meta.id, name: p.meta.name, count: p.items.count, thumbnail: p.meta.thumbnail,
                                deletedAt: t, purgeAt: t + 30 * 86_400)
            }.sorted { $0.name < $1.name }
        }
    }

    func recentTracks(limit: Int?) async throws -> [RecentTrack] {
        withLock {
            guard !fs.historyCleared else { return [] }
            // Anchored to today's local noon, not "now", so the Today / Yesterday grouping (and its
            // snapshot) doesn't depend on the time of day the tests run.
            let noon = Int64(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970) + 12 * 3_600
            return liked.prefix(limit ?? 50).enumerated().map { i, l in
                RecentTrack(song: l.song, playedAt: noon - Int64(i) * 60, plays: 1 + i % 4) // minutes apart from noon: one "Today" group at any hour
            }
        }
    }

    func listeningStats(since: Int64) async throws -> ListeningStats {
        let recent = try await recentTracks(limit: 50)
        let artists = try await topArtists(limit: 8)
        guard !recent.isEmpty else {
            return ListeningStats(secs: 0, prevSecs: nil, plays: 0, songs: 0, newSongs: 0, artists: 0, days: [],
                                  hours: Array(repeating: 0, count: 168), topSongs: [], topArtists: [], topAlbums: [], firstAt: nil, streak: 0)
        }
        // A deterministic history counted back from today (90 days of it): a steady pattern, so
        // the charts have something to draw and the snapshots stay stable.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: now))
        let first = cal.date(byAdding: .day, value: -89, to: today)!
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        var days: [CorePair<String, Int>] = []
        for back in stride(from: 89, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            guard Int64(d.timeIntervalSince1970) >= since - 86_400 else { continue }
            let secs = back % 9 == 4 ? 0 : 900 + (back * 37 % 11) * 420
            if secs > 0 { days.append(CorePair(fmt.string(from: d), secs)) }
        }
        let secs = days.reduce(0) { $0 + $1.second }
        let hours = (0..<168).map { i -> Int in
            let (d, h) = (i / 24, i % 24)
            let base = h >= 18 && h <= 23 ? 900 : h >= 7 && h <= 9 ? 500 : h >= 12 && h <= 16 ? 300 : h < 2 ? 200 : 0
            return base + (d == 5 ? base / 2 : 0)
        }
        var albums: [String: ListeningStats.TopAlbum] = [:]
        for r in recent {
            guard let id = r.song.albumId, let title = r.song.album else { continue }
            albums[id, default: .init(id: id, title: title, artist: r.song.artists, thumbnail: r.song.thumbnail, plays: 0, secs: 0)].plays += r.plays
            albums[id]?.secs += r.plays * Int(r.song.seconds)
        }
        let plays = recent.reduce(0) { $0 + $1.plays } * 4
        // The followed shows, as the core tallies episodes into shows.
        let pods = withLock { fs.follows }.prefix(3).enumerated().map { i, s in
            ListeningStats.TopPodcast(id: s.id, name: s.title, thumbnail: s.thumbnail, plays: 6 - i * 2, secs: 14_400 - i * 4_800)
        }
        let podSecs = pods.reduce(0) { $0 + $1.secs }
        return ListeningStats(secs: secs, podcastSecs: podSecs, episodes: pods.reduce(0) { $0 + $1.plays }, prevSecs: since > 0 ? secs * 4 / 5 : nil,
                              plays: plays, songs: recent.count, newSongs: recent.count / 3,
                              artists: Set(recent.map(\.song.artists)).count, days: days, hours: hours,
                              topSongs: recent.sorted { $0.plays > $1.plays }.prefix(10).map { .init(song: $0.song, plays: $0.plays * 4, secs: Int($0.song.seconds) * $0.plays * 4) },
                              topArtists: artists, topAlbums: albums.values.sorted { $0.secs == $1.secs ? $0.id < $1.id : $0.secs > $1.secs }.prefix(6).map { $0 },
                              topPodcasts: Array(pods), firstAt: Int64(first.timeIntervalSince1970), streak: 3, bestStreak: 12)
    }

    func topArtists(limit: Int) async throws -> [TopArtist] {
        let recent = try await recentTracks(limit: 50)
        var plays: [String: Int] = [:]
        for r in recent { plays[r.song.artists, default: 0] += r.plays }
        return plays.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
            .map { TopArtist(name: $0.key, id: nil, thumbnail: nil, plays: $0.value, secs: $0.value * 200) }
    }

    func clearListeningHistory() async throws { withLock { fs.historyCleared = true } }

    func blockedArtists() async throws -> [BlockedArtist] { withLock { fs.blocked } }
    func blockArtist(id: String?, name: String) async throws -> [BlockedArtist] {
        withLock {
            let b = BlockedArtist(id: id, name: name.trimmingCharacters(in: .whitespaces))
            if !fs.blocked.contains(where: { $0.key == b.key }) { fs.blocked.append(b) }
            return fs.blocked
        }
    }
    func unblockArtist(key: String) async throws -> [BlockedArtist] {
        withLock { fs.blocked.removeAll { $0.key == key }; return fs.blocked }
    }

    func renameFolder(id: String, name: String) async throws {
        withLock { for i in fs.folders.indices where fs.folders[i].id == id { fs.folders[i].name = name } }
        emit("library-changed", ["scope": "folders"])
    }
    func deleteFolder(id: String) async throws -> FolderSnapshot {
        let snap = try withLock { () -> FolderSnapshot in
            guard let i = fs.folders.firstIndex(where: { $0.id == id }) else { throw MockError.missing(id) }
            let f = fs.folders.remove(at: i)
            let members = playlists.indices.filter { playlists[$0].meta.folderId == id }
            for j in members { playlists[j].meta.folderId = nil }
            return FolderSnapshot(folder: f, childFolders: [],
                                  items: members.enumerated().map { CorePair(playlists[$0.element].meta.id, $0.offset) })
        }
        emit("library-changed", ["scope": "folders"])
        return snap
    }
    func restoreFolder(_ snapshot: FolderSnapshot) async throws -> Folder {
        withLock {
            fs.folders.append(snapshot.folder)
            let ids = Set(snapshot.items.map(\.first))
            for j in playlists.indices where ids.contains(playlists[j].meta.id) { playlists[j].meta.folderId = snapshot.folder.id }
        }
        emit("library-changed", ["scope": "folders"])
        return snapshot.folder
    }

    func setPlaylistCover(playlistId: String, path: String?) async throws -> PlaylistCoverResult {
        let thumb = withLock { () -> String? in
            guard let i = playlists.firstIndex(where: { $0.meta.id == playlistId }) else { return nil }
            playlists[i].meta.thumbnail = path.map { URL(fileURLWithPath: $0).absoluteString } ?? playlists[i].items.first?.thumbnail
            return playlists[i].items.first?.thumbnail
        }
        emit("library-changed", ["scope": "playlists"])
        return PlaylistCoverResult(cover: path.map { URL(fileURLWithPath: $0).absoluteString }, thumbnail: thumb)
    }

    /// The fixtures are one page each: there is never a next one.
    func playlistMore(token: String) async throws -> PlaylistMore { PlaylistMore(items: [], continuation: nil) }
    func playlistContinuation(id: String) async throws -> String? { nil }
}
