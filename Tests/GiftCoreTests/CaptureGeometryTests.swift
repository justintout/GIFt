import CoreGraphics
import GiftCore
import XCTest

final class CaptureGeometryTests: XCTestCase {
    func testRetinaDisplayUsesPointSourceRectAndPixelOutputSize() throws {
        let display = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pointPixelScale: 2
        )

        let geometry = try CaptureGeometryCalculator.geometry(
            for: CGRect(x: 100, y: 200, width: 300, height: 150),
            on: display
        )

        XCTAssertEqual(geometry.selectionRect, CGRect(x: 100, y: 200, width: 300, height: 150))
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 100, y: 550, width: 300, height: 150))
        XCTAssertEqual(geometry.outputWidth, 600)
        XCTAssertEqual(geometry.outputHeight, 300)
    }

    func testDisplayToTheLeftUsesLocalDisplayCoordinates() throws {
        let display = DisplayGeometry(
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            pointPixelScale: 1
        )

        let geometry = try CaptureGeometryCalculator.geometry(
            for: CGRect(x: -1820, y: 100, width: 640, height: 360),
            on: display
        )

        XCTAssertEqual(geometry.sourceRect, CGRect(x: 100, y: 620, width: 640, height: 360))
        XCTAssertEqual(geometry.outputWidth, 640)
        XCTAssertEqual(geometry.outputHeight, 360)
    }

    func testDisplayAbovePrimaryUsesOwningDisplayOrigin() throws {
        let display = DisplayGeometry(
            frame: CGRect(x: 0, y: 900, width: 1280, height: 720),
            pointPixelScale: 2
        )

        let geometry = try CaptureGeometryCalculator.geometry(
            for: CGRect(x: 50, y: 1000, width: 400, height: 225),
            on: display
        )

        XCTAssertEqual(geometry.sourceRect, CGRect(x: 50, y: 395, width: 400, height: 225))
        XCTAssertEqual(geometry.outputWidth, 800)
        XCTAssertEqual(geometry.outputHeight, 450)
    }

    func testSelectionIsClippedToDisplayBeforeSizing() throws {
        let display = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 2
        )

        let geometry = try CaptureGeometryCalculator.geometry(
            for: CGRect(x: -10, y: 90, width: 30, height: 30),
            on: display
        )

        XCTAssertEqual(geometry.selectionRect, CGRect(x: 0, y: 90, width: 20, height: 10))
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertEqual(geometry.outputWidth, 40)
        XCTAssertEqual(geometry.outputHeight, 20)
    }

    func testFractionalSelectionExpandsToWholePixels() throws {
        let display = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 2
        )

        let geometry = try CaptureGeometryCalculator.geometry(
            for: CGRect(x: 10.25, y: 20.25, width: 10.25, height: 10.25),
            on: display
        )

        XCTAssertEqual(geometry.sourceRect, CGRect(x: 10, y: 69.5, width: 10.5, height: 10.5))
        XCTAssertEqual(geometry.outputWidth, 21)
        XCTAssertEqual(geometry.outputHeight, 21)
    }
}
