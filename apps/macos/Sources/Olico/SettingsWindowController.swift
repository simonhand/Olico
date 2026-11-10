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
            window.setContentSize(NSSize(width: 920, height: 640))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
