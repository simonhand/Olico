import CoreGraphics
import Foundation

public struct SampledColor: Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum ColorSampler {
    /// Maps a view point (bottom-left origin) to a top-left-origin pixel coordinate.
    public static func pixelPoint(
        for point: CGPoint,
        in frame: CGRect,
        imageSize: CGSize
    ) -> (x: Int, y: Int)? {
        guard frame.width > 0, frame.height > 0,
              imageSize.width >= 1, imageSize.height >= 1
        else { return nil }
        let scaleX = imageSize.width / frame.width
        let scaleY = imageSize.height / frame.height
        let x = Int(((point.x - frame.minX) * scaleX).rounded(.down))
        let flippedY = Int(((point.y - frame.minY) * scaleY).rounded(.down))
        let width = Int(imageSize.width)
        let height = Int(imageSize.height)
        return (
            x: min(max(x, 0), width - 1),
            y: min(max(height - 1 - flippedY, 0), height - 1)
        )
    }

    public static func sample(_ image: CGImage, at pixel: (x: Int, y: Int)) -> SampledColor? {
        guard pixel.x >= 0, pixel.y >= 0,
              pixel.x < image.width, pixel.y < image.height
        else { return nil }
        guard let cropped = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return SampledColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }

    public static func sample(
        _ image: CGImage,
        viewPoint: CGPoint,
        imageFrame: CGRect
    ) -> (pixel: (x: Int, y: Int), color: SampledColor)? {
        guard let pixel = pixelPoint(
            for: viewPoint,
            in: imageFrame,
            imageSize: CGSize(width: image.width, height: image.height)
        ), let color = sample(image, at: pixel) else { return nil }
        return (pixel, color)
    }

    public static func crop(
        _ image: CGImage,
        around pixel: (x: Int, y: Int),
        radius: Int
    ) -> (image: CGImage, originX: Int, originY: Int)? {
        guard radius >= 0, image.width >= 1, image.height >= 1 else { return nil }
        let side = radius * 2 + 1
        let width = min(side, image.width)
        let height = min(side, image.height)
        let originX = min(max(pixel.x - radius, 0), image.width - width)
        let originY = min(max(pixel.y - radius, 0), image.height - height)
        guard let cropped = image.cropping(to: CGRect(
            x: originX,
            y: originY,
            width: width,
            height: height
        )) else { return nil }
        return (cropped, originX, originY)
    }
}

public enum ColorText {
    public static func hex(_ color: SampledColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }

    public static func rgb(_ color: SampledColor) -> String {
        "rgb(\(color.red), \(color.green), \(color.blue))"
    }

    public static func hsl(_ color: SampledColor) -> String {
        let r = Double(color.red) / 255
        let g = Double(color.green) / 255
        let b = Double(color.blue) / 255
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let lightness = (maximum + minimum) / 2
        var hue = 0.0
        var saturation = 0.0
        if maximum != minimum {
            let delta = maximum - minimum
            saturation = lightness > 0.5
                ? delta / (2 - maximum - minimum)
                : delta / (maximum + minimum)
            switch maximum {
            case r:
                hue = (g - b) / delta + (g < b ? 6 : 0)
            case g:
                hue = (b - r) / delta + 2
            default:
                hue = (r - g) / delta + 4
            }
            hue *= 60
        }
        let h = Int(hue.rounded()) % 360
        return "hsl(\(h), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
    }

    public static func string(_ color: SampledColor, format: ColorFormat) -> String {
        switch format {
        case .hex: return hex(color)
        case .rgb: return rgb(color)
        case .hsl: return hsl(color)
        }
    }
}
