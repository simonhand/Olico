import CoreGraphics
import CoreImage

public enum AnnotationTool: String, CaseIterable, Equatable {
    case arrow
    case pen
    case mosaic
}

public struct Annotation: Equatable {
    public enum Kind: Equatable {
        case arrow(start: CGPoint, end: CGPoint)
        case pen(points: [CGPoint])
        case mosaic(points: [CGPoint])
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

public enum AnnotationStyle {
    public static let lineWidth: CGFloat = 3
    public static let mosaicWidth: CGFloat = 26
    public static let mosaicBlock: CGFloat = 12
    public static let color = CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
}

public enum AnnotationRenderer {
    private static let ciContext = CIContext(options: nil)

    /// Draws annotations (view coordinates) onto the full bitmap and returns a new image.
    public static func render(
        _ image: CGImage,
        imageFrame: CGRect,
        annotations: [Annotation],
        lineWidth: CGFloat = AnnotationStyle.lineWidth
    ) -> CGImage {
        guard !annotations.isEmpty, imageFrame.width > 0, imageFrame.height > 0 else {
            return image
        }
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scaleX = CGFloat(width) / imageFrame.width
        let scaleY = CGFloat(height) / imageFrame.height
        let scale = min(scaleX, scaleY)
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - imageFrame.minX) * scaleX,
                y: (point.y - imageFrame.minY) * scaleY
            )
        }

        var pixelated: CGImage?
        for annotation in annotations {
            switch annotation.kind {
            case .arrow(let start, let end):
                drawArrow(context, from: map(start), to: map(end), width: lineWidth * scale)
            case .pen(let points):
                drawPen(context, points: points.map(map), width: lineWidth * scale)
            case .mosaic(let points):
                if pixelated == nil {
                    pixelated = pixelatedImage(image)
                }
                if let pixelated {
                    drawMosaic(
                        context,
                        pixelated: pixelated,
                        imageSize: CGSize(width: width, height: height),
                        points: points.map(map),
                        width: AnnotationStyle.mosaicWidth * scale
                    )
                }
            }
        }
        return context.makeImage() ?? image
    }

    public static func pixelated(
        _ image: CGImage,
        block: CGFloat = AnnotationStyle.mosaicBlock
    ) -> CGImage? {
        pixelatedImage(image, block: block)
    }

    private static func pixelatedImage(
        _ image: CGImage,
        block: CGFloat = AnnotationStyle.mosaicBlock
    ) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(block, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private static func drawArrow(
        _ context: CGContext,
        from: CGPoint,
        to: CGPoint,
        width: CGFloat
    ) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 0.5, width > 0 else { return }
        let ux = dx / length
        let uy = dy / length
        let head = min(max(width * 4, length * 0.3), length)
        let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)

        context.setStrokeColor(AnnotationStyle.color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: from)
        context.addLine(to: base)
        context.strokePath()

        let spread = head * 0.45
        let left = CGPoint(x: base.x - uy * spread, y: base.y + ux * spread)
        let right = CGPoint(x: base.x + uy * spread, y: base.y - ux * spread)
        context.setFillColor(AnnotationStyle.color)
        context.move(to: to)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    private static func drawPen(_ context: CGContext, points: [CGPoint], width: CGFloat) {
        guard let first = points.first, width > 0 else { return }
        context.setStrokeColor(AnnotationStyle.color)
        context.setFillColor(AnnotationStyle.color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if points.count == 1 {
            context.fillEllipse(in: CGRect(
                x: first.x - width / 2,
                y: first.y - width / 2,
                width: width,
                height: width
            ))
            return
        }
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    private static func drawMosaic(
        _ context: CGContext,
        pixelated: CGImage,
        imageSize: CGSize,
        points: [CGPoint],
        width: CGFloat
    ) {
        guard let first = points.first, width > 0 else { return }
        let path = CGMutablePath()
        if points.count == 1 {
            path.addEllipse(in: CGRect(
                x: first.x - width / 2,
                y: first.y - width / 2,
                width: width,
                height: width
            ))
        } else {
            path.addLines(between: points)
        }
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        context.draw(pixelated, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
    }
}
