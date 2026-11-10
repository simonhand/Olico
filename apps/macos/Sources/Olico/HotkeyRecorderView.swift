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
            Text(title).font(.headline)
            Text(captured.map(HotkeyFormatter.display) ?? "按下新的快捷键")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Text("Esc 取消").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    guard let captured else { return }
                    do {
                        try onSave(captured)
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
                .disabled(captured == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
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

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [Modifier] = []
        if flags.contains(.command) { modifiers.append(.cmd) }
        if flags.contains(.option) { modifiers.append(.opt) }
        if flags.contains(.control) { modifiers.append(.ctrl) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        onCapture?(Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }
}
