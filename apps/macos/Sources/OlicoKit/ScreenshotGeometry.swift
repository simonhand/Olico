import CoreGraphics

public enum SelectionHandle: CaseIterable, Equatable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
}

public enum ScreenshotGeometry {
    public static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        rect.intersection(bounds)
    }

    public static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> SelectionHandle? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let expanded = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard expanded.contains(point) else { return nil }
        let nearLeft = abs(point.x - rect.minX) <= tolerance
        let nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearBottom = abs(point.y - rect.minY) <= tolerance
        let nearTop = abs(point.y - rect.maxY) <= tolerance
        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _): return .bottomLeft
        case (true, _, _, true): return .topLeft
        case (_, true, true, _): return .bottomRight
        case (_, true, _, true): return .topRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .bottom
        case (_, _, _, true): return .top
        default: return nil
        }
    }

    public static func resized(
        _ rect: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        within bounds: CGRect
    ) -> CGRect {
        let point = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        switch handle {
        case .topLeft:
            minX = point.x
            maxY = point.y
        case .top:
            maxY = point.y
        case .topRight:
            maxX = point.x
            maxY = point.y
        case .left:
            minX = point.x
        case .right:
            maxX = point.x
        case .bottomLeft:
            minX = point.x
            minY = point.y
        case .bottom:
            minY = point.y
        case .bottomRight:
            maxX = point.x
            minY = point.y
        }
        if minX > maxX { swap(&minX, &maxX) }
        if minY > maxY { swap(&minY, &maxY) }
        return clamp(
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            to: bounds
        )
    }

    public static func pixelCropRect(
        for selection: CGRect,
        viewBounds: CGRect,
        imageSize: CGSize,
        minimum: CGFloat = 1
    ) -> CGRect? {
        pixelCropRect(for: selection, in: viewBounds, imageSize: imageSize, minimum: minimum)
    }

    /// Maps a view-space selection into image pixels. `frame` is the view-space
    /// rect the image is drawn into, so a window bitmap aligned to its own rect
    /// crops correctly without assuming the image covers the whole overlay.
    public static func pixelCropRect(
        for selection: CGRect,
        in frame: CGRect,
        imageSize: CGSize,
        minimum: CGFloat = 1
    ) -> CGRect? {
        guard frame.width > 0, frame.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let clipped = clamp(selection, to: frame)
        guard !clipped.isNull, clipped.width >= minimum, clipped.height >= minimum else { return nil }
        let scaleX = imageSize.width / frame.width
        let scaleY = imageSize.height / frame.height
        let minX = max(0, ((clipped.minX - frame.minX) * scaleX).rounded(.down))
        let maxX = min(imageSize.width, ((clipped.maxX - frame.minX) * scaleX).rounded(.up))
        let minY = max(0, ((frame.maxY - clipped.maxY) * scaleY).rounded(.down))
        let maxY = min(imageSize.height, ((frame.maxY - clipped.minY) * scaleY).rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Converts a Quartz global rect (top-left origin, y down) into overlay view
    /// coordinates (bottom-left origin, y up).
    public static func viewRect(
        fromQuartz rect: CGRect,
        screenFrame: CGRect,
        primaryHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: primaryHeight - rect.maxY - screenFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func quartzPoint(
        fromView point: CGPoint,
        screenFrame: CGRect,
        primaryHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: point.x + screenFrame.minX,
            y: primaryHeight - (point.y + screenFrame.minY)
        )
    }
}
