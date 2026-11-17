// The DMG window's background picture, drawn with CoreGraphics/CoreText (no assets, no tools).
//   swift scripts/macos/dmg-background.swift <out-dir>
// Writes background.png (640x400) and background@2x.png (1280x800) into <out-dir>; make-dmg.sh
// merges them into one HiDPI TIFF with tiffutil. The geometry must match make-dmg.sh: icons
// centred at (160,170) and (480,170) in a 640x400 window, top-left origin.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 640, H: CGFloat = 400
let iconY: CGFloat = 170          // icon centre, from the top (Finder's coordinates)
let leftX: CGFloat = 160, rightX: CGFloat = 480
let labelCenterY: CGFloat = 253   // where Finder centres a 13pt label under a 128pt icon
let pink = CGColor(srgbRed: 1.0, green: 0x2D / 255.0, blue: 0x7A / 255.0, alpha: 1)

func text(_ c: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, baselineFromTop y: CGFloat) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: size * -0.01])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    c.textPosition = CGPoint(x: centerX - CGFloat(w) / 2, y: H - y)
    CTLineDraw(line, c)
}

func render(scale: CGFloat, to path: String) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.scaleBy(x: scale, y: scale)
    c.interpolationQuality = .high
    c.setShouldSmoothFonts(false)

    // Near-black, a touch lighter at the top.
    let bg = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.085, green: 0.085, blue: 0.095, alpha: 1),
                                                  CGColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    // A faint pink glow behind the arrow, so the eye lands on the path from app to folder.
    let glow = CGGradient(colorsSpace: cs, colors: [pink.copy(alpha: 0.10)!, pink.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H - iconY), startRadius: 0,
                         endCenter: CGPoint(x: W / 2, y: H - iconY), endRadius: 260, options: [])

    // Arrow: a pink stroke with a chevron head, between the two 128pt icons.
    let y = H - iconY
    let x0 = leftX + 92, x1 = rightX - 92
    c.setStrokeColor(pink)
    c.setLineWidth(3)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: x0, y: y)); c.addLine(to: CGPoint(x: x1, y: y))
    c.move(to: CGPoint(x: x1 - 11, y: y + 11)); c.addLine(to: CGPoint(x: x1, y: y)); c.addLine(to: CGPoint(x: x1 - 11, y: y - 11))
    c.strokePath()

    // Finder draws icon labels black in Light Mode and white in Dark Mode, whatever the picture,
    // and nothing in a .DS_Store can change that. A mid-grey pill under each label keeps both
    // readable (about 4.5:1 either way) on the dark background.
    let labelY = H - labelCenterY
    c.setFillColor(CGColor(srgbRed: 0.48, green: 0.48, blue: 0.50, alpha: 1))
    for x in [leftX, rightX] {
        c.addPath(CGPath(roundedRect: CGRect(x: x - 52, y: labelY - 11, width: 104, height: 22),
                         cornerWidth: 11, cornerHeight: 11, transform: nil))
    }
    c.fillPath()

    text(c, "Drag Spotless to Applications", size: 17, weight: .semibold, color: .white, centerX: W / 2, baselineFromTop: 318)
    text(c, "or just open it, and Spotless installs itself", size: 12.5, weight: .regular,
         color: NSColor(white: 1, alpha: 0.5), centerX: W / 2, baselineFromTop: 341)

    let img = c.makeImage()!
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(d) else { fatalError("cannot write \(path)") }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(scale: 1, to: "\(out)/background.png")
render(scale: 2, to: "\(out)/background@2x.png")
