// Port of the desktop `ui/src/lib/eq-curve.ts`: the RBJ Audio EQ Cookbook biquads FFmpeg's
// lowshelf/equalizer/highshelf use (and `crates/player/src/dsp.rs`), so the curve on screen is the
// curve the player applies. Presets are `dsp::PRESETS` (fitted to Apple Music's EQ curves).
import Foundation

enum EQ {
    enum Kind: String { case lowshelf, peaking, highshelf }
    struct Band { var kind: Kind; var freq: Double; var q: Double }
    struct Biquad { var b0, b1, b2, a1, a2: Double }

    /// Spotify's six bands (`dsp::EQ_BANDS`).
    static let bands: [Band] = [
        Band(kind: .lowshelf, freq: 60, q: 0.7), Band(kind: .peaking, freq: 150, q: 1), Band(kind: .peaking, freq: 400, q: 1),
        Band(kind: .peaking, freq: 1000, q: 1), Band(kind: .peaking, freq: 2400, q: 1), Band(kind: .highshelf, freq: 15000, q: 0.7),
    ]
    static let maxDb = 12.0
    static let rate = 48000.0
    static let fMin = 20.0
    static let fMax = 20000.0

    /// `dsp::PRESETS`, same order and values.
    static let presets: [(String, [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0]),
        ("Acoustic", [5.8, 3.5, 0.8, 0.7, 5.0, 3.5]),
        ("Bass Booster", [6.0, 3.6, 1.2, -0.2, 0.0, 0.0]),
        ("Bass Reducer", [-6.0, -3.6, -1.2, 0.2, 0.0, 0.0]),
        ("Classical", [5.1, 3.7, -0.3, -2.5, 2.2, 5.8]),
        ("Dance", [5.1, 4.7, -0.8, 2.7, 6.0, 0.5]),
        ("Deep", [5.5, 1.4, 1.4, 3.1, -1.3, -7.2]),
        ("Electronic", [4.9, 1.8, -2.5, 1.7, 1.5, 7.5]),
        ("Hip-Hop", [5.6, 2.7, 0.3, -1.4, 1.4, 4.5]),
        ("Jazz", [4.3, 2.4, -0.1, -2.3, 1.7, 5.8]),
        ("Latin", [4.9, 0.4, -0.8, -1.7, -0.3, 6.9]),
        ("Loudness", [6.6, 0.6, -1.8, 0.8, -2.9, 2.3]),
        ("Lounge", [-3.1, -0.7, 3.3, 2.4, -1.2, 1.7]),
        ("Piano", [3.2, 0.3, 3.2, 0.0, 5.2, 5.3]),
        ("Pop", [-1.7, -0.1, 3.1, 3.6, 0.4, -2.3]),
        ("R&B", [4.2, 6.6, -2.5, -2.1, 4.0, 5.7]),
        ("Rock", [5.5, 3.2, -0.1, -1.8, 2.5, 7.0]),
        ("Small Speakers", [6.0, 3.6, 1.1, 0.5, -2.8, -6.6]),
        ("Spoken Word", [-3.2, -0.1, 1.9, 3.4, 5.3, 0.4]),
        ("Treble Booster", [0.0, 0.0, -0.1, 0.2, 4.2, 8.6]),
        ("Treble Reducer", [0.0, 0.0, 0.1, -0.2, -4.2, -8.6]),
        ("Vocal Booster", [-2.2, -3.1, 3.6, 2.9, 2.2, -2.1]),
    ]

    static func biquad(_ kind: Kind, freq: Double, q: Double, gainDb: Double, rate: Double = rate) -> Biquad {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * freq / rate
        let c = cos(w0)
        let alpha = sin(w0) / (2 * q)
        var b0, b1, b2, a0, a1, a2: Double
        if kind == .peaking {
            (b0, b1, b2) = (1 + alpha * A, -2 * c, 1 - alpha * A)
            (a0, a1, a2) = (1 + alpha / A, -2 * c, 1 - alpha / A)
        } else {
            let k = 2 * sqrt(A) * alpha
            let s: Double = kind == .lowshelf ? 1 : -1
            b0 = A * (A + 1 - s * (A - 1) * c + k)
            b1 = s * 2 * A * (A - 1 - s * (A + 1) * c)
            b2 = A * (A + 1 - s * (A - 1) * c - k)
            a0 = A + 1 + s * (A - 1) * c + k
            a1 = -s * 2 * (A - 1 + s * (A + 1) * c)
            a2 = A + 1 + s * (A - 1) * c - k
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// |H(e^jw)| in dB.
    static func magnitudeDb(_ c: Biquad, freq: Double, rate: Double = rate) -> Double {
        let w = 2 * Double.pi * freq / rate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = c.b0 + c.b1 * c1 + c.b2 * c2
        let ni = -(c.b1 * s1 + c.b2 * s2)
        let dr = 1 + c.a1 * c1 + c.a2 * c2
        let di = -(c.a1 * s1 + c.a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }

    /// Summed response of all bands at `freq` (cascaded biquads: dB adds).
    static func responseDb(_ gains: [Double], freq: Double, bands: [Band] = bands) -> Double {
        var sum = 0.0
        for (i, b) in bands.enumerated() {
            let g = i < gains.count ? gains[i] : 0
            if g != 0 { sum += magnitudeDb(biquad(b.kind, freq: b.freq, q: b.q, gainDb: g), freq: freq) }
        }
        return sum
    }

    static func logFrequencies(_ n: Int = 200) -> [Double] {
        let lo = log(fMin), hi = log(fMax)
        return (0..<n).map { exp(lo + (hi - lo) * Double($0) / Double(n - 1)) }
    }

    static func freqToX(_ f: Double) -> Double { (log(f) - log(fMin)) / (log(fMax) - log(fMin)) }
    static func xToFreq(_ x: Double) -> Double { exp(log(fMin) + x * (log(fMax) - log(fMin))) }

    /// The player's automatic pre-gain (`dsp::auto_preamp`), for display.
    static func autoPreamp(_ gains: [Double]) -> Double {
        let peak = logFrequencies(241).map { responseDb(gains, freq: $0) }.max() ?? 0
        let p = -max(0, peak)
        return (max(p, -maxDb) * 100).rounded() / 100 + 0
    }

    /// Clamp to ±12 and round to 0.1 dB, like the player.
    static func clamp(_ g: Double) -> Double {
        guard g.isFinite else { return 0 }
        return (max(-maxDb, min(maxDb, g)) * 10).rounded() / 10 + 0
    }

    /// The preset these gains are (within 0.05 dB), if any.
    static func presetName(_ gains: [Double]) -> String? {
        presets.first { p in zip(p.1, gains).allSatisfy { abs($0 - $1) < 0.05 } }?.0
    }

    /// "60Hz", "1KHz", "2.4KHz": Spotify's axis labels.
    static func freqLabel(_ f: Double) -> String {
        if f >= 1000 {
            let k = (f / 100).rounded() / 10
            return k == k.rounded() ? "\(Int(k))KHz" : "\(k)KHz"
        }
        return "\(Int(f))Hz"
    }
}
