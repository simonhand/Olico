import AppKit
import OlicoKit

struct ScreenshotOutput {
    var selection: CGRect
    var image: CGImage
    var imageFrame: CGRect
}

private final class ScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ScreenshotOverlayView: NSView {
    private struct WindowCapture {
        var candidate: WindowCandidate
        var rect: CGRect
        var image: CGImage?
    }

    private let image: NSImage
    private let imagePixelSize: CGSize
    private let backgroundImage: CGImage
    private let screenFrame: CGRect
    private let primaryHeight: CGFloat
    private let onCopy: (ScreenshotOutput) -> Void
    private let onSave: (ScreenshotOutput) -> Void
    private let onCancel: () -> Void
    private let onWindowPick: (WindowCandidate, CGRect) -> Void

    private var selection: CGRect?
    private var windowCapture: WindowCapture?
    private var hovered: (candidate: WindowCandidate, rect: CGRect)?
    private var candidates: [WindowCandidate] = []
    private var lastCatalogRefresh: TimeInterval = 0
    private var dragStart: CGPoint?
    private var activeHandle: SelectionHandle?
    private var didDrag = false
    private var pointer: CGPoint?
    private var tracking: NSTrackingArea?

    init(
        image cgImage: CGImage,
        screen: NSScreen,
        onCopy: @escaping (ScreenshotOutput) -> Void,
        onSave: @escaping (ScreenshotOutput) -> Void,
        onCancel: @escaping () -> Void,
        onWindowPick: @escaping (WindowCandidate, CGRect) -> Void
    ) {
        self.image = NSImage(cgImage: cgImage, size: screen.frame.size)
        self.imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        self.backgroundImage = cgImage
        self.screenFrame = screen.frame
        self.primaryHeight = WindowCatalog.primaryHeight
        self.onCopy = onCopy
        self.onSave = onSave
        self.onCancel = onCancel
        self.onWindowPick = onWindowPick
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
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
            if let windowCapture, let capturedImage = windowCapture.image {
                context.saveGState()
                context.clip(to: selection)
                NSImage(cgImage: capturedImage, size: windowCapture.rect.size)
                    .draw(in: windowCapture.rect)
                context.restoreGState()
            } else {
                context.saveGState()
                context.clip(to: selection)
                image.draw(in: bounds)
                context.restoreGState()
            }
            drawSelection(selection)
        } else {
            drawHoveredWindow()
            drawCrosshair()
        }

        drawHint()
    }

    private func drawSelection(_ rect: CGRect) {
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()

        let sourceSize: CGSize
        let sourceFrame: CGRect
        if let windowCapture, let capturedImage = windowCapture.image {
            sourceSize = CGSize(width: capturedImage.width, height: capturedImage.height)
            sourceFrame = windowCapture.rect
        } else {
            sourceSize = imagePixelSize
            sourceFrame = bounds
        }
        let scaleX = sourceSize.width / max(sourceFrame.width, 1)
        let scaleY = sourceSize.height / max(sourceFrame.height, 1)
        let width = Int((rect.width * scaleX).rounded())
        let height = Int((rect.height * scaleY).rounded())

        let labelCenter = tagCenter(for: rect)
        drawTag("\(width) × \(height)", center: labelCenter)

        NSColor.white.setFill()
        for point in handlePoints(for: rect).values {
            let handle = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            handle.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            NSBezierPath(rect: handle).stroke()
        }
    }

    private func drawHoveredWindow() {
        guard let hovered else { return }
        let rect = hovered.rect
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()

        let scale = window?.backingScaleFactor ?? 2
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        let title = displayTitle(hovered.candidate.title)
        drawTag("\(title)   \(width) × \(height)", center: tagCenter(for: rect))
    }

    private func tagCenter(for rect: CGRect) -> CGPoint {
        let y = rect.minY > 40 ? rect.minY - 16 : rect.maxY + 16
        return CGPoint(
            x: min(max(rect.midX, bounds.minX + 100), bounds.maxX - 100),
            y: min(max(y, bounds.minY + 20), bounds.maxY - 20)
        )
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
        drawTag(hintText(), center: CGPoint(x: bounds.midX, y: 26))
    }

    private func hintText() -> String {
        guard selection != nil else {
            return "单击窗口   拖拽选区   双击 / ⌘A 全屏   Esc 取消"
        }
        if let windowCapture, windowCapture.image == nil {
            return "正在抓取窗口…   Esc 取消"
        }
        return "↵ 复制   ⌘S 保存   拖拽调整   Esc 取消"
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

    private func displayTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "窗口" }
        let limit = 24
        return title.count > limit ? String(title.prefix(limit)) + "…" : title
    }

    private func output() -> ScreenshotOutput? {
        guard let selection else { return nil }
        if let windowCapture {
            guard let image = windowCapture.image else { return nil }
            return ScreenshotOutput(selection: selection, image: image, imageFrame: windowCapture.rect)
        }
        return ScreenshotOutput(selection: selection, image: backgroundImage, imageFrame: bounds)
    }

    func applyWindowCapture(_ image: CGImage, rect: CGRect) {
        guard var capture = windowCapture, capture.rect == rect else { return }
        capture.image = image
        windowCapture = capture
        needsDisplay = true
    }

    func cancelWindowCapture() {
        guard windowCapture != nil else { return }
        windowCapture = nil
        selection = nil
        needsDisplay = true
        if let pointer {
            refreshHover(at: pointer, force: true)
        }
    }

    private func refreshHover(at point: CGPoint, force: Bool = false) {
        guard selection == nil else {
            if hovered != nil {
                hovered = nil
                needsDisplay = true
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - lastCatalogRefresh >= 0.12 {
            candidates = WindowCatalog.candidates()
            lastCatalogRefresh = now
        }
        let quartzPoint = ScreenshotGeometry.quartzPoint(
            fromView: point,
            screenFrame: screenFrame,
            primaryHeight: primaryHeight
        )
        let picked = WindowPicker.pick(
            at: quartzPoint,
            from: candidates,
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
        var next: (WindowCandidate, CGRect)?
        if let picked {
            let rect = ScreenshotGeometry.viewRect(
                fromQuartz: picked.frame,
                screenFrame: screenFrame,
                primaryHeight: primaryHeight
            )
            if rect.width >= 1, rect.height >= 1, rect.intersects(bounds) {
                next = (picked, rect)
            }
        }
        let changed = next?.0.id != hovered?.candidate.id || next?.1 != hovered?.rect
        hovered = next
        if changed {
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if let pointer {
            refreshHover(at: pointer)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            if let selection, selection.contains(point) {
                if let output = output() {
                    onCopy(output)
                }
                return
            }
            selection = bounds
            windowCapture = nil
            hovered = nil
            dragStart = nil
            activeHandle = nil
            needsDisplay = true
            return
        }
        if let selection, let handle = ScreenshotGeometry.handle(at: point, in: selection, tolerance: 8) {
            activeHandle = handle
            dragStart = point
            didDrag = false
            return
        }
        dragStart = point
        activeHandle = nil
        didDrag = false
        if let selection, !selection.contains(point) {
            self.selection = nil
            windowCapture = nil
            refreshHover(at: point, force: true)
        } else if selection == nil {
            refreshHover(at: point, force: true)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = activeHandle, let current = selection {
            selection = ScreenshotGeometry.resized(current, handle: handle, to: point, within: bounds)
        } else {
            if !didDrag, hypot(point.x - start.x, point.y - start.y) > 3 {
                didDrag = true
                windowCapture = nil
                hovered = nil
            }
            if didDrag {
                selection = ScreenshotGeometry.clamp(
                    ScreenshotGeometry.rect(from: start, to: point),
                    to: bounds
                )
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !didDrag, activeHandle == nil, selection == nil, let hovered {
            selection = hovered.rect
            windowCapture = WindowCapture(candidate: hovered.candidate, rect: hovered.rect, image: nil)
            self.hovered = nil
            dragStart = nil
            needsDisplay = true
            onWindowPick(hovered.candidate, hovered.rect)
            return
        }
        if let selection, didDrag, selection.width < 3 || selection.height < 3 {
            self.selection = nil
        }
        dragStart = nil
        activeHandle = nil
        didDrag = false
        if selection == nil {
            refreshHover(at: point)
        }
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
            if let output = output() {
                onCopy(output)
            }
            return
        }
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command), characters == "s" {
            if let output = output() {
                onSave(output)
            }
            return
        }
        if event.modifierFlags.contains(.command), characters == "a" {
            selection = bounds
            windowCapture = nil
            hovered = nil
            needsDisplay = true
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
    private var resignKeyPolicy = ResignKeyPolicy()

    func present(
        image: CGImage,
        screen: NSScreen,
        onCopy: @escaping (ScreenshotOutput) -> Void,
        onSave: @escaping (ScreenshotOutput) -> Void,
        onCancel: @escaping () -> Void,
        onWindowPick: @escaping (WindowCandidate, CGRect) -> Void
    ) {
        self.onCancel = onCancel
        self.resignKeyPolicy = ResignKeyPolicy()
        previousApp = NSWorkspace.shared.frontmostApplication

        let view = ScreenshotOverlayView(
            image: image,
            screen: screen,
            onCopy: onCopy,
            onSave: onSave,
            onCancel: onCancel,
            onWindowPick: onWindowPick
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

    func applyWindowCapture(_ image: CGImage, rect: CGRect) {
        guard panel != nil else { return }
        (panel?.contentView as? ScreenshotOverlayView)?.applyWindowCapture(image, rect: rect)
    }

    func cancelWindowCapture() {
        guard panel != nil else { return }
        (panel?.contentView as? ScreenshotOverlayView)?.cancelWindowCapture()
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

    func windowDidBecomeKey(_ notification: Notification) {
        resignKeyPolicy = ResignKeyPolicy()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel != nil else { return }
        switch resignKeyPolicy.nextAction() {
        case .rekey(let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(panel.contentView)
            }
        case .cancel:
            let cancel = onCancel
            dismiss()
            cancel?()
        }
    }
}
