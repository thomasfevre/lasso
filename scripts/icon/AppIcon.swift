// Renders the Lasso app icon into a full .iconset, matching the app's own
// GlassKit theme (warm dark glass: near-black ground, an amber glow top-right and
// an indigo glow bottom-left, a cream viewfinder, an amber focus dot). Run via
// scripts/icon/generate.sh, which turns the .iconset into AppIcon.icns.
//
// Usage: swift AppIcon.swift <output-iconset-dir>
import AppKit

let cream = NSColor(srgbRed: 0.957, green: 0.925, blue: 0.878, alpha: 1) // #f4ece0
let ground = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.051, alpha: 1) // #0a0a0d
let amberHi = NSColor(srgbRed: 0.886, green: 0.733, blue: 0.490, alpha: 1) // #e2bb7d
let amberLo = NSColor(srgbRed: 0.663, green: 0.467, blue: 0.247, alpha: 1) // #a9773f
let amberGlow = NSColor(srgbRed: 0.47, green: 0.34, blue: 0.17, alpha: 1)
let indigoGlow = NSColor(srgbRed: 0.16, green: 0.20, blue: 0.41, alpha: 1)

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle tile with a small inset, so the mark never sits on the pixel edge.
    let inset = s * 0.05
    let tile = NSRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
    let w = tile.width
    let path = NSBezierPath(roundedRect: tile, xRadius: w * 0.2237, yRadius: w * 0.2237)

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()

    // Ground.
    ground.setFill(); tile.fill()

    // Glows (AppKit y-up: top = maxY). Indigo bottom-left, amber top-right on top.
    func glow(_ color: NSColor, cx: CGFloat, cy: CGFloat, radius: CGFloat, peak: CGFloat) {
        guard let g = NSGradient(colors: [color.withAlphaComponent(peak), color.withAlphaComponent(0)]) else { return }
        g.draw(fromCenter: CGPoint(x: cx, y: cy), radius: 0,
               toCenter: CGPoint(x: cx, y: cy), radius: radius, options: [])
    }
    glow(indigoGlow, cx: tile.minX + w*0.14, cy: tile.minY + w*0.10, radius: w*0.80, peak: 0.55)
    glow(amberGlow,  cx: tile.minX + w*0.82, cy: tile.minY + w*0.90, radius: w*0.85, peak: 0.55)

    // Faint diagonal sheen from the top-leading.
    if let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0)]) {
        sheen.draw(in: tile, angle: -55)
    }

    // Viewfinder brackets in cream.
    let vf = tile.insetBy(dx: w*0.30, dy: w*0.30)
    let len = vf.width * 0.32, line = w * 0.045, rad = w * 0.05
    cream.setStroke()
    let corners: [(NSPoint, NSPoint, NSPoint)] = [
        (NSPoint(x: vf.minX, y: vf.minY+len), NSPoint(x: vf.minX, y: vf.minY), NSPoint(x: vf.minX+len, y: vf.minY)),
        (NSPoint(x: vf.maxX-len, y: vf.minY), NSPoint(x: vf.maxX, y: vf.minY), NSPoint(x: vf.maxX, y: vf.minY+len)),
        (NSPoint(x: vf.maxX, y: vf.maxY-len), NSPoint(x: vf.maxX, y: vf.maxY), NSPoint(x: vf.maxX-len, y: vf.maxY)),
        (NSPoint(x: vf.minX+len, y: vf.maxY), NSPoint(x: vf.minX, y: vf.maxY), NSPoint(x: vf.minX, y: vf.maxY-len)),
    ]
    for (a, c, b) in corners {
        let p = NSBezierPath()
        p.lineWidth = line; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: a); p.appendArc(from: c, to: b, radius: rad); p.line(to: b)
        p.stroke()
    }

    // Amber focus dot at center, with a diagonal amber gradient.
    let d = w * 0.13
    let dotRect = NSRect(x: tile.midX - d/2, y: tile.midY - d/2, width: d, height: d)
    if let ag = NSGradient(starting: amberHi, ending: amberLo) {
        ag.draw(in: NSBezierPath(ovalIn: dotRect), angle: -60)
    }

    NSGraphicsContext.current?.restoreGraphicsState() // drop clip

    // Specular glass rim: a bright top-leading edge fading to a faint dark bottom.
    if let rim = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.5),
        NSColor.white.withAlphaComponent(0),
        NSColor.black.withAlphaComponent(0.28),
    ]) {
        let ring = NSBezierPath(roundedRect: tile.insetBy(dx: w*0.006, dy: w*0.006),
                                xRadius: w*0.2237, yRadius: w*0.2237)
        ring.lineWidth = max(1, w * 0.012)
        ring.addClip()
        rim.draw(in: tile, angle: -45)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// iconset entries: (filename, pixel size)
let entries: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    write(drawIcon(size: px), to: out.appendingPathComponent(name))
}
// A standalone 1024 master for reference / other platforms.
write(drawIcon(size: 1024), to: out.deletingLastPathComponent().appendingPathComponent("icon-master-1024.png"))
print("rendered \(entries.count) sizes into \(out.path)")
