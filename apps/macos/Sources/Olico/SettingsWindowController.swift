import AppKit
import SwiftUI
import OlicoKit

final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    private let launchAgent: LaunchAgent
    private let logger: AppLogger

    init(store: SettingsStore, launchAgent: LaunchAgent, logger: AppLogger) {
        self.store = store
        self.launchAgent = launchAgent
        self.logger = logger
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(store: store, launchAgent: launchAgent, logger: logger)
            )
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Olico 设置"
            window.setContentSize(NSSize(width: 960, height: 640))
            window.minSize = NSSize(width: 900, height: 600)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.center()
            // TEMP screenshot hook
            if ProcessInfo.processInfo.environment["OLICO_DEBUG_TALL_WINDOW"] != nil,
               let screen = NSScreen.screens.first {
                window.setContentSize(NSSize(width: 960, height: 900))
                window.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 30))
            }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
