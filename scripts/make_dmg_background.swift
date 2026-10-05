// Draws the DMG window's background at 1x and 2x into Packaging/dmg-background.png and
// dmg-background@2x.png. dmgbuild finds the @2x file beside the 1x one and combines them into a
// HiDPI TIFF. Run from the repository root: swift scripts/make_dmg_background.swift
//
// The art is wrapping paper in the icon's colors: cream paper with faint teal pinstripes and coral
// dots, a dashed teal twine from GIFt to Applications with a coral "drag me" tag hanging from it,
// and each label on a teal gift tag.
//
// Coordinates are in points on the 640 × 400 window, origin at the top left. The icon centers
// match the icon_locations in Packaging/dmg_settings.py, and Finder centers each label under its
// icon at about y 266–280.
//
// Finder draws the labels in its own text color, black in light mode and white in dark mode, over
// this fixed image. Only the tags under the labels need to suit both: their teal gives white text
// 4.4:1 and black text 4.7:1.

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let size = CGSize(width: 640, height: 400)
let iconCenters = [CGPoint(x: 170, y: 190), CGPoint(x: 470, y: 190)]
let labelY: CGFloat = 273

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let paper = color(0xFCF6EA), teal = color(0x1C8C8C), coral = color(0xFF7A5C), cream = color(0xFFF7EA)
/// The icon's teal, darkened just enough to keep both label colors readable.
let tagTeal = color(0x178585)

/// Seeded, so every run scatters the dots in the same places.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
}

/// Keeps dots off the icons, their labels, and the twine and its tag.
func isClear(_ point: CGPoint) -> Bool {
    for center in iconCenters where abs(point.x - center.x) < 84 && point.y > center.y - 80 && point.y < labelY + 22 {
        return false
    }
    return !(point.x > 236 && point.x < 404 && point.y > 150 && point.y < 270)
}

func text(_ string: String, at center: CGPoint, size: CGFloat, color: NSColor, in context: CGContext) {
    var font = NSFont.systemFont(ofSize: size, weight: .heavy)
    if let rounded = font.fontDescriptor.withDesign(.rounded) {
        font = NSFont(descriptor: rounded, size: size) ?? font
    }
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let textSize = attributed.size()
    // The context is flipped to a top-left origin, so text needs a flipped AppKit context too.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    attributed.draw(at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()
}

/// A gift tag behind a label: a plate with a pointed end and a punched hole.
func labelTag(_ context: CGContext, center: CGPoint) {
    let rect = CGRect(x: center.x - 58, y: center.y - 12, width: 116, height: 24)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + 12, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 6), control: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 6))
    path.addQuadCurve(to: CGPoint(x: rect.maxX - 6, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + 12, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
    path.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: color(0x000000, 0.18))
    context.addPath(path)
    context.setFillColor(tagTeal)
    context.fillPath()
    context.restoreGState()
    context.setFillColor(cream)
    context.fillEllipse(in: CGRect(x: rect.minX + 8, y: rect.midY - 2.5, width: 5, height: 5))
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

    // Paper with faint diagonal teal pinstripes.
    context.setFillColor(paper)
    context.fill(CGRect(origin: .zero, size: size))
    context.setStrokeColor(color(0x1C8C8C, 0.13))
    context.setLineWidth(6)
    for x in stride(from: -size.height, to: size.width, by: 34) {
        context.move(to: CGPoint(x: x, y: size.height))
        context.addLine(to: CGPoint(x: x + size.height, y: 0))
    }
    context.strokePath()

    // Coral dots, kept clear of everything Finder or the twine draws over.
    var random = SeededRandom(state: 7)
    for _ in 0..<70 {
        let point = CGPoint(x: random.next() * size.width, y: random.next() * size.height)
        let radius = 3 + random.next() * 3
        let alpha: CGFloat = random.next() > 0.5 ? 0.55 : 0.35
        guard isClear(point) else { continue }
        context.setFillColor(color(alpha > 0.5 ? 0xFF7A5C : 0xE25C3E, alpha))
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    // The twine: a slack dashed curve from the gift to the folder, ending in an arrowhead.
    let start = CGPoint(x: 246, y: 176), end = CGPoint(x: 392, y: 176)
    let control1 = CGPoint(x: 290, y: 214), control2 = CGPoint(x: 350, y: 214)
    let twine = CGMutablePath()
    twine.move(to: start)
    twine.addCurve(to: end, control1: control1, control2: control2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(teal)
    context.setLineWidth(2.5)
    context.saveGState()
    context.setLineDash(phase: 0, lengths: [7, 4])
    context.addPath(twine)
    context.strokePath()
    context.restoreGState()
    let angle = atan2(end.y - control2.y, end.x - control2.x)
    let head: CGFloat = 11
    context.move(to: CGPoint(x: end.x - head * cos(angle - .pi / 5), y: end.y - head * sin(angle - .pi / 5)))
    context.addLine(to: end)
    context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 5), y: end.y - head * sin(angle + .pi / 5)))
    context.strokePath()

    // The "drag me" tag, hanging slightly askew from the twine's low point.
    context.saveGState()
    context.translateBy(x: 320, y: 205)
    context.rotate(by: 8 * .pi / 180)
    context.move(to: .zero)
    context.addLine(to: CGPoint(x: 0, y: 14))
    context.setLineWidth(1.5)
    context.strokePath()
    let tag = CGMutablePath()
    tag.move(to: CGPoint(x: -26, y: 22))
    tag.addLine(to: CGPoint(x: -10, y: 14))
    tag.addLine(to: CGPoint(x: 10, y: 14))
    tag.addLine(to: CGPoint(x: 26, y: 22))
    tag.addLine(to: CGPoint(x: 26, y: 54))
    tag.addLine(to: CGPoint(x: -26, y: 54))
    tag.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: color(0x000000, 0.2))
    context.addPath(tag)
    context.setFillColor(coral)
    context.fillPath()
    context.restoreGState()
    context.setFillColor(paper)
    context.fillEllipse(in: CGRect(x: -3, y: 17, width: 6, height: 6))
    text("drag", at: CGPoint(x: 0, y: 32), size: 11, color: NSColor(cgColor: cream)!, in: context)
    text("me", at: CGPoint(x: 0, y: 45), size: 11, color: NSColor(cgColor: cream)!, in: context)
    context.restoreGState()

    for center in iconCenters {
        labelTag(context, center: CGPoint(x: center.x, y: labelY))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(1, "dmg-background.png"), (2, "dmg-background@2x.png")] {
    let url = root.appendingPathComponent("Packaging/\(name)")
    try drawBackground(scale: scale).representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}
