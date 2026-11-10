import CoreGraphics
import ImageIO
import XCTest
@testable import OlicoKit

final class ScreenshotOutputTests: XCTestCase {
    func testFileNameMatchesSpec() {
        let date = Date(timeIntervalSince1970: 0)
        let name = ScreenshotFileWriter.fileName(
            for: date,
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(name, "Olico_1970-01-01_00-00-00.png")
    }

    func testDirectoryExpandsTildeAndFallsBack() {
        XCTAssertEqual(
            ScreenshotFileWriter.directoryURL(for: "~/Pictures/Olico").path,
            ("~/Pictures/Olico" as NSString).expandingTildeInPath
        )
        XCTAssertEqual(
            ScreenshotFileWriter.directoryURL(for: "  ").path,
            ("~/Pictures/Olico" as NSString).expandingTildeInPath
        )
    }

    func testSaveCreatesDirectoryAndWritesPNG() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olico-shot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("shots").path

        let url = try ScreenshotFileWriter.save(
            try makeImage(width: 2, height: 2),
            directory: directory,
            date: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "Olico_1970-01-01_00-00-00.png")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testPNGAndTIFFEncodersProduceMagicBytes() throws {
        let image = try makeImage(width: 2, height: 2)
        let png = try XCTUnwrap(ScreenshotFileWriter.pngData(image))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let tiff = try XCTUnwrap(ScreenshotFileWriter.tiffData(image))
        let header = Array(tiff.prefix(4))
        XCTAssertTrue(header == [0x49, 0x49, 0x2A, 0x00] || header == [0x4D, 0x4D, 0x00, 0x2A])
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
