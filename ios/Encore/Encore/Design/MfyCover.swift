// Made for you covers drawn natively, in the style of the desktop's generated SVGs
// (`smart/mfy.rs::cover_svg`, devmock `coverSvg`): colour band backdrop with a glow, our mark
// top-left, the playlist's name set in Figtree 800. Mock/core thumbnails use `mfy:<title>#<n>`.
import SwiftUI

struct MfyCoverArt: View {
    let title: String
    let n: Int
    /// The core's `BANDS` (smart/mfy.rs): backgrounds by playlist number.
    static let bands = ["#3b3f8f", "#7a3b69", "#2f6f73", "#8a5a2b", "#4b6b3a", "#5a4a8a", "#8c3f3f", "#2f5d8a", "#6b5b3e", "#3f6f5a"]

    init(url: String) {
        let body = url.dropFirst(4)
        let parts = body.split(separator: "#", maxSplits: 1)
        title = String(parts.first ?? "").removingPercentEncoding ?? String(parts.first ?? "")
        n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }

    @MainActor static func render(_ url: String) -> UIImage? {
        let r = ImageRenderer(content: MfyCoverArt(url: url).frame(width: 320, height: 320))
        r.scale = 2
        return r.uiImage
    }

    /// One layout for every playlist, as the core draws it: band and glow, the name bottom-left.
    var body: some View {
        GeometryReader { g in
            let u = g.size.width / 640
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottomLeading) {
                    Color(hex: Self.bands[n % Self.bands.count])
                    RadialGradient(colors: [.white.opacity(0.28), .black.opacity(0.25)], center: UnitPoint(x: 0.75, y: 0.2), startRadius: 0, endRadius: 520)
                    Text(title).font(.custom("Figtree-ExtraBold", fixedSize: 64 * u)).foregroundStyle(.white)
                        .minimumScaleFactor(0.3).lineLimit(2).padding(28 * u)
                }
                SpotlessMark(size: 48 * u).padding(28 * u)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Deterministic stand-in artwork for snapshot tests: a two-colour gradient from the URL's hash.
enum StubArt {
    @MainActor static func render(_ url: String) -> UIImage {
        var h: UInt64 = 1469598103934665603
        for b in url.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let hue = Double(h % 360) / 360, hue2 = Double((h >> 9) % 360) / 360
        let v = LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75), Color(hue: hue2, saturation: 0.6, brightness: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing).frame(width: 96, height: 96)
        let r = ImageRenderer(content: v)
        r.scale = 1
        return r.uiImage ?? UIImage()
    }
}
