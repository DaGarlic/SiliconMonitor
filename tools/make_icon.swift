// Draws the app icon: swift tools/make_icon.swift <output.png>   (1024x1024)
import AppKit

let out = CommandLine.arguments[1]
let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Icon body (Apple's grid: 824pt square with ~100pt margin)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
/// Apple-style rounded square (a superellipse, closer to the macOS shape than plain rounded corners).
func squircle(in r: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = r.width / 2, b = r.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = r.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = r.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}
let bodyPath = squircle(in: body)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
rgb(0x0B1A33).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(0x0F2A52), rgb(0x0B1A33), rgb(0x07101F)])!.draw(in: bodyPath, angle: -60)

// Soft top highlight
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Chip
let chip = NSRect(x: 312, y: 312, width: 400, height: 400)
rgb(0xFFFFFF, 0.92).setFill()
for i in 0..<4 {
    let p = 372 + CGFloat(i) * 93.3 - 15
    NSBezierPath(roundedRect: NSRect(x: p, y: chip.maxY - 6, width: 30, height: 64), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: p, y: chip.minY - 58, width: 30, height: 64), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: chip.minX - 58, y: p, width: 64, height: 30), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: chip.maxX - 6, y: p, width: 64, height: 30), xRadius: 8, yRadius: 8).fill()
}
let chipPath = NSBezierPath(roundedRect: chip, xRadius: 78, yRadius: 78)
rgb(0xFFFFFF, 0.96).setFill()
chipPath.fill()
let inner = NSBezierPath(roundedRect: chip.insetBy(dx: 26, dy: 26), xRadius: 54, yRadius: 54)
rgb(0x0B1A33).setFill()
inner.fill()

// Load bars (blue = performance tier, orange = top tier, like the app)
let heights: [CGFloat] = [0.40, 0.72, 0.55, 0.95, 0.66]
let colors = [rgb(0x4AA3FF), rgb(0x4AA3FF), rgb(0x4AA3FF), rgb(0xFF9F3A), rgb(0xFF9F3A)]
let base: CGFloat = 362, maxH: CGFloat = 236
for i in 0..<5 {
    let x = 362 + CGFloat(i) * 65
    rgb(0xFFFFFF, 0.08).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: base, width: 40, height: maxH), xRadius: 10, yRadius: 10).fill()
    colors[i].setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: base, width: 40, height: maxH * heights[i]), xRadius: 10, yRadius: 10).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
