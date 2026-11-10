import AppKit
import OlicoKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var store: SettingsStore?
    private var settingsWindow: SettingsWindowController?
    private var hotkeyCenter: GlobalHotkeyCenter?
    private var launchAgent: LaunchAgent?
    private var logger: AppLogger?
    private var singleInstance: SingleInstance?
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olico")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let logger = AppLogger(directory: support.appendingPathComponent("logs"))
        self.logger = logger

        let singleInstance = SingleInstance(lockURL: support.appendingPathComponent("instance.lock"))
        self.singleInstance = singleInstance
        guard singleInstance.acquire() else {
            if !CommandLine.arguments.contains("--login-item") {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.olico.activate"),
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
            NSApp.terminate(nil)
            return
        }

        do {
            let client = try CoreClient(dataDir: support)
            let center = GlobalHotkeyCenter()
            let catalog = AppCatalog()
            let agent = LaunchAgent(
                plistURL: LaunchAgent.defaultPlistURL(),
                executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0]
            )
            let store = try SettingsStore(client: client, catalog: catalog) { config in
                center.reload(config: config)
            }
            store.reloadApps()

            center.onAction = { action in
                switch action {
                case .app(let target, let path):
                    let entry = AppEntry(bundleID: target, name: target, path: path)
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try AppLauncher.activateOrLaunch(entry)
                        } catch {
                            logger.log("launch failed for \(target): \(error.localizedDescription)")
                        }
                    }
                case .builtin(.screenshot):
                    logger.log("hotkey: screenshot requested")
                case .builtin(.clipboard):
                    logger.log("hotkey: clipboard requested")
                case .builtin(.colorPicker):
                    logger.log("hotkey: color picker requested")
                case .builtin(.togglePins):
                    logger.log("hotkey: toggle pins requested")
                }
            }
            store.conflicts = center.reload(config: store.config)

            self.store = store
            self.hotkeyCenter = center
            self.launchAgent = agent
            self.settingsWindow = SettingsWindowController(store: store, launchAgent: agent, logger: logger)

            statusItemController = StatusItemController(
                onSettings: { [weak self] in self?.showSettings() },
                onQuit: { NSApp.terminate(nil) }
            )

            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.olico.activate"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showSettings()
            }

            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let store = self.store else { return }
                logger.log("system woke, reloading hotkeys")
                store.conflicts = self.hotkeyCenter?.reload(config: store.config) ?? [:]
                store.reloadApps()
            }

            ensureLaunchAgent(enabled: store.config.residency.launchAtLogin, agent: agent, logger: logger)
            startHealthCheck()

            if CommandLine.arguments.contains("--settings") {
                showSettings()
            }
            logger.log("Olico started")
        } catch {
            logger.log("startup failed: \(error.localizedDescription)")
            statusItemController = StatusItemController(
                onSettings: { [weak self] in self?.showSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        settingsWindow?.show()
    }

    private func ensureLaunchAgent(enabled: Bool, agent: LaunchAgent, logger: AppLogger) {
        guard enabled else { return }
        DispatchQueue.global(qos: .utility).async {
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            if agent.isEnabled(), agent.installedExecutablePath() == executable {
                return
            }
            do {
                try agent.install()
                logger.log("launch agent installed")
            } catch {
                logger.log("launch agent install failed: \(error.localizedDescription)")
            }
        }
    }

    private func startHealthCheck() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let store = self.store else { return }
            let expected = HotkeySlot.allCases.count + store.config.shortcuts.filter(\.enabled).count
            if self.hotkeyCenter?.registeredCount != expected {
                self.logger?.log("health: hotkey count mismatch, reloading")
                store.conflicts = self.hotkeyCenter?.reload(config: store.config) ?? [:]
            }
        }
    }
}
