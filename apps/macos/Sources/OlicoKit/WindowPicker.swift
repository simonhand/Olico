import CoreGraphics
import Foundation

public struct WindowCandidate: Equatable {
    public var id: UInt32
    public var frame: CGRect
    public var layer: Int
    public var ownerPID: pid_t
    public var alpha: Double
    public var title: String?

    public init(
        id: UInt32,
        frame: CGRect,
        layer: Int,
        ownerPID: pid_t,
        alpha: Double,
        title: String? = nil
    ) {
        self.id = id
        self.frame = frame
        self.layer = layer
        self.ownerPID = ownerPID
        self.alpha = alpha
        self.title = title
    }
}

public enum WindowPicker {
    /// Picks the frontmost ordinary window under the pointer.
    /// `windows` must be ordered front to back.
    public static func pick(
        at point: CGPoint,
        from windows: [WindowCandidate],
        excludingPID: pid_t
    ) -> WindowCandidate? {
        windows.first { window in
            window.layer == 0
                && window.alpha > 0
                && window.ownerPID != excludingPID
                && window.frame.width >= 1
                && window.frame.height >= 1
                && window.frame.contains(point)
        }
    }
}
