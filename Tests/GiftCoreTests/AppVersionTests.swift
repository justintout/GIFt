import Foundation
@testable import GiftCore
import XCTest

final class AppVersionTests: XCTestCase {
    func testComparesNumerically() throws {
        let september = try XCTUnwrap(AppVersion("2026.9.3"))
        let october = try XCTUnwrap(AppVersion("v2026.10.1"))
        XCTAssertLessThan(september, october)
        XCTAssertEqual(october.description, "2026.10.1")
        XCTAssertNil(AppVersion("2026.10"))
        XCTAssertNil(AppVersion("2026.10.1-beta"))
    }

    func testDecodesGitHubLatestRelease() throws {
        let json = #"{"tag_name": "v2026.11.2", "html_url": "https://github.com/justintout/GIFt/releases/tag/v2026.11.2", "assets": []}"#
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, AppVersion("2026.11.2"))
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/justintout/GIFt/releases/tag/v2026.11.2")
    }
}
