import Foundation
import GiftCore

/// Asks GitHub for the latest release when the user requests it. Nothing runs in the background,
/// and nothing downloads or installs itself: a newer release is offered as a link to its page.
@MainActor
final class UpdateChecker {
    enum State {
        case idle
        case checking
        case upToDate
        case available(LatestRelease)
        case failed(String)
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/justintout/GIFt/releases/latest")!

    /// Missing only when GIFt runs outside an app bundle, which has no Info.plist.
    let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    private(set) var state: State = .idle {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    func check() {
        if case .checking = state { return }
        state = .checking
        Task {
            state = await fetchState()
        }
    }

    private func fetchState() async -> State {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                let release = try JSONDecoder().decode(LatestRelease.self, from: data)
                if let currentVersion, release.version <= currentVersion {
                    return .upToDate
                }
                return .available(release)
            case 404:
                // GitHub answers 404 until the first release is published.
                return .failed("No releases published yet")
            default:
                appLog.error("update check got an unexpected response: \(String(describing: response), privacy: .public)")
                return .failed("Couldn't reach GitHub")
            }
        } catch {
            appLog.error("update check failed: \(String(describing: error), privacy: .public)")
            return .failed("Couldn't reach GitHub")
        }
    }
}
