import CoreGraphics

/// Where the measurement grid draws its lines. Positions are global screen coordinates in points,
/// measured from the top left of the primary display, so every display's lines fall on the same
/// multiples and a label reads the same number an agent passes back as a selection.
public enum ScreenGrid {
    public static let defaultSpacing = 100
    public static let minimumSpacing = 25

    /// Every multiple of `spacing` in `lower..<upper`. Displays left of or above the primary one
    /// have negative coordinates, which are lined up the same way.
    public static func lines(from lower: CGFloat, to upper: CGFloat, spacing: Int) -> [Int] {
        guard spacing > 0, upper > lower else { return [] }
        let first = Int((lower / CGFloat(spacing)).rounded(.up)) * spacing
        return Array(stride(from: first, to: Int(upper.rounded(.up)), by: spacing))
    }

    /// Lines worth a coordinate label. Labels need about 100 points between them to stay legible,
    /// so a fine grid labels only every few lines.
    public static func isLabeled(_ value: Int, spacing: Int) -> Bool {
        let every = max(1, Int((100.0 / Double(spacing)).rounded(.up)))
        return value % (spacing * every) == 0
    }

    /// Lines drawn heavier, so distances can be counted at a glance.
    public static func isMajor(_ value: Int, spacing: Int) -> Bool {
        value % (spacing * 5) == 0
    }
}
