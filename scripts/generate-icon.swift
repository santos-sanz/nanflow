import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Nanflow.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func squircle(rect: NSRect, n: CGFloat = 5.0) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = copysign(pow(abs(c), 2.0 / n), c)
        let y = copysign(pow(abs(s), 2.0 / n), s)
        let point = NSPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func renderIcon(size: CGFloat) throws -> Data {
    let scale = size / 1024.0
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "NanflowIcon", code: 1) }

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "NanflowIcon", code: 2)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    let margin: CGFloat = 82 * scale
    let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let shape = squircle(rect: rect)
    shape.lineJoinStyle = .round
    shape.lineCapStyle = .round

    cg.saveGState()
    shape.addClip()

    let background = NSGradient(colorsAndLocations:
        (color(0x14235A), 0.0),
        (color(0x2A5BF0), 0.48),
        (color(0x8B3DFF), 1.0)
    )!
    background.draw(
        from: NSPoint(x: rect.minX, y: rect.maxY),
        to: NSPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    let sheenCenter = NSPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.18)
    let sheen = NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.16), 0.0),
        (NSColor.white.withAlphaComponent(0.0), 1.0)
    )!
    sheen.draw(
        fromCenter: sheenCenter,
        radius: 0,
        toCenter: sheenCenter,
        radius: rect.width * 0.40,
        options: []
    )

    let glow = NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.10), 0.0),
        (NSColor.white.withAlphaComponent(0.0), 1.0)
    )!
    glow.draw(
        fromCenter: NSPoint(x: rect.midX, y: rect.midY),
        radius: 0,
        toCenter: NSPoint(x: rect.midX, y: rect.midY),
        radius: rect.width * 0.44,
        options: []
    )

    let shade = NSGradient(colorsAndLocations:
        (NSColor.black.withAlphaComponent(0.20), 0.0),
        (NSColor.black.withAlphaComponent(0.0), 1.0)
    )!
    shade.draw(
        from: NSPoint(x: rect.midX, y: rect.minY),
        to: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.55),
        options: []
    )

    let compact = size <= 32
    let barWidth: CGFloat = compact ? max(2.4, 0.15 * size) : 64 * scale
    let gap: CGFloat = compact ? max(0.9, 0.055 * size) : 30 * scale
    let maxHeight: CGFloat = compact ? size * 0.42 : 380 * scale
    let heights: [CGFloat] = compact ? [0.58, 1.0, 0.58] : [0.42, 0.72, 1.0, 0.72, 0.42]
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - totalWidth / 2
    let centerY = rect.midY + 6 * scale

    cg.saveGState()
    if !compact {
        cg.setShadow(offset: .zero, blur: 18 * scale, color: NSColor.white.withAlphaComponent(0.30).cgColor)
    }
    for height in heights {
        let barRect = NSRect(x: x, y: centerY - maxHeight * height / 2, width: barWidth, height: maxHeight * height)
        let bar = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSColor.white.withAlphaComponent(0.97).setFill()
        bar.fill()
        x += barWidth + gap
    }
    cg.restoreGState()

    cg.restoreGState()

    cg.saveGState()
    shape.lineWidth = 2.5 * scale
    NSColor.white.withAlphaComponent(0.16).setStroke()
    shape.stroke()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "NanflowIcon", code: 3)
    }
    return data
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    try renderIcon(size: CGFloat(size)).write(to: iconset.appendingPathComponent(name))
}

try renderIcon(size: 1024).write(to: root.appendingPathComponent("docs/logo.png"))

let logo = """
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="8%" y1="8%" x2="92%" y2="92%">
      <stop offset="0%" stop-color="#14235A"/>
      <stop offset="48%" stop-color="#2A5BF0"/>
      <stop offset="100%" stop-color="#8B3DFF"/>
    </linearGradient>
    <radialGradient id="sheen" cx="24%" cy="20%" r="40%">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect x="82" y="82" width="860" height="860" rx="194" fill="url(#bg)"/>
  <rect x="82" y="82" width="860" height="860" rx="194" fill="url(#sheen)"/>
  <g fill="#FFFFFF" fill-opacity="0.97">
    <rect x="292" y="438" width="64" height="160" rx="32"/>
    <rect x="386" y="381" width="64" height="274" rx="32"/>
    <rect x="480" y="328" width="64" height="380" rx="32"/>
    <rect x="574" y="381" width="64" height="274" rx="32"/>
    <rect x="668" y="438" width="64" height="160" rx="32"/>
  </g>
</svg>
"""
try logo.write(to: root.appendingPathComponent("docs/logo.svg"), atomically: true, encoding: .utf8)
print("Wrote build/Nanflow.iconset, docs/logo.png and docs/logo.svg")
