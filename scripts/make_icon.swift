// Draws GIFt's app icon (the "Frame stack" design) at every size macOS asks for and packs them into
// Packaging/AppIcon.icns. Run from the repository root: swift scripts/make_icon.swift
//
// Coordinates are on a 1024-point canvas with the origin at the top left, matching the SVG the
// design came from. Small sizes are simplified on purpose, the way system icons are: at 32
// pixels the rearmost frame goes and the ring thickens, and at 16 only the front frame remains,
// centered and enlarged, with a ring at least a pixel wide.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("GIFt-\(UUID().uuidString).iconset")
let output = root.appendingPathComponent("Packaging/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillRotated(_ context: CGContext, rect: CGRect, radius: CGFloat, degrees: CGFloat, around center: CGPoint, fill: CGColor) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: degrees * .pi / 180)
    context.translateBy(x: -center.x, y: -center.y)
    context.addPath(roundedRect(rect, radius: radius))
    context.setFillColor(fill)
    context.fillPath()
    context.restoreGState()
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let simple = pixels <= 32
    let tiny = pixels <= 16
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    // Flip to the SVG's top-left origin and scale the 1024 canvas to the target size.
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    // Tile: a light gradient squircle on Apple's icon grid, with a soft drop shadow.
    let tile = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: color(0x000000, 0.28))
    context.addPath(tile)
    context.setFillColor(color(0xE6E9EE))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xF7F8FA), color(0xD5D9E0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    context.restoreGState()

    // Frames behind the front one.
    if !simple {
        fillRotated(context, rect: CGRect(x: 330, y: 230, width: 460, height: 360), radius: 40, degrees: 8, around: CGPoint(x: 560, y: 410), fill: color(0xB9BEC8))
    }
    if !tiny {
        fillRotated(context, rect: CGRect(x: 290, y: 270, width: 460, height: 360), radius: 40, degrees: 4, around: CGPoint(x: 520, y: 450), fill: color(0x8E95A3))
    }

    // Front frame with the record ring.
    let front = tiny ? CGRect(x: 192, y: 272, width: 640, height: 480) : CGRect(x: 234, y: 330, width: 500, height: 390)
    context.addPath(roundedRect(front, radius: tiny ? 64 : 44))
    context.setFillColor(color(0x232428))
    context.fillPath()
    let ringCenter = CGPoint(x: front.midX, y: front.midY)
    let ringRadius: CGFloat = tiny ? 150 : 112
    context.setStrokeColor(color(0xF5F5F7))
    context.setLineWidth(tiny ? 72 : simple ? 52 : 34)
    context.strokeEllipse(in: CGRect(x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
    let dot: CGFloat = tiny ? 70 : simple ? 58 : 50
    context.setFillColor(color(0xFF3B30))
    context.fillEllipse(in: CGRect(x: ringCenter.x - dot, y: ringCenter.y - dot, width: dot * 2, height: dot * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = drawIcon(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(output.path)")
