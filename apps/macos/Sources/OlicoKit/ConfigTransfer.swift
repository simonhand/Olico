import Foundation

public enum ConfigTransferError: Error, Equatable, LocalizedError {
    case decodeFailed
    case unsupportedVersion(Int)
    case invalidHotkey(String, HotkeyValidationError)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            return "配置文件格式不正确"
        case .unsupportedVersion(let version):
            return "不支持的配置版本（v\(version)），仅支持 v\(ConfigTransfer.supportedVersion)"
        case .invalidHotkey(let label, let reason):
            return "「\(label)」快捷键无效：\(reason.localizedDescription)"
        }
    }
}

public enum ConfigTransfer {
    public static let supportedVersion = 2

    public static func encode(_ config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(config)
    }

    public static func decode(_ data: Data) throws -> AppConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config: AppConfig
        do {
            config = try decoder.decode(AppConfig.self, from: data)
        } catch {
            throw ConfigTransferError.decodeFailed
        }
        guard config.version == supportedVersion else {
            throw ConfigTransferError.unsupportedVersion(config.version)
        }
        try validate(config)
        return config
    }

    private static func validate(_ config: AppConfig) throws {
        var existing: [(label: String, hotkey: Hotkey)] = []
        for slot in HotkeySlot.allCases {
            let hotkey = hotkey(for: slot, in: config)
            if let reason = HotkeyValidator.validate(hotkey: hotkey, conflictsWith: existing) {
                throw ConfigTransferError.invalidHotkey(slot.label, reason)
            }
            existing.append((slot.label, hotkey))
        }
        for shortcut in config.shortcuts where shortcut.enabled {
            if let reason = HotkeyValidator.validate(hotkey: shortcut.hotkey, conflictsWith: existing) {
                throw ConfigTransferError.invalidHotkey(shortcut.target, reason)
            }
            existing.append((shortcut.target, shortcut.hotkey))
        }
    }

    private static func hotkey(for slot: HotkeySlot, in config: AppConfig) -> Hotkey {
        switch slot {
        case .screenshot: return config.hotkeys.screenshot
        case .clipboard: return config.hotkeys.clipboard
        case .colorPicker: return config.hotkeys.colorPicker
        case .togglePins: return config.hotkeys.togglePins
        }
    }
}
