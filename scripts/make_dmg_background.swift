// Draws the DMG window's background at 1x and 2x into Packaging/dmg-background.png and
// dmg-background@2x.png. dmgbuild finds the @2x file beside the 1x one and combines them into a
// HiDPI TIFF. Run from the repository root: swift scripts/make_dmg_background.swift
//
// Coordinates are in points on the 640 × 400 window, origin at the top left. The icon centers
// match the icon_locations in Packaging/dmg_settings.py.
//
// Finder draws the icon labels in its own text color, black in light mode and white in dark mode,
// over this fixed image. The ground is a mid-tone gray so both stay readable.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let size = CGSize(width: 640, height: 400)
let appCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 470, y: 190)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawBackground(scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    // Sized in points, so the 2x file is tagged 144 dpi and the context already maps points to
    // pixels. Only the flip to a top-left origin is left to do.
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // Ground: a cool mid-gray, a shade lighter at the top, like the review window's stage under light.
    let ground = CGGradient(colorsSpace: sRGB, colors: [color(0x8C9099), color(0x6E727A)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(ground, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // A soft pool of light under each icon, kept faint so the labels below keep their contrast.
    let pool = CGGradient(colorsSpace: sRGB, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    for center in [appCenter, applicationsCenter] {
        context.drawRadialGradient(pool, startCenter: center, startRadius: 0, endCenter: center, endRadius: 115, options: [])
    }

    // The arrow: a shallow arc from the app to Applications, ending in an open arrowhead that
    // follows the curve's direction.
    let start = CGPoint(x: 258, y: 196)
    let end = CGPoint(x: 384, y: 196)
    let control = CGPoint(x: 321, y: 152)
    let angle = atan2(end.y - control.y, end.x - control.x)
    let head: CGFloat = 13
    let spread: CGFloat = .pi / 5
    let arrow = CGMutablePath()
    arrow.move(to: start)
    arrow.addQuadCurve(to: end, control: control)
    arrow.move(to: CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread)))
    arrow.addLine(to: end)
    arrow.addLine(to: CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread)))

    context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: color(0x000000, 0.3))
    context.addPath(arrow)
    context.setStrokeColor(color(0xFFFFFF, 0.92))
    context.setLineWidth(3.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(1, "dmg-background.png"), (2, "dmg-background@2x.png")] {
    let url = root.appendingPathComponent("Packaging/\(name)")
    try drawBackground(scale: scale).representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}
