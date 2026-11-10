import AppKit
import CoreGraphics
import OlicoKit

@MainActor
enum WindowCatalog {
    /// Height of the primary display in Quartz coordinates, used to flip y.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    /// On-screen windows ordered front to back in Quartz global coordinates.
    static func candidates() -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let title = info[kCGWindowName as String] as? String
                ?? info[kCGWindowOwnerName as String] as? String
            return WindowCandidate(
                id: number.uint32Value,
                frame: frame,
                layer: layer,
                ownerPID: ownerPID,
                alpha: alpha,
                title: title
            )
        }
    }
}
