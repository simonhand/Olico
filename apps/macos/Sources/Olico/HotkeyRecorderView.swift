import SwiftUI
import AppKit
import OlicoKit

struct HotkeyRecorderView: View {
    let title: String
    let onSave: (Hotkey) throws -> Void
    let onCancel: () -> Void

    @State private var captured: Hotkey?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 15, weight: .semibold))
            VStack(spacing: 8) {
                if let captured {
                    Text(HotkeyFormatter.display(captured))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "keyboard")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("按下新的快捷键")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            if let errorText {
                NoticeBanner(text: errorText, isError: true)
            }
            HStack {
                Text("Esc 取消").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                Button("保存") {
                    guard let captured else { return }
                    do {
                        try onSave(captured)
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(captured == nil)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(KeyCaptureView(
            onCapture: { hotkey in
                captured = hotkey
                errorText = nil
            },
            onCancel: onCancel
        ))
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (Hotkey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
    }
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((Hotkey) -> Void)?
    var onCancel: (() -> Void)?

    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeMonitor()
            return
        }
        installMonitor()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    deinit {
        // NSEvent.removeMonitor must run on the main thread.
        if let monitor {
            DispatchQueue.main.async { NSEvent.removeMonitor(monitor) }
        }
    }

    // A local monitor sees the key before the window's responder chain, so
    // command combinations and three-key chords cannot be swallowed by menus
    // or by a missing first responder.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window != nil else { return event }
            if event.isARepeat { return nil }
            if event.keyCode == HotkeyCapture.cancelKeyCode {
                self.onCancel?()
                return nil
            }
            guard let hotkey = HotkeyCapture.hotkey(
                keyCode: UInt32(event.keyCode),
                flags: event.modifierFlags
            ) else { return nil }
            self.onCapture?(hotkey)
            return nil
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
