// Draws GIFt's app icon (the "Gift Stack" design in the Paper and Teal palette) at every size
// macOS asks for and packs them into Packaging/AppIcon.icns.
// Run from the repository root: swift scripts/make_icon.swift
//
// Coordinates are on a 1024-point canvas with the origin at the top left, matching the SVG the
// design came from. Small sizes are simplified on purpose, the way system icons are: at 32 pixels
// the rearmost frame and the bow go and the ring thickens, and at 16 only the front frame remains,
// centered and enlarged, with a ring at least a pixel wide.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("GIFt-\(UUID().uuidString).iconset")
let output = root.appendingPathComponent("Packaging/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Palette {
    static let tileTop = color(0xFCF6EA)
    static let tileBottom = color(0xEADBBE)
    static let back = color(0xDCC9A6)
    static let backRibbon = color(0xECDFC6)
    static let middle = color(0xC4AC84)
    static let middleRibbon = color(0xD8C5A3)
    static let front = color(0x1C8C8C)
    static let ribbon = color(0xFF7A5C)
    static let knot = color(0xE25C3E)
    static let ring = color(0xFFF7EA)
    static let dot = color(0xFF6A48)
}

/// The stack at 1.4 times the original frames, with the rear frames tucked in and tilted 3° and
/// 6° so it can fill the tile. Centers were computed so the stack's bounds sit centered on the
/// tile, 32 points inside its rounded edge at the tightest point.
enum Stack {
    static let scale: CGFloat = 1.4
    static let front = CGPoint(x: 487.2, y: 559.1)
    static let middle = (center: CGPoint(x: 514.9, y: 501.4), degrees: CGFloat(3))
    static let back = (center: CGPoint(x: 545.7, y: 470.6), degrees: CGFloat(6))
    static let rearSize = CGSize(width: 644, height: 504)
    static let rearRadius: CGFloat = 56
}

enum Level {
    /// 64 pixels and up.
    case full
    /// 32 pixels.
    case small
    /// 16 pixels.
    case tiny

    init(pixels: Int) {
        self = pixels <= 16 ? .tiny : pixels <= 32 ? .small : .full
    }
}

func fillRoundedRect(_ context: CGContext, _ rect: CGRect, radius: CGFloat, _ fill: CGColor) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(fill)
    context.fillPath()
}

func fill(_ context: CGContext, _ rect: CGRect, _ fill: CGColor) {
    context.setFillColor(fill)
    context.fill(rect)
}

/// A rear frame with its ribbon, rotated about its center.
func drawRear(_ context: CGContext, center: CGPoint, degrees: CGFloat, frame: CGColor, ribbon: CGColor) {
    let size = Stack.rearSize
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: degrees * .pi / 180)
    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    fillRoundedRect(context, rect, radius: Stack.rearRadius, frame)
    let ribbonWidth = 30 * Stack.scale
    fill(context, CGRect(x: -ribbonWidth / 2, y: rect.minY, width: ribbonWidth, height: rect.height), ribbon)
    context.restoreGState()
}

/// A frame tied with a ribbon cross, with the record ring and dot where the ribbons meet.
func drawWrappedFrame(_ context: CGContext, _ rect: CGRect, radius: CGFloat, ribbonWidth: CGFloat, ringRadius: CGFloat, ringWidth: CGFloat, dotRadius: CGFloat) {
    fillRoundedRect(context, rect, radius: radius, Palette.front)
    fill(context, CGRect(x: rect.midX - ribbonWidth / 2, y: rect.minY, width: ribbonWidth, height: rect.height), Palette.ribbon)
    fill(context, CGRect(x: rect.minX, y: rect.midY - ribbonWidth / 2, width: rect.width, height: ribbonWidth), Palette.ribbon)

    let center = CGPoint(x: rect.midX, y: rect.midY)
    let ring = CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
    context.setFillColor(Palette.front)
    context.fillEllipse(in: ring)
    context.setStrokeColor(Palette.ring)
    context.setLineWidth(ringWidth)
    context.strokeEllipse(in: ring)
    context.setFillColor(Palette.dot)
    context.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
}

func drawBow(_ context: CGContext, above top: CGFloat, centerX: CGFloat) {
    let k = Stack.scale
    for side: CGFloat in [-1, 1] {
        context.saveGState()
        context.translateBy(x: centerX + side * 36 * k, y: top - 14 * k)
        context.rotate(by: side * 24 * .pi / 180)
        context.setFillColor(Palette.ribbon)
        context.fillEllipse(in: CGRect(x: -42 * k, y: -24 * k, width: 84 * k, height: 48 * k))
        context.restoreGState()
    }
    context.setFillColor(Palette.knot)
    context.fillEllipse(in: CGRect(x: centerX - 15 * k, y: top - 17 * k, width: 30 * k, height: 30 * k))
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let level = Level(pixels: pixels)
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

    // Tile: a paper gradient squircle on Apple's icon grid, with a soft drop shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: color(0x000000, 0.28))
    context.addPath(tile)
    context.setFillColor(Palette.tileBottom)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Palette.tileTop, Palette.tileBottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    context.restoreGState()

    let k = Stack.scale
    switch level {
    case .tiny:
        let width: CGFloat = 760
        let unit = width / 640
        let rect = CGRect(x: 512 - width / 2, y: 512 - width * 0.375, width: width, height: width * 0.75)
        drawWrappedFrame(context, rect, radius: 64 * unit, ribbonWidth: 84 * unit, ringRadius: 150 * unit, ringWidth: 72 * unit, dotRadius: 70 * unit)
    case .small, .full:
        if level == .full {
            drawRear(context, center: Stack.back.center, degrees: Stack.back.degrees, frame: Palette.back, ribbon: Palette.backRibbon)
        }
        drawRear(context, center: Stack.middle.center, degrees: Stack.middle.degrees, frame: Palette.middle, ribbon: Palette.middleRibbon)
        let front = CGRect(x: Stack.front.x - 250 * k, y: Stack.front.y - 195 * k, width: 500 * k, height: 390 * k)
        let full = level == .full
        drawWrappedFrame(context, front, radius: 44 * k, ribbonWidth: (full ? 56 : 70) * k, ringRadius: 112 * k,
                         ringWidth: (full ? 34 : 52) * k, dotRadius: (full ? 50 : 58) * k)
        if full {
            drawBow(context, above: front.minY, centerX: front.midX)
        }
    }

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
