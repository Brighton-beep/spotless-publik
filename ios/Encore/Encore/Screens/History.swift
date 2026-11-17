// Stream ios-p2: Recents (Spotify iOS: profile menu › Recents) and your listening stats.
// "Recently played" is the local listening history (`lib_recent_tracks`), newest first under day
// headers; "Your top" is the last four weeks (`listening_stats`): time listened, plays, top artists
// and top songs (Spotify's profile "Top artists / tracks this month"). Desktop: `/history` and
// `/stats` (iOS: StatsView, linked from "Your top"). Nothing here leaves the phone; Settings ›
// Privacy clears it.
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    enum Tab: String, CaseIterable { case recents = "Recently played", top = "Your top" }
    @State var tab: Tab = .recents
    @State private var rows: [RecentTrack]?
    @State private var stats: ListeningStats?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack { BackButton(); Spacer() }
                    .padding(.horizontal, Space.s + 2).frame(height: 44)
                Text("Recents").font(Typo.pageTitle).padding(.horizontal, Space.gutter).padding(.top, Space.s)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Space.s) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Chip(title: t.rawValue, selected: tab == t) { withAnimation(Motion.quick) { tab = t } }
                            .accessibilityIdentifier("history-chip-\(t == .recents ? "recents" : "top")")
                    }
                }
                .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
                switch tab {
                case .recents: recents
                case .top: top
                }
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.base)
        .foregroundStyle(Palette.text)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: app.homeSerial) { Task { await load() } }
    }

    private static let context = PlayContext(kind: .song, id: nil, title: "Recents")

    // MARK: recently played

    @ViewBuilder private var recents: some View {
        if let rows {
            if rows.isEmpty {
                empty("Songs you play show up here.")
            } else {
                let songs = rows.map(\.song)
                ForEach(Self.days(rows), id: \.title) { day in
                    Text(day.title).font(Typo.font(16, .bold))
                        .padding(.horizontal, Space.gutter).padding(.top, Space.l).padding(.bottom, Space.xs)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.indices, id: \.self) { i in
                        TrackRow(song: songs[i], context: Self.context) { app.player.play(songs, at: i, context: Self.context) }
                    }
                }
            }
        } else {
            EntityLoadState(failed: failed) { Task { await load() } }
        }
    }

    /// Rows grouped under "Today", "Yesterday", then the date (indices into `rows`, in order).
    static func days(_ rows: [RecentTrack], now: Date = .now, calendar: Calendar = .current) -> [(title: String, indices: [Int])] {
        var out: [(title: String, indices: [Int])] = []
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.setLocalizedDateFormatFromTemplate("EEEMMMd")
        for (i, r) in rows.enumerated() {
            let d = Date(timeIntervalSince1970: TimeInterval(r.playedAt))
            let title: String
            if calendar.isDate(d, inSameDayAs: now) { title = "Today" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { title = "Yesterday" }
            else { title = fmt.string(from: d) }
            if out.last?.title == title { out[out.count - 1].indices.append(i) } else { out.append((title, [i])) }
        }
        return out
    }

    // MARK: your top

    @ViewBuilder private var top: some View {
        if let stats {
            if stats.plays == 0 {
                empty("Listen for a while and your top artists and songs show up here.")
            } else {
                Text("Last 4 weeks").font(Typo.font(13)).foregroundStyle(Palette.subdued).padding(.horizontal, Space.gutter)
                statsLink
                HStack(spacing: Space.s) {
                    tile(Self.minutes(stats.secs), "minutes listened")
                    tile("\(stats.plays)", stats.plays == 1 ? "play" : "plays")
                    tile("\(stats.artists)", stats.artists == 1 ? "artist" : "artists")
                }
                .padding(.horizontal, Space.gutter).padding(.top, Space.s)
                if !stats.topArtists.isEmpty {
                    header("Top artists")
                    ForEach(Array(stats.topArtists.prefix(10).enumerated()), id: \.offset) { i, a in artistRow(i + 1, a) }
                }
                if !stats.topSongs.isEmpty {
                    header("Top songs")
                    let songs = stats.topSongs.prefix(10).map(\.song)
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                        TrackRow(song: s, index: i + 1, context: Self.context) { app.player.play(Array(songs), at: i, context: Self.context) }
                    }
                }
            }
        } else {
            EntityLoadState(failed: failed) { Task { await load() } }
        }
    }

    /// The full stats page: other ranges, top albums and when you listen.
    private var statsLink: some View {
        Button { app.router.push(.stats) } label: {
            HStack(spacing: Space.m) {
                Icon(name: "chart-bar", size: 22).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening stats").font(Typo.font(15, .bold))
                    Text("Top tracks and albums, any range, and when you listen").font(Typo.font(12)).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: 0)
                Icon(name: "caret-right", size: 16).foregroundStyle(Palette.subdued)
            }
            .padding(Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Palette.highlight))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .padding(.horizontal, Space.gutter).padding(.top, Space.s)
        .accessibilityIdentifier("history-stats-link")
    }

    /// "1,234" minutes (rounded down, at least 1 once anything played).
    static func minutes(_ secs: Int) -> String {
        let m = secs > 0 ? max(1, secs / 60) : 0
        return m.formatted(.number)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Typo.font(22, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Typo.font(12)).foregroundStyle(Palette.subdued).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Palette.highlight))
        .accessibilityElement(children: .combine)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(Typo.font(20, .bold))
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.s)
            .accessibilityAddTraits(.isHeader)
    }

    private func artistRow(_ rank: Int, _ a: TopArtist) -> some View {
        Button {
            if let id = a.id { app.router.push(.artist(id)) }
        } label: {
            HStack(spacing: Space.m) {
                Text("\(rank)").font(Typo.font(16)).foregroundStyle(Palette.subdued).frame(width: 24)
                if let t = a.thumbnail { ArtImage(url: t, px: 144, circle: true).frame(width: 48, height: 48) }
                else { AccountPhoto(url: nil, name: a.name, size: 48) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.name).font(Typo.rowTitle).lineLimit(1)
                    Text("\(a.plays) play\(a.plays == 1 ? "" : "s")").font(Typo.rowSubtitle).foregroundStyle(Palette.subdued)
                }
                Spacer()
            }
            .padding(.horizontal, Space.gutter).frame(height: Metrics.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .disabled(a.id == nil)
        .accessibilityIdentifier("top-artist")
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typo.font(14)).foregroundStyle(Palette.subdued)
            .padding(.horizontal, Space.gutter).padding(.top, Space.l)
            .accessibilityIdentifier("history-empty")
    }

    private func load() async {
        failed = false
        do {
            async let r = app.core.recentTracks(limit: 200)
            async let s = app.core.listeningStats(since: Int64(Date().timeIntervalSince1970) - 28 * 86_400)
            rows = try await r
            stats = try await s
        } catch {
            if rows == nil || stats == nil { failed = true }
        }
    }
}
