import AppKit
import OlicoKit

private final class ScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ScreenshotOverlayView: NSView {
    private let image: NSImage
    private let imagePixelSize: CGSize
    private let onCopy: (CGRect) -> Void
    private let onSave: (CGRect) -> Void
    private let onCancel: () -> Void

    private var selection: CGRect?
    private var dragStart: CGPoint?
    private var activeHandle: SelectionHandle?
    private var pointer: CGPoint?
    private var tracking: NSTrackingArea?

    init(
        image cgImage: CGImage,
        size: CGSize,
        onCopy: @escaping (CGRect) -> Void,
        onSave: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.image = NSImage(cgImage: cgImage, size: size)
        self.imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        self.onCopy = onCopy
        self.onSave = onSave
        self.onCancel = onCancel
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        image.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        if let selection {
            context.saveGState()
            context.clip(to: selection)
            image.draw(in: bounds)
            context.restoreGState()
            drawSelection(selection)
        } else {
            drawCrosshair()
        }

        drawHint()
    }

    private func drawSelection(_ rect: CGRect) {
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()

        let pixelScaleX = imagePixelSize.width / bounds.width
        let pixelScaleY = imagePixelSize.height / bounds.height
        let width = Int((rect.width * pixelScaleX).rounded())
        let height = Int((rect.height * pixelScaleY).rounded())

        let labelCenter = CGPoint(
            x: rect.midX,
            y: rect.minY > 40 ? rect.minY - 16 : rect.maxY + 16
        )
        drawTag("\(width) × \(height)", center: labelCenter)

        NSColor.white.setFill()
        for point in handlePoints(for: rect).values {
            let handle = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            handle.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            NSBezierPath(rect: handle).stroke()
        }
    }

    private func handlePoints(for rect: CGRect) -> [SelectionHandle: CGPoint] {
        [
            .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .top: CGPoint(x: rect.midX, y: rect.maxY),
            .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .left: CGPoint(x: rect.minX, y: rect.midY),
            .right: CGPoint(x: rect.maxX, y: rect.midY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            .bottom: CGPoint(x: rect.midX, y: rect.minY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
        ]
    }

    private func drawCrosshair() {
        guard let pointer else { return }
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: pointer.x, y: 0))
        path.line(to: CGPoint(x: pointer.x, y: bounds.height))
        path.move(to: CGPoint(x: 0, y: pointer.y))
        path.line(to: CGPoint(x: bounds.width, y: pointer.y))
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawHint() {
        drawTag("拖拽选择区域    ↵ 复制    ⌘S 保存    Esc 取消", center: CGPoint(x: bounds.midX, y: 26))
    }

    private func drawTag(_ text: String, center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(
            x: center.x - size.width / 2 - 8,
            y: center.y - size.height / 2 - 4,
            width: size.width + 16,
            height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            at: CGPoint(x: rect.minX + 8, y: rect.minY + 4),
            withAttributes: attributes
        )
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            if let selection, selection.contains(point) {
                onCopy(selection)
            } else {
                selection = bounds
                needsDisplay = true
            }
            return
        }
        if let selection, let handle = ScreenshotGeometry.handle(at: point, in: selection, tolerance: 8) {
            activeHandle = handle
            dragStart = point
            return
        }
        dragStart = point
        activeHandle = nil
        if let selection, !selection.contains(point) {
            self.selection = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = activeHandle, let current = selection {
            selection = ScreenshotGeometry.resized(current, handle: handle, to: point, within: bounds)
        } else {
            selection = ScreenshotGeometry.clamp(
                ScreenshotGeometry.rect(from: start, to: point),
                to: bounds
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width < 3 || selection.height < 3 {
            self.selection = nil
        }
        dragStart = nil
        activeHandle = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let selection {
                onCopy(selection)
            }
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            if let selection {
                onSave(selection)
            }
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class ScreenshotOverlayController: NSObject, NSWindowDelegate {
    private var panel: ScreenshotPanel?
    private var previousApp: NSRunningApplication?
    private var onCancel: (() -> Void)?

    func present(
        image: CGImage,
        screen: NSScreen,
        onCopy: @escaping (CGRect) -> Void,
        onSave: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCancel = onCancel
        previousApp = NSWorkspace.shared.frontmostApplication

        let view = ScreenshotOverlayView(
            image: image,
            size: screen.frame.size,
            onCopy: onCopy,
            onSave: onSave,
            onCancel: onCancel
        )
        let panel = ScreenshotPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = .none
        panel.delegate = self
        panel.contentView = view
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentView = nil
        onCancel = nil
        previousApp?.activate()
        previousApp = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel != nil else { return }
        let cancel = onCancel
        dismiss()
        cancel?()
    }
}
