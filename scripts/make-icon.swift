// Draws the Decibel app icon. Usage: swift scripts/make-icon.swift <out.png> [size]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1024") ?? 1024)
let s = size / 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt squircle centred on a 1024 canvas, with a soft drop shadow.
let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor.black.setFill()
shape.fill()
ctx.restoreGState()

shape.addClip()
NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.06, alpha: 1)])!.draw(in: tile, angle: -90)

// Level bars along the bottom, rising like a meter.
let accent = NSColor(red: 0.30, green: 0.45, blue: 0.97, alpha: 1)
let heights: [CGFloat] = [0.26, 0.36, 0.50, 0.40, 0.30]
let alphas: [CGFloat] = [0.35, 0.55, 0.95, 0.55, 0.35]
let barW = 74 * s, gap = 34 * s
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
for (i, h) in heights.enumerated() {
    let x = tile.midX - total / 2 + CGFloat(i) * (barW + gap)
    let bar = NSRect(x: x, y: tile.minY + 110 * s, width: barW, height: 824 * s * h * 0.42)
    accent.withAlphaComponent(alphas[i]).setFill()
    NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
}

// The ear, in a light-to-accent gradient, masked from the SF Symbol.
let config = NSImage.SymbolConfiguration(pointSize: 370 * s, weight: .medium)
if let ear = NSImage(systemSymbolName: "ear", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let rect = NSRect(x: tile.midX - ear.size.width / 2, y: tile.midY - ear.size.height / 2 + 105 * s,
                      width: ear.size.width, height: ear.size.height)
    let glyph = NSImage(size: rect.size, flipped: false) { r in
        NSGradient(colors: [NSColor(red: 0.78, green: 0.86, blue: 1, alpha: 1), accent])!.draw(in: r, angle: -90)
        ear.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }
    glyph.draw(in: rect)
}

// Hairline highlight along the top edge.
NSColor(white: 1, alpha: 0.10).setStroke()
let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 184 * s, yRadius: 184 * s)
rim.lineWidth = 3 * s
rim.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
