import CoreGraphics
import XCTest
@testable import OlicoKit

final class AnnotationTests: XCTestCase {
    func testRenderWithoutAnnotationsReturnsOriginalImage() throws {
        let image = try makeSolid(width: 20, height: 20, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let rendered = AnnotationRenderer.render(
            image,
            imageFrame: CGRect(x: 0, y: 0, width: 20, height: 20),
            annotations: []
        )
        XCTAssertTrue(rendered === image)
    }

    func testPenMapsViewCoordinatesIntoImageFrame() throws {
        let image = try makeSolid(width: 200, height: 200, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let rendered = AnnotationRenderer.render(
            image,
            imageFrame: CGRect(x: 20, y: 30, width: 100, height: 100),
            annotations: [Annotation(kind: .pen(points: [
                CGPoint(x: 40, y: 50),
                CGPoint(x: 90, y: 50),
            ]))]
        )

        let onLine = color(of: rendered, x: 90, y: 159)
        XCTAssertGreaterThan(onLine.red, 200)
        XCTAssertLessThan(onLine.green, 120)

        let offLine = color(of: rendered, x: 90, y: 140)
        XCTAssertGreaterThan(offLine.blue, 200)
        XCTAssertLessThan(offLine.red, 60)

        let untouched = color(of: rendered, x: 10, y: 10)
        XCTAssertGreaterThan(untouched.blue, 200)
    }

    func testArrowDrawsShaftAndHead() throws {
        let image = try makeSolid(width: 200, height: 200, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let rendered = AnnotationRenderer.render(
            image,
            imageFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
            annotations: [Annotation(kind: .arrow(
                start: CGPoint(x: 20, y: 20),
                end: CGPoint(x: 120, y: 120)
            ))]
        )

        let shaft = color(of: rendered, x: 70, y: 129)
        XCTAssertGreaterThan(shaft.red, 200)
        XCTAssertLessThan(shaft.green, 120)

        let head = color(of: rendered, x: 116, y: 82)
        XCTAssertGreaterThan(head.red, 200)

        let untouched = color(of: rendered, x: 10, y: 10)
        XCTAssertGreaterThan(untouched.blue, 200)
    }

    func testMosaicPixelatesInsideStrokeOnly() throws {
        let original = try makeChecker(size: 64, cell: 2)
        let points = [CGPoint(x: 10, y: 32), CGPoint(x: 54, y: 32)]
        let rendered = AnnotationRenderer.render(
            original,
            imageFrame: CGRect(x: 0, y: 0, width: 64, height: 64),
            annotations: [Annotation(kind: .mosaic(points: points))]
        )

        let firstInside = color(of: rendered, x: 21, y: 30)
        let secondInside = color(of: rendered, x: 22, y: 30)
        XCTAssertEqual(firstInside.red, secondInside.red)
        XCTAssertEqual(firstInside.green, secondInside.green)
        XCTAssertEqual(firstInside.blue, secondInside.blue)

        let originalLeft = color(of: original, x: 21, y: 30)
        let originalRight = color(of: original, x: 22, y: 30)
        XCTAssertNotEqual(originalLeft.red, originalRight.red)

        let outside = color(of: rendered, x: 20, y: 5)
        let originalOutside = color(of: original, x: 20, y: 5)
        XCTAssertEqual(outside.red, originalOutside.red)
        XCTAssertEqual(outside.green, originalOutside.green)
        XCTAssertEqual(outside.blue, originalOutside.blue)
    }

    func testPixelatedProducesImage() throws {
        let image = try makeChecker(size: 32, cell: 4)
        let pixelated = try XCTUnwrap(AnnotationRenderer.pixelated(image))
        XCTAssertEqual(pixelated.width, 32)
        XCTAssertEqual(pixelated.height, 32)
    }

    private func makeSolid(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeChecker(size: Int, cell: Int) throws -> CGImage {
        let context = try makeContext(width: size, height: size)
        for y in stride(from: 0, to: size, by: cell) {
            for x in stride(from: 0, to: size, by: cell) {
                let isWhite = ((x / cell) + (y / cell)) % 2 == 0
                context.setFillColor(isWhite
                    ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                    : CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func color(of image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return (0, 0, 0)
        }
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        pointer.initialize(repeating: 0, count: 4)
        defer {
            pointer.deinitialize(count: 4)
            pointer.deallocate()
        }
        guard let context = CGContext(
            data: pointer,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0, 0)
        }
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pointer[0]), Int(pointer[1]), Int(pointer[2]))
    }
}
