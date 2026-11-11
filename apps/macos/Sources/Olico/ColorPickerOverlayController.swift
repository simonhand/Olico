import AppKit
import OlicoKit

private final class ColorPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ColorPickerOverlayView: NSView {
    private static let sampleRadius = 5
    private static let loupeSide: CGFloat = 132
    private static let cardHeight: CGFloat = 68

    private let image: CGImage
    private let imageSize: CGSize
    private let screenFrame: CGRect
    private let primaryHeight: CGFloat
    private let format: ColorFormat
    private let onPick: (CGPoint) -> Void
    private let onCancel: () -> Void

    private var pointer: CGPoint?
    private var tracking: NSTrackingArea?

    init(
        image: CGImage,
        screen: NSScreen,
        format: ColorFormat,
        onPick: @escaping (CGPoint) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.image = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        self.screenFrame = screen.frame
        self.primaryHeight = WindowCatalog.primaryHeight
        self.format = format
        self.onPick = onPick
        self.onCancel = onCancel
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        movePointer(to: pointerFromScreen(NSEvent.mouseLocation))
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLoupe()
        drawHint()
    }

    override func mouseMoved(with event: NSEvent) {
        movePointer(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        movePointer(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        movePointer(to: point)
        onPick(point)
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
            onPick(pointer ?? pointerFromScreen(NSEvent.mouseLocation))
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123:
            nudge(dx: -step, dy: 0)
        case 124:
            nudge(dx: step, dy: 0)
        case 125:
            nudge(dx: 0, dy: -step)
        case 126:
            nudge(dx: 0, dy: step)
        default:
            super.keyDown(with: event)
        }
    }

    private func pointerFromScreen(_ point: CGPoint) -> CGPoint {
        guard let window else { return point }
        return convert(window.convertPoint(fromScreen: point), from: nil)
    }

    private func movePointer(to point: CGPoint) {
        let previous = pointer.map { loupeRect(for: $0) }
        pointer = point
        let current = loupeRect(for: point)
        if let previous {
            setNeedsDisplay(previous.union(current))
        } else {
            needsDisplay = true
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        let current = pointer ?? pointerFromScreen(NSEvent.mouseLocation)
        let next = CGPoint(
            x: min(max(current.x + dx, bounds.minX + 1), bounds.maxX - 1),
            y: min(max(current.y + dy, bounds.minY + 1), bounds.maxY - 1)
        )
        movePointer(to: next)
        CGWarpMouseCursorPosition(
            ScreenshotGeometry.quartzPoint(
                fromView: next,
                screenFrame: screenFrame,
                primaryHeight: primaryHeight
            )
        )
    }

    private func loupeRect(for pointer: CGPoint) -> CGRect {
        let width = max(Self.loupeSide, 176)
        let height = Self.loupeSide + 8 + Self.cardHeight
        var origin = CGPoint(x: pointer.x + 24, y: pointer.y + 24)
        if origin.x + width > bounds.maxX - 12 {
            origin.x = pointer.x - width - 24
        }
        if origin.y + height > bounds.maxY - 12 {
            origin.y = pointer.y - height - 24
        }
        origin.x = max(12, origin.x)
        origin.y = max(12, origin.y)
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    private func drawLoupe() {
        guard let pointer,
              let context = NSGraphicsContext.current?.cgContext,
              let point = ColorSampler.pixelPoint(for: pointer, in: bounds, imageSize: imageSize),
              let sample = ColorSampler.sample(image, at: point),
              let crop = ColorSampler.crop(image, around: point, radius: Self.sampleRadius)
        else { return }

        let total = loupeRect(for: pointer)
        let loupe = CGRect(
            x: total.midX - Self.loupeSide / 2,
            y: total.maxY - Self.loupeSide,
            width: Self.loupeSide,
            height: Self.loupeSide
        )

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 14,
            color: NSColor.black.withAlphaComponent(0.45).cgColor
        )
        NSColor.black.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: loupe, xRadius: 12, yRadius: 12).fill()
        context.restoreGState()

        context.saveGState()
        NSBezierPath(roundedRect: loupe, xRadius: 12, yRadius: 12).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop.image, size: loupe.size).draw(in: loupe)

        let columns = CGFloat(max(crop.image.width, 1))
        let rows = CGFloat(max(crop.image.height, 1))
        let cellWidth = loupe.width / columns
        let cellHeight = loupe.height / rows
        let cellX = CGFloat(point.x - crop.originX)
        let cellY = CGFloat(point.y - crop.originY)
        let cell = CGRect(
            x: loupe.minX + cellX * cellWidth,
            y: loupe.maxY - (cellY + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        NSColor.black.withAlphaComponent(0.75).setStroke()
        let outer = NSBezierPath(rect: cell.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 3
        outer.stroke()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: cell)
        border.lineWidth = 1.5
        border.stroke()
        context.restoreGState()

        NSColor.white.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(
            roundedRect: loupe.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 12,
            yRadius: 12
        )
        outline.lineWidth = 1
        outline.stroke()

        drawCard(total: total, sample: sample, pointer: pointer)
    }

    private func drawCard(total: CGRect, sample: SampledColor, pointer: CGPoint) {
        let card = CGRect(x: total.minX, y: total.minY, width: total.width, height: Self.cardHeight)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10).fill()

        let swatch = CGRect(x: card.minX + 10, y: card.maxY - 24, width: 14, height: 14)
        NSColor(
            srgbRed: CGFloat(sample.red) / 255,
            green: CGFloat(sample.green) / 255,
            blue: CGFloat(sample.blue) / 255,
            alpha: 1
        ).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let primary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
        ]

        let textX = swatch.maxX + 8
        let lineHeight: CGFloat = 15
        var y = card.maxY - 22
        (ColorText.hex(sample) as NSString).draw(at: CGPoint(x: textX, y: y), withAttributes: primary)
        y -= lineHeight
        (ColorText.rgb(sample) as NSString).draw(at: CGPoint(x: card.minX + 10, y: y), withAttributes: secondary)
        y -= lineHeight
        (ColorText.hsl(sample) as NSString).draw(at: CGPoint(x: card.minX + 10, y: y), withAttributes: secondary)
        y -= lineHeight
        let quartz = ScreenshotGeometry.quartzPoint(
            fromView: pointer,
            screenFrame: screenFrame,
            primaryHeight: primaryHeight
        )
        let coords = "x \(Int(quartz.x.rounded()))  y \(Int(quartz.y.rounded()))"
        (coords as NSString).draw(at: CGPoint(x: card.minX + 10, y: y), withAttributes: secondary)
    }

    private func drawHint() {
        let label: String
        switch format {
        case .hex: label = "HEX"
        case .rgb: label = "RGB"
        case .hsl: label = "HSL"
        }
        drawTag(
            "单击复制 \(label)   方向键微调   Esc 取消",
            center: CGPoint(x: bounds.midX, y: 26)
        )
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
}

@MainActor
final class ColorPickerOverlayController: NSObject, NSWindowDelegate {
    private let logger: AppLogger
    private var panel: ColorPickerPanel?
    private var previousApp: NSRunningApplication?
    private var onCancel: (() -> Void)?
    private var resignKeyPolicy = ResignKeyPolicy()

    init(logger: AppLogger) {
        self.logger = logger
        super.init()
    }

    func present(
        image: CGImage,
        screen: NSScreen,
        format: ColorFormat,
        onPick: @escaping (CGPoint) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCancel = onCancel
        resignKeyPolicy = ResignKeyPolicy()
        previousApp = NSWorkspace.shared.frontmostApplication

        let view = ColorPickerOverlayView(
            image: image,
            screen: screen,
            format: format,
            onPick: onPick,
            onCancel: onCancel
        )
        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let background = NSImageView(frame: container.bounds)
        background.image = NSImage(cgImage: image, size: screen.frame.size)
        background.imageScaling = .scaleAxesIndependently
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)

        let panel = ColorPickerPanel(
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
        panel.contentView = container
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        logger.log(
            "color picker presented active=\(NSApp.isActive) key=\(panel.isKeyWindow) "
                + "previous=\(previousApp?.bundleIdentifier ?? "?")"
        )
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
            logger.log("color picker resign key, rekey attempt \(resignKeyPolicy.attempts)")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(panel.contentView)
            }
        case .cancel:
            logger.log("color picker resign key, giving up")
            let cancel = onCancel
            dismiss()
            cancel?()
        }
    }
}
