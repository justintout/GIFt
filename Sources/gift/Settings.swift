import AppKit

struct Settings: Codable {
    static let allowedFrameRates = [8, 10, 12, 15, 24, 30]
    static let defaultFrameRate = 12
    /// Bumped when a release adds a first-run step that existing installs also need to see.
    static let currentInitialSetupVersion = 1

    var outputDirectory: URL
    var autoStartAfterSelection: Bool
    var bringWindowToFront: Bool
    var reviewBeforeSaving: Bool
    var highlightClicks: Bool
    var stopShortcut: KeyboardShortcut
    var defaultFPS: Int
    var indicatorStyle: IndicatorStyle
    var initialSetupVersion: Int

    var hasCompletedInitialSetup: Bool {
        get { initialSetupVersion >= Self.currentInitialSetupVersion }
        set { initialSetupVersion = newValue ? Self.currentInitialSetupVersion : 0 }
    }

    static let standard = Settings(
        outputDirectory: FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser,
        autoStartAfterSelection: true,
        bringWindowToFront: true,
        reviewBeforeSaving: true,
        highlightClicks: true,
        stopShortcut: .default,
        defaultFPS: defaultFrameRate,
        indicatorStyle: .default,
        initialSetupVersion: 0
    )

    enum CodingKeys: String, CodingKey {
        case outputDirectory
        case autoStartAfterSelection
        case bringWindowToFront
        case reviewBeforeSaving
        case highlightClicks
        case stopShortcut
        case defaultFPS
        case indicatorStyle
        case initialSetupVersion
    }

    private static let defaultsKey = "gift.settings"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .standard
        }
        return stored.sanitized()
    }

    static func save(_ settings: Settings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            settingsLog.error("unable to encode settings; keeping the previous values")
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Decoding skips the initializers that apply these limits, so re-apply them to anything
    /// that came off disk.
    private func sanitized() -> Settings {
        var settings = self
        if !Self.allowedFrameRates.contains(settings.defaultFPS) {
            settings.defaultFPS = Self.defaultFrameRate
        }
        settings.indicatorStyle = settings.indicatorStyle.clamped()
        return settings
    }
}

extension Settings {
    /// Decoded a field at a time so a setting added in a later release cannot invalidate the whole
    /// blob. A synthesized `Decodable` throws on a missing key, which would reset every existing
    /// user's settings — including the output folder — the first time a field was added. Every
    /// field below is therefore optional here, not just newly added ones, so forgetting to make a
    /// future field optional cannot reintroduce that.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings.standard

        func value<T: Decodable>(_ key: CodingKeys, or use: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? use
        }

        self.init(
            outputDirectory: value(.outputDirectory, or: fallback.outputDirectory),
            autoStartAfterSelection: value(.autoStartAfterSelection, or: fallback.autoStartAfterSelection),
            bringWindowToFront: value(.bringWindowToFront, or: fallback.bringWindowToFront),
            reviewBeforeSaving: value(.reviewBeforeSaving, or: fallback.reviewBeforeSaving),
            highlightClicks: value(.highlightClicks, or: fallback.highlightClicks),
            stopShortcut: value(.stopShortcut, or: fallback.stopShortcut),
            defaultFPS: value(.defaultFPS, or: fallback.defaultFPS),
            indicatorStyle: value(.indicatorStyle, or: fallback.indicatorStyle),
            initialSetupVersion: value(.initialSetupVersion, or: 0)
        )
    }
}

struct IndicatorStyle: Codable, Equatable {
    static let fillOpacityRange: ClosedRange<CGFloat> = 0...0.4
    static let borderWidthRange: ClosedRange<CGFloat> = 1...8

    static let defaultColor = NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
    static let `default` = IndicatorStyle(color: defaultColor, fillOpacity: 0.08, borderWidth: 2)

    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var fillOpacity: CGFloat
    var borderWidth: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, fillOpacity: CGFloat, borderWidth: CGFloat) {
        self.red = red.clamped(to: 0...1)
        self.green = green.clamped(to: 0...1)
        self.blue = blue.clamped(to: 0...1)
        self.fillOpacity = fillOpacity.clamped(to: Self.fillOpacityRange)
        self.borderWidth = borderWidth.clamped(to: Self.borderWidthRange)
    }

    init(color: NSColor, fillOpacity: CGFloat, borderWidth: CGFloat) {
        let srgb = color.usingColorSpace(.sRGB) ?? Self.defaultColor
        self.init(
            red: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent,
            fillOpacity: fillOpacity,
            borderWidth: borderWidth
        )
    }

    var color: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    func clamped() -> IndicatorStyle {
        IndicatorStyle(red: red, green: green, blue: blue, fillOpacity: fillOpacity, borderWidth: borderWidth)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
