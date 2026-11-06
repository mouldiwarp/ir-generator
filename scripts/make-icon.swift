// Draws the app icon (gold impulse spike decaying into a sweep, on obsidian) and writes an .iconset folder.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let gold = NSColor(srgbRed: 0xC5 / 255, green: 0xA0 / 255, blue: 0x59 / 255, alpha: 1)
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: path, angle: -90)
    gold.withAlphaComponent(0.45).setStroke()
    path.lineWidth = max(1, s * 0.008)
    path.stroke()
    // Baseline, spike, decaying ring.
    let w = body.width, x0 = body.minX + w * 0.12, base = body.minY + body.height * 0.40
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x0, y: base))
    p.line(to: NSPoint(x: x0 + w * 0.14, y: base))
    p.line(to: NSPoint(x: x0 + w * 0.19, y: body.minY + body.height * 0.84))
    p.line(to: NSPoint(x: x0 + w * 0.25, y: body.minY + body.height * 0.18))
    let n = 16
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n - 1)
        let x = x0 + w * (0.25 + 0.51 * t)
        let a = body.height * 0.22 * pow(1 - t, 1.6)
        p.line(to: NSPoint(x: x, y: base + (i.isMultiple(of: 2) ? a : -a)))
    }
    p.lineWidth = s * 0.035
    p.lineJoinStyle = .round
    p.lineCapStyle = .round
    let shadow = NSShadow()
    shadow.shadowColor = gold.withAlphaComponent(0.8)
    shadow.shadowBlurRadius = s * 0.04
    shadow.set()
    gold.setStroke()
    p.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
