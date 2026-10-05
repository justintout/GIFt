import Foundation

/// A calendar version, `YYYY.M.N`. Compared number by number, because a string comparison would
/// put 2026.9.3 after 2026.10.1.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    /// Accepts an optional leading "v", so a release tag parses directly. Anything else, such as
    /// a prerelease suffix, is rejected rather than guessed at.
    public init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) ? Int(part) : nil }
        guard parts.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        components = numbers
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// The parts of GitHub's "latest release" response that the update check uses.
public struct LatestRelease: Decodable, Sendable {
    public let version: AppVersion
    /// The release's page, with its notes and the disk image.
    public let pageURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tagName)
        guard let version = AppVersion(tag) else {
            throw DecodingError.dataCorruptedError(forKey: .tagName, in: container, debugDescription: "'\(tag)' is not a YYYY.M.N version")
        }
        self.version = version
        pageURL = try container.decode(URL.self, forKey: .htmlURL)
    }
}
