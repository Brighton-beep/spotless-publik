// Tempo, pitch and reverb for music (`set_playback_params {speed, semitones, reverb}`), the Mac's
// TempoPitchDialog. The presets and rooms mirror the desktop's `ui/src/lib/effect-presets.ts`
// (a UI table there too); the core applies whatever it is sent.
import Foundation

/// `player::Reverb`, camelCase on the wire.
struct Reverb: Codable, Hashable {
    var enabled = false
    /// 1...6: small / medium / large room, medium / large hall, plate.
    var preset = 3
    var dry = 100
    var wet = 25
    var decay = 1.1
    var preDelay = 0
    var damping = 8000
    var reflections = 100

    /// The rooms in `player::REVERB_PRESETS` order, and each one's natural length.
    static let rooms = ["Small room", "Medium room", "Large room", "Medium hall", "Large hall", "Plate"]
    static let roomDecays: [Double] = [0.4, 0.7, 1.1, 1.8, 3.2, 1.8]

    /// Reverb on, in `room` at its natural length: picking a room undoes a decay fine-tune.
    func inRoom(_ room: Int) -> Reverb {
        var r = self
        r.enabled = true; r.preset = room; r.decay = Self.roomDecays[room - 1]
        return r
    }
}

struct PlaybackEffects: Codable, Hashable {
    var speed: Double = 1
    var semitones = 0
    var reverb = Reverb()

    init(speed: Double = 1, semitones: Int = 0, reverb: Reverb = Reverb()) {
        self.speed = speed; self.semitones = semitones; self.reverb = reverb
    }

    /// The `playback-params` event; older payloads carry only the speed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decode(Double.self, forKey: .speed)
        semitones = try c.decodeIfPresent(Int.self, forKey: .semitones) ?? 0
        reverb = try c.decodeIfPresent(Reverb.self, forKey: .reverb) ?? Reverb()
    }

    static let original = PlaybackEffects()
    var isOriginal: Bool { sameSound(.original) }

    /// What you hear: a switched-off reverb's settings make no difference to it.
    func sameSound(_ o: PlaybackEffects) -> Bool {
        guard abs(speed - o.speed) < 0.001, semitones == o.semitones, reverb.enabled == o.reverb.enabled else { return false }
        return !reverb.enabled || reverb == o.reverb
    }

    struct Preset: Identifiable {
        var id: String
        var title: String
        var hint: String
        var icon: String
        var effects: PlaybackEffects
    }

    /// One-tap sounds. Slowed and nightcore shift pitch with speed the way a record does.
    static let presets: [Preset] = {
        var slowed = Reverb().inRoom(4); slowed.wet = 40
        var nightcore = Reverb().inRoom(6); nightcore.wet = 15; nightcore.decay = 1.2; nightcore.preDelay = 20
        return [
            Preset(id: "original", title: "Original", hint: "The song as it was released", icon: "music-note", effects: .original),
            Preset(id: "slowed", title: "Slowed + reverb", hint: "Slower and deeper, in a big room", icon: "moon",
                   effects: PlaybackEffects(speed: 0.85, semitones: -3, reverb: slowed)),
            Preset(id: "nightcore", title: "Nightcore", hint: "Faster and higher, with a touch of reverb", icon: "sparkle",
                   effects: PlaybackEffects(speed: 1.2, semitones: 3, reverb: nightcore)),
            Preset(id: "practice", title: "Practice", hint: "Slower, in the same key", icon: "timer",
                   effects: PlaybackEffects(speed: 0.75)),
            Preset(id: "hall", title: "Concert hall", hint: "As if it were playing live", icon: "users-three",
                   effects: PlaybackEffects(reverb: Reverb().inRoom(5))),
        ]
    }()
}
