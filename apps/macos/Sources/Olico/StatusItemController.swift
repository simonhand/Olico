import AppKit

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Olico")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Olico", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func quit() {
        onQuit()
    }
}
