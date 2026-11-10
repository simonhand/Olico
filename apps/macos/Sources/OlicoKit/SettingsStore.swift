import Foundation
import Combine

public enum LinkValidationError: Error, Equatable, LocalizedError {
    case emptyTitle
    case invalidURL
    case invalidHotkey(HotkeyValidationError)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: return "名称不能为空"
        case .invalidURL: return "请输入有效的 http 或 https 链接"
        case .invalidHotkey(let reason): return "快捷键无效：\(reason.localizedDescription)"
        }
    }
}

public final class SettingsStore: ObservableObject {
    @Published public var config: AppConfig
    @Published public private(set) var apps: [AppEntry] = []
    @Published public var conflicts: [String: String] = [:]
    @Published public var searchText = ""
    @Published public var onlyConfigured = false
    @Published public private(set) var lastError: String?

    private let client: CoreClient
    private let catalog: AppCatalog
    private let onConfigChanged: ((AppConfig) -> [String: String])?

    public init(
        client: CoreClient,
        catalog: AppCatalog,
        onConfigChanged: ((AppConfig) -> [String: String])? = nil
    ) throws {
        self.client = client
        self.catalog = catalog
        self.onConfigChanged = onConfigChanged
        self.config = try client.config()
    }

    public func persistedConfig() -> AppConfig {
        (try? client.config()) ?? config
    }

    public func reloadApps() {
        apps = catalog.scan(force: true)
    }

    public func filteredApps() -> [AppEntry] {
        var result = apps
        if onlyConfigured {
            result = result.filter { shortcut(for: $0.bundleID) != nil }
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter {
                $0.name.lowercased().contains(needle) || $0.bundleID.lowercased().contains(needle)
            }
        }
        return result
    }

    public func shortcut(for bundleID: String) -> AppShortcut? {
        config.shortcuts.first { $0.target == bundleID }
    }

    public func name(for bundleID: String) -> String {
        apps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    public func setBuiltinHotkey(_ slot: HotkeySlot, _ hotkey: Hotkey) throws {
        var existing: [(label: String, hotkey: Hotkey)] = []
        for other in HotkeySlot.allCases where other != slot {
            existing.append((other.label, self.hotkey(for: other)))
        }
        for shortcut in config.shortcuts where shortcut.enabled {
            existing.append((name(for: shortcut.target), shortcut.hotkey))
        }
        for link in config.links where link.enabled {
            existing.append((link.title, link.hotkey))
        }
        if let error = HotkeyValidator.validate(hotkey: hotkey, conflictsWith: existing) {
            throw error
        }
        switch slot {
        case .screenshot: config.hotkeys.screenshot = hotkey
        case .clipboard: config.hotkeys.clipboard = hotkey
        case .colorPicker: config.hotkeys.colorPicker = hotkey
        case .togglePins: config.hotkeys.togglePins = hotkey
        }
        try saveConfig()
    }

    public func setShortcut(app: AppEntry, hotkey: Hotkey) throws {
        var existing: [(label: String, hotkey: Hotkey)] = HotkeySlot.allCases.map {
            ($0.label, self.hotkey(for: $0))
        }
        for shortcut in config.shortcuts where shortcut.enabled && shortcut.target != app.bundleID {
            existing.append((name(for: shortcut.target), shortcut.hotkey))
        }
        for link in config.links where link.enabled {
            existing.append((link.title, link.hotkey))
        }
        if let error = HotkeyValidator.validate(hotkey: hotkey, conflictsWith: existing) {
            throw error
        }
        let updated = AppShortcut(
            target: app.bundleID,
            path: app.path,
            keyCode: hotkey.keyCode,
            modifiers: hotkey.modifiers,
            enabled: true
        )
        if let index = config.shortcuts.firstIndex(where: { $0.target == app.bundleID }) {
            config.shortcuts[index] = updated
        } else {
            config.shortcuts.append(updated)
        }
        try saveConfig()
    }

    public func removeShortcut(bundleID: String) throws {
        config.shortcuts.removeAll { $0.target == bundleID }
        try saveConfig()
    }

    public func link(for id: String) -> LinkShortcut? {
        config.links.first { $0.id == id }
    }

    @discardableResult
    public func saveLink(
        id: String?,
        title: String,
        url: String,
        hotkey: Hotkey
    ) throws -> LinkShortcut {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw LinkValidationError.emptyTitle }
        guard let normalized = LinkLauncher.normalizedURL(url) else {
            throw LinkValidationError.invalidURL
        }

        var existing: [(label: String, hotkey: Hotkey)] = HotkeySlot.allCases.map {
            ($0.label, self.hotkey(for: $0))
        }
        for shortcut in config.shortcuts where shortcut.enabled {
            existing.append((name(for: shortcut.target), shortcut.hotkey))
        }
        for other in config.links where other.enabled && other.id != id {
            existing.append((other.title, other.hotkey))
        }
        if let error = HotkeyValidator.validate(hotkey: hotkey, conflictsWith: existing) {
            throw LinkValidationError.invalidHotkey(error)
        }

        let link = LinkShortcut(
            id: id ?? UUID().uuidString,
            title: trimmedTitle,
            url: normalized.absoluteString,
            keyCode: hotkey.keyCode,
            modifiers: hotkey.modifiers
        )
        if let index = config.links.firstIndex(where: { $0.id == link.id }) {
            config.links[index] = link
        } else {
            config.links.append(link)
        }
        try saveConfig()
        return link
    }

    public func removeLink(id: String) throws {
        config.links.removeAll { $0.id == id }
        try saveConfig()
    }

    public func saveConfig() throws {
        do {
            try client.setConfig(config)
            conflicts = onConfigChanged?(config) ?? [:]
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func clearClipboard() {
        do {
            try client.clipboardClear()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func importConfig(_ imported: AppConfig, agent: LaunchAgent) throws {
        let previous = config
        config = imported
        do {
            if imported.residency.launchAtLogin != agent.isEnabled() {
                if imported.residency.launchAtLogin {
                    try agent.install()
                } else {
                    try agent.uninstall()
                }
            }
            try saveConfig()
        } catch {
            config = previous
            lastError = error.localizedDescription
            throw error
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool, agent: LaunchAgent) throws {
        do {
            if enabled {
                try agent.install()
            } else {
                try agent.uninstall()
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        config.residency.launchAtLogin = enabled
        try saveConfig()
    }

    private func hotkey(for slot: HotkeySlot) -> Hotkey {
        switch slot {
        case .screenshot: return config.hotkeys.screenshot
        case .clipboard: return config.hotkeys.clipboard
        case .colorPicker: return config.hotkeys.colorPicker
        case .togglePins: return config.hotkeys.togglePins
        }
    }
}
