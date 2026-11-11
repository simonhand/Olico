import CoreGraphics
import XCTest
@testable import OlicoKit

final class ColorSamplerTests: XCTestCase {
    func testPixelPointFlipsYAndScales() {
        let point = ColorSampler.pixelPoint(
            for: CGPoint(x: 50, y: 75),
            in: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(point?.x, 100)
        XCTAssertEqual(point?.y, 49)
    }

    func testPixelPointMapsFrameOriginToTopLeftPixel() {
        let point = ColorSampler.pixelPoint(
            for: CGPoint(x: 20, y: 30),
            in: CGRect(x: 20, y: 30, width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(point?.x, 0)
        XCTAssertEqual(point?.y, 199)
    }

    func testPixelPointClampsToImageBounds() {
        let frame = CGRect(x: 20, y: 30, width: 100, height: 100)
        let size = CGSize(width: 200, height: 200)
        let below = ColorSampler.pixelPoint(for: CGPoint(x: -100, y: -100), in: frame, imageSize: size)
        XCTAssertEqual(below?.x, 0)
        XCTAssertEqual(below?.y, 199)
        let above = ColorSampler.pixelPoint(for: CGPoint(x: 500, y: 500), in: frame, imageSize: size)
        XCTAssertEqual(above?.x, 199)
        XCTAssertEqual(above?.y, 0)
    }

    func testSampleReadsTopLeftPixelOrder() throws {
        let image = try makeQuadImage()
        XCTAssertEqual(
            ColorSampler.sample(image, at: (x: 5, y: 5)),
            SampledColor(red: 255, green: 0, blue: 0)
        )
        XCTAssertEqual(
            ColorSampler.sample(image, at: (x: 15, y: 5)),
            SampledColor(red: 0, green: 255, blue: 0)
        )
        XCTAssertEqual(
            ColorSampler.sample(image, at: (x: 5, y: 15)),
            SampledColor(red: 0, green: 0, blue: 255)
        )
        XCTAssertEqual(
            ColorSampler.sample(image, at: (x: 15, y: 15)),
            SampledColor(red: 255, green: 255, blue: 255)
        )
    }

    func testSampleOutOfBoundsReturnsNil() throws {
        let image = try makeQuadImage()
        XCTAssertNil(ColorSampler.sample(image, at: (x: -1, y: 0)))
        XCTAssertNil(ColorSampler.sample(image, at: (x: 0, y: 20)))
    }

    func testCropClampsToImageEdges() throws {
        let image = try makeImage(width: 64, height: 64)
        let center = try XCTUnwrap(ColorSampler.crop(image, around: (x: 32, y: 32), radius: 5))
        XCTAssertEqual(center.originX, 27)
        XCTAssertEqual(center.originY, 27)
        XCTAssertEqual(center.image.width, 11)
        XCTAssertEqual(center.image.height, 11)

        let corner = try XCTUnwrap(ColorSampler.crop(image, around: (x: 0, y: 0), radius: 5))
        XCTAssertEqual(corner.originX, 0)
        XCTAssertEqual(corner.originY, 0)
        XCTAssertEqual(corner.image.width, 11)
        XCTAssertEqual(corner.image.height, 11)

        let far = try XCTUnwrap(ColorSampler.crop(image, around: (x: 63, y: 63), radius: 5))
        XCTAssertEqual(far.originX, 53)
        XCTAssertEqual(far.originY, 53)
    }

    func testHexRGBAndHSLFormatting() {
        let color = SampledColor(red: 255, green: 59, blue: 48)
        XCTAssertEqual(ColorText.hex(color), "#FF3B30")
        XCTAssertEqual(ColorText.rgb(color), "rgb(255, 59, 48)")
        XCTAssertEqual(ColorText.hsl(color), "hsl(3, 100%, 59%)")
        XCTAssertEqual(ColorText.string(color, format: .hex), "#FF3B30")
        XCTAssertEqual(ColorText.string(color, format: .rgb), "rgb(255, 59, 48)")
        XCTAssertEqual(ColorText.string(color, format: .hsl), "hsl(3, 100%, 59%)")
    }

    func testHSLForGray() {
        let gray = SampledColor(red: 128, green: 128, blue: 128)
        XCTAssertEqual(ColorText.hsl(gray), "hsl(0, 0%, 50%)")
        let black = SampledColor(red: 0, green: 0, blue: 0)
        XCTAssertEqual(ColorText.hsl(black), "hsl(0, 0%, 0%)")
    }

    private func makeQuadImage() throws -> CGImage {
        let context = try XCTUnwrap(makeContext(width: 20, height: 20))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 10, width: 10, height: 10))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 10, height: 10))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(makeContext(width: width, height: height))
        context.setFillColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
