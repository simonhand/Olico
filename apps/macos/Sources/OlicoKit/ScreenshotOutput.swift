import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotOutputError: LocalizedError, Equatable {
    case encodeFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .encodeFailed: return "无法编码截图"
        case .writeFailed: return "无法写入截图文件"
        }
    }
}

public enum ScreenshotFileWriter {
    public static let defaultDirectory = "~/Pictures/Olico"

    public static func fileName(for date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Olico_\(formatter.string(from: date)).png"
    }

    public static func directoryURL(for saveDir: String) -> URL {
        let trimmed = saveDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? defaultDirectory : trimmed
        return URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    @discardableResult
    public static func save(
        _ image: CGImage,
        directory: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> URL {
        let directoryURL = directoryURL(for: directory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent(fileName(for: date, timeZone: timeZone))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotOutputError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotOutputError.writeFailed
        }
        return url
    }

    public static func pngData(_ image: CGImage) -> Data? {
        encode(image, as: .png)
    }

    public static func tiffData(_ image: CGImage) -> Data? {
        encode(image, as: .tiff)
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
