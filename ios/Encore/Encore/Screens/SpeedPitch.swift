// Speed & pitch for music (the desktop's TempoPitchDialog): pick a ready-made sound, or set tempo,
// pitch and reverb yourself. Every change applies when the finger lifts; nothing waits for Done.
// Episodes keep their own speed sheet (Podcasts.swift `SpeedSheet`).
import SwiftUI

struct EffectsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// A slider mid-drag; committed on release.
    @State private var speedDraft: Double?
    @State private var pitchDraft: Double?
    @State private var wetDraft: Double?

    private var e: PlaybackEffects { app.effects }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Speed & pitch").font(Typo.font(18, .bold)).accessibilityAddTraits(.isHeader)
                Text("Applies to every song you play, until you change it back or restart the app.")
                    .font(Typo.font(13)).foregroundStyle(Palette.subdued)
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.m)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    label("Presets")
                    presets
                    label("Adjust").padding(.top, Space.l)
                    VStack(spacing: 0) {
                        tempo
                        Divider().overlay(Palette.border)
                        pitch
                        Divider().overlay(Palette.border)
                        reverb
                    }
                    .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Palette.tinted))
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.l)
            }
            HStack {
                Button { Haptics.selection(); app.setEffects(.original) } label: {
                    Text("Reset all").font(Typo.button).padding(.horizontal, Space.l).frame(height: 36)
                        .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                }
                .disabled(e == .original)
                .opacity(e == .original ? 0.4 : 1)
                .accessibilityIdentifier("effects-reset")
                Spacer()
                Button { dismiss() } label: {
                    Text("Done").font(Typo.button).foregroundStyle(.black).padding(.horizontal, Space.xl).frame(height: 36)
                        .background(Capsule().fill(.white))
                }
                .accessibilityIdentifier("effects-done")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effects-sheet")
    }

    private func label(_ t: String) -> some View {
        Text(t).font(Typo.font(16, .bold)).accessibilityAddTraits(.isHeader)
    }

    // MARK: presets

    private var presets: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
            ForEach(PlaybackEffects.presets) { p in
                let on = e.sameSound(p.effects)
                Button { Haptics.selection(); app.setEffects(p.effects) } label: {
                    HStack(alignment: .top, spacing: Space.s) {
                        Icon(name: p.icon, fill: on, size: 20).foregroundStyle(on ? Palette.accent : Palette.subdued)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(Typo.font(14, .bold)).lineLimit(1)
                            Text(p.hint).font(Typo.font(12)).foregroundStyle(Palette.subdued).lineLimit(2)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(on ? Palette.accent.opacity(0.12) : Palette.tinted))
                    .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).stroke(on ? Palette.accent : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale(scale: 0.98))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(p.hint)
                .accessibilityIdentifier("effects-preset-\(p.id)")
            }
        }
    }

    // MARK: sliders

    private var tempo: some View {
        let v = speedDraft ?? e.speed
        return VStack(alignment: .leading, spacing: Space.s) {
            valueRow("Tempo", v == 1 ? "Normal" : String(format: "%.2f×", v), changed: e.speed != 1, reset: {
                var n = e; n.speed = 1; app.setEffects(n)
            })
            Slider(value: Binding(get: { v }, set: { speedDraft = ($0 * 20).rounded() / 20 }), in: 0.5...2, step: 0.05) { editing in
                if !editing, let d = speedDraft { var n = e; n.speed = d; speedDraft = nil; app.setEffects(n) }
            }
            .tint(Palette.accent)
            .accessibilityLabel("Tempo")
            .accessibilityIdentifier("effects-tempo")
            scale("Slower", "Faster", normalAt: (1 - 0.5) / 1.5)
            if v != 1, app.player.duration > 0 {
                Text("This song lasts \(Self.clock(app.player.duration / v))").font(Typo.font(12)).foregroundStyle(Palette.subdued)
            }
        }
        .padding(Space.l)
    }

    private var pitch: some View {
        let v = Int(pitchDraft ?? Double(e.semitones))
        return VStack(alignment: .leading, spacing: Space.s) {
            valueRow("Pitch", v == 0 ? "Normal" : Self.signed(v), changed: e.semitones != 0, reset: {
                var n = e; n.semitones = 0; app.setEffects(n)
            })
            Slider(value: Binding(get: { Double(v) }, set: { pitchDraft = $0.rounded() }), in: -12...12, step: 1) { editing in
                if !editing, let d = pitchDraft { var n = e; n.semitones = Int(d); pitchDraft = nil; app.setEffects(n) }
            }
            .tint(Palette.accent)
            .accessibilityLabel("Pitch")
            .accessibilityValue(v == 0 ? "Normal" : "\(Self.signed(v)) semitones")
            .accessibilityIdentifier("effects-pitch")
            scale("Lower", "Higher", normalAt: 0.5)
        }
        .padding(Space.l)
    }

    private var reverb: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Toggle(isOn: Binding(get: { e.reverb.enabled }, set: { on in var n = e; n.reverb.enabled = on; app.setEffects(n) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reverb").font(Typo.font(15, .bold))
                    Text("Make it sound like it's playing in a room.").font(Typo.font(12)).foregroundStyle(Palette.subdued)
                }
            }
            .tint(Palette.accent)
            .accessibilityIdentifier("effects-reverb")
            if e.reverb.enabled {
                Text("Room").font(Typo.font(12, .bold)).foregroundStyle(Palette.subdued)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 3), spacing: Space.s) {
                    ForEach(Array(Reverb.rooms.enumerated()), id: \.offset) { i, name in
                        let on = e.reverb.preset == i + 1
                        Button { Haptics.selection(); var n = e; n.reverb = e.reverb.inRoom(i + 1); app.setEffects(n) } label: {
                            HStack(spacing: 6) {
                                tail(Reverb.roomDecays[i], on: on)
                                Text(name).font(Typo.font(12, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(on ? Palette.text : Palette.subdued)
                            .padding(.horizontal, Space.s).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(on ? Palette.accent.opacity(0.12) : Palette.tinted))
                            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(on ? Palette.accent : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("effects-room-\(i + 1)")
                    }
                }
                let wet = wetDraft ?? Double(e.reverb.wet)
                valueRow("Amount", "\(Int(wet))%", changed: false)
                Slider(value: Binding(get: { wet }, set: { wetDraft = $0.rounded() }), in: 0...100, step: 1) { editing in
                    if !editing, let d = wetDraft { var n = e; n.reverb.wet = Int(d); wetDraft = nil; app.setEffects(n) }
                }
                .tint(Palette.accent)
                .accessibilityLabel("Reverb amount")
            }
        }
        .padding(Space.l)
    }

    /// A room's tail as bars over 3.6 s, so a hall reads longer than a room at a glance.
    private func tail(_ decay: Double, on: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<7, id: \.self) { i in
                let h = max(2, 14 * pow(max(0, 1 - Double(i) * 0.5 / (decay * 1.25)), 1.6))
                Capsule().fill(on ? Palette.accent : Palette.subdued.opacity(0.4)).frame(width: 2, height: h)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func valueRow(_ title: String, _ value: String, changed: Bool, reset: (() -> Void)? = nil) -> some View {
        HStack(spacing: Space.s) {
            Text(title).font(Typo.font(15, .bold))
            Spacer()
            if let reset {
                Button("Reset", action: reset).font(Typo.font(13, .bold)).foregroundStyle(Palette.accentText)
                    .opacity(changed ? 1 : 0).disabled(!changed)
            }
            Text(value).font(Typo.font(14, .bold)).monospacedDigit()
                .frame(minWidth: 64).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.tintedHighlight))
        }
    }

    /// The slider's ends in words, and "Normal" marked where it sits.
    private func scale(_ low: String, _ high: String, normalAt: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Text(low).offset(y: 4)
                Text(high).frame(maxWidth: .infinity, alignment: .trailing).offset(y: 4)
                VStack(spacing: 1) {
                    Rectangle().fill(Palette.subdued.opacity(0.5)).frame(width: 1, height: 4)
                    Text("Normal")
                }
                .fixedSize()
                .position(x: g.size.width * normalAt, y: 10)
            }
        }
        .font(Typo.font(11)).foregroundStyle(Palette.subdued)
        .frame(height: 22)
        .accessibilityHidden(true)
    }

    static func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : n < 0 ? "−\(-n)" : "0" }

    static func clock(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
    }
}
