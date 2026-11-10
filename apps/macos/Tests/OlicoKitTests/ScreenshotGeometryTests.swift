import CoreGraphics
import XCTest
@testable import OlicoKit

final class ScreenshotGeometryTests: XCTestCase {
    func testRectNormalizesReverseDrag() {
        let rect = ScreenshotGeometry.rect(
            from: CGPoint(x: 80, y: 90),
            to: CGPoint(x: 20, y: 30)
        )
        XCTAssertEqual(rect, CGRect(x: 20, y: 30, width: 60, height: 60))
    }

    func testClampKeepsRectInsideBounds() {
        let rect = ScreenshotGeometry.clamp(
            CGRect(x: -10, y: -5, width: 30, height: 20),
            to: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 20, height: 15))
    }

    func testClampReturnsEmptyForDisjointRect() {
        let rect = ScreenshotGeometry.clamp(
            CGRect(x: 200, y: 200, width: 20, height: 20),
            to: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertTrue(rect.isEmpty)
    }

    func testPixelCropUsesTopLeftOrigin() {
        let crop = ScreenshotGeometry.pixelCropRect(
            for: CGRect(x: 10, y: 20, width: 30, height: 40),
            viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(crop, CGRect(x: 20, y: 80, width: 60, height: 80))
    }

    func testPixelCropRoundsOutward() {
        let crop = ScreenshotGeometry.pixelCropRect(
            for: CGRect(x: 10.25, y: 20.4, width: 30.3, height: 40.1),
            viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(crop, CGRect(x: 20, y: 79, width: 62, height: 81))
    }

    func testPixelCropClampsToImage() {
        let crop = ScreenshotGeometry.pixelCropRect(
            for: CGRect(x: 95, y: 95, width: 20, height: 20),
            viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(crop, CGRect(x: 190, y: 0, width: 10, height: 10))
    }

    func testPixelCropRejectsTinySelection() {
        XCTAssertNil(ScreenshotGeometry.pixelCropRect(
            for: CGRect(x: 10, y: 10, width: 0.4, height: 20),
            viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200),
            minimum: 1
        ))
    }

    func testHandleHitTest() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            ScreenshotGeometry.handle(at: CGPoint(x: 100, y: 100), in: rect, tolerance: 6),
            .topRight
        )
        XCTAssertEqual(
            ScreenshotGeometry.handle(at: CGPoint(x: 50, y: 100), in: rect, tolerance: 6),
            .top
        )
        XCTAssertEqual(
            ScreenshotGeometry.handle(at: CGPoint(x: 50, y: 50), in: rect, tolerance: 6),
            nil
        )
    }

    func testResizeNormalizesCrossedEdges() {
        let rect = ScreenshotGeometry.resized(
            CGRect(x: 20, y: 20, width: 40, height: 40),
            handle: .topLeft,
            to: CGPoint(x: 80, y: 80),
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 60, y: 20, width: 20, height: 60))
    }

    func testResizeClampsToBounds() {
        let rect = ScreenshotGeometry.resized(
            CGRect(x: 20, y: 20, width: 40, height: 40),
            handle: .bottomRight,
            to: CGPoint(x: 150, y: -20),
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 20, y: 0, width: 80, height: 60))
    }
}
