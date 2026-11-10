import AppKit

@MainActor
final class ScreenshotHUD {
    static let shared = ScreenshotHUD()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var revealURL: URL?

    func show(message: String, revealURL: URL? = nil) {
        dismiss()
        self.revealURL = revealURL
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = (message as NSString).size(withAttributes: attributes).width
        let width = min(max(ceil(textWidth) + 44, 180), 560)
        let height: CGFloat = 44
        let frame = CGRect(x: 0, y: 0, width: width, height: height)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none

        let content = HUDContentView(frame: frame)
        content.onClick = { [weak self] in
            guard let self, let url = self.revealURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self.dismiss()
        }
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        content.addSubview(effect)

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = frame.insetBy(dx: 16, dy: 12)
        label.autoresizingMask = [.width, .height]
        content.addSubview(label)
        panel.contentView = content

        panel.setFrameOrigin(CGPoint(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.minY + 28
        ))
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        revealURL = nil
    }
}

private final class HUDContentView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
