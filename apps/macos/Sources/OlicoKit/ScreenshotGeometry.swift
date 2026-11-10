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
        guard viewBounds.width > 0, viewBounds.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let clipped = clamp(selection, to: viewBounds)
        guard !clipped.isNull, clipped.width >= minimum, clipped.height >= minimum else { return nil }
        let scaleX = imageSize.width / viewBounds.width
        let scaleY = imageSize.height / viewBounds.height
        let minX = max(0, ((clipped.minX - viewBounds.minX) * scaleX).rounded(.down))
        let maxX = min(imageSize.width, ((clipped.maxX - viewBounds.minX) * scaleX).rounded(.up))
        let minY = max(0, ((viewBounds.maxY - clipped.maxY) * scaleY).rounded(.down))
        let maxY = min(imageSize.height, ((viewBounds.maxY - clipped.minY) * scaleY).rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
