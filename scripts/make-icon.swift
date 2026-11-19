import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = output.appendingPathComponent("Studio.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let icon = NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { _ in
    NSColor(red: 0.957, green: 0.949, blue: 0.933, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210).fill()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 52, y: 10)); path.line(to: NSPoint(x: 25, y: 10))
    path.curve(to: NSPoint(x: 12, y: 23), controlPoint1: NSPoint(x: 17, y: 10), controlPoint2: NSPoint(x: 12, y: 15))
    path.line(to: NSPoint(x: 12, y: 41))
    path.curve(to: NSPoint(x: 25, y: 54), controlPoint1: NSPoint(x: 12, y: 49), controlPoint2: NSPoint(x: 17, y: 54))
    path.line(to: NSPoint(x: 52, y: 54))
    path.move(to: NSPoint(x: 50, y: 22)); path.line(to: NSPoint(x: 34, y: 22))
    path.curve(to: NSPoint(x: 28, y: 28), controlPoint1: NSPoint(x: 30, y: 22), controlPoint2: NSPoint(x: 28, y: 24))
    path.curve(to: NSPoint(x: 34, y: 34), controlPoint1: NSPoint(x: 28, y: 32), controlPoint2: NSPoint(x: 30, y: 34))
    path.line(to: NSPoint(x: 42, y: 34))
    path.curve(to: NSPoint(x: 48, y: 40), controlPoint1: NSPoint(x: 46, y: 34), controlPoint2: NSPoint(x: 48, y: 36))
    path.curve(to: NSPoint(x: 42, y: 46), controlPoint1: NSPoint(x: 48, y: 44), controlPoint2: NSPoint(x: 46, y: 46))
    path.line(to: NSPoint(x: 26, y: 46))
    let transform = NSAffineTransform(); transform.translateX(by: 128, yBy: 128); transform.scale(by: 12); path.transform(using: transform as AffineTransform)
    path.lineWidth = 72; path.lineCapStyle = .round; path.lineJoinStyle = .round
    NSColor(red: 0.592, green: 0.349, blue: 0.125, alpha: 1).setStroke(); path.stroke()
    return true
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: destination.appendingPathComponent(filename))
        if pixels == 1024 { try data.write(to: output.appendingPathComponent("Studio.png")) }
    }
}
