// SVG -> PNG with macOS's own SVG renderer (NSImage), no third-party tools.
// Reads jobs from stdin, one per line:  <in.svg> <out.png> <size | WxH> [opaque] [shadow]
//   opaque  RGB PNG without an alpha channel (the iOS App Store icon must have none)
//   shadow  macOS app-icon drop shadow under the artwork (CoreGraphics shadow follows its alpha)
// Driven by scripts/brand/gen-brand.py, which compiles this once and pipes every job through it.
import AppKit
import ImageIO
import UniformTypeIdentifiers

func render(_ src: String, _ dst: String, _ n: Int, _ h: Int, opaque: Bool, shadow: Bool) {
    guard let img = NSImage(contentsOfFile: src) else { fatalError("cannot read \(src)") }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let c = CGContext(data: nil, width: n, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
    c.interpolationQuality = .high
    if opaque { c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: n, height: h)) }
    let s = CGFloat(n)
    if shadow {
        // Apple's macOS icon grid: a soft shadow ~1% down, ~1% blur, 30% black.
        c.setShadow(offset: CGSize(width: 0, height: -s * 0.0098), blur: s * 0.0195,
                    color: CGColor(gray: 0, alpha: 0.30))
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    img.draw(in: NSRect(x: 0, y: 0, width: s, height: CGFloat(h)), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let out = c.makeImage()!
    let url = URL(fileURLWithPath: dst) as CFURL
    let d = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, out, nil)
    guard CGImageDestinationFinalize(d) else { fatalError("cannot write \(dst)") }
}

while let line = readLine() {
    let f = line.split(separator: " ").map(String.init)
    if f.count < 3 { continue }
    let wh = f[2].split(separator: "x").map { Int($0)! }
    render(f[0], f[1], wh[0], wh.count > 1 ? wh[1] : wh[0], opaque: f.contains("opaque"), shadow: f.contains("shadow"))
}
