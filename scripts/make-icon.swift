// Draws Panefold's app icon to a 1024×1024 PNG. Same drawing as AppIcon.image(.panefold) in the app.
//
//     swift scripts/make-icon.swift build/icon-1024.png
import AppKit

func color(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
}

let size: CGFloat = 1024
let image = NSImage(size: CGSize(width: size, height: size), flipped: true) { rect in
    let inset = rect.width * 0.09
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.225
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(colors: [color(0x1E2A44), color(0x0E1424)])?.draw(in: path, angle: -90)
    let pad = body.width * 0.14, gap = body.width * 0.045
    let inner = body.insetBy(dx: pad, dy: pad)
    let half = (inner.width - gap) / 2
    let top = (inner.height - gap) * 0.58, bottom = (inner.height - gap) * 0.42
    let panes = [
        CGRect(x: inner.minX, y: inner.minY, width: half, height: inner.height),
        CGRect(x: inner.minX + half + gap, y: inner.minY, width: half, height: top),
        CGRect(x: inner.minX + half + gap, y: inner.minY + top + gap, width: half * 0.56, height: bottom),
        CGRect(x: inner.minX + half + gap + half * 0.56 + gap, y: inner.minY + top + gap, width: half * 0.44 - gap, height: bottom),
    ]
    for (i, r) in panes.enumerated() {
        color([0x5AA9FF, 0x8FD3FF, 0xFFB86B, 0xFF7A85][i]).setFill()
        NSBezierPath(roundedRect: r, xRadius: body.width * 0.05, yRadius: body.width * 0.05).fill()
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
