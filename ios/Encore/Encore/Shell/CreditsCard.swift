// Lane P1: Spotify's "Credits" card under Now Playing (the desktop's `nowplaying/CreditsCard.svelte`,
// lane magic-d6). "Credits" with "Show all" (the credits sheet), then up to three people, one row
// each with all their roles ("Main Artist, Producer"), and Follow on names YouTube links to a
// channel. Hidden while it loads, when YouTube has none, and for episodes, as Spotify leaves it out.
// Hook (in `Shell/NowPlaying.swift`, after About the artist): `CreditsCard()`
import SwiftUI

struct CreditsCard: View {
    @Environment(AppModel.self) private var app
    @State private var credits: SongCredits?
    @State private var forId: String?

    private var song: SongItem? {
        let s = app.player.current
        guard let s, s.isEpisode != true, s.videoId == (app.player.now?.videoId ?? s.videoId) else { return nil }
        return s
    }

    var body: some View {
        let people = Array((credits?.people ?? []).prefix(3))
        // A real container: a `.task` on an empty Group never runs, and the card starts empty.
        VStack(spacing: 0) {
            if let song, forId == song.videoId, !people.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        Text("Credits").font(Typo.font(16, .bold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Show all") { CreditsPresenter.present(song, app: app, afterSheet: false) }
                            .font(Typo.font(14, .bold)).foregroundStyle(Palette.subdued)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("credits-show-all")
                    }
                    ForEach(people, id: \.name) { p in row(p) }
                }
                .foregroundStyle(Palette.text)
                .padding(Space.l)
                .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.elevatedHighlight))
                .padding(.horizontal, Space.gutter)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("credits-card")
            }
        }
        .task(id: song?.videoId) { await load() }
    }

    private func row(_ p: SongCredits.Row) -> some View {
        HStack(spacing: Space.m) {
            Button {
                openCreditName(app, name: p.name, artistId: p.artistId)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(Typo.rowTitle).lineLimit(1)
                    Text(p.roles.joined(separator: ", ")).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let id = p.artistId { FollowPill(name: p.name, artistId: id) }
        }
        .frame(minHeight: 56)
    }

    private func load() async {
        guard let song else { credits = nil; forId = nil; return }
        if let hit = CreditsCache.shared.cached(song.videoId) { credits = hit; forId = song.videoId; return }
        let c = try? await CreditsCache.shared.load(song, core: app.core)
        guard !Task.isCancelled else { return }
        credits = c
        forId = song.videoId
    }
}
