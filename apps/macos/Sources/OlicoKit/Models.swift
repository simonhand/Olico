import Foundation

public enum Modifier: String, Codable, CaseIterable, Hashable {
    case cmd, opt, ctrl, shift

    var sortOrder: Int {
        switch self {
        case .cmd: return 0
        case .opt: return 1
        case .ctrl: return 2
        case .shift: return 3
        }
    }
}

public struct Hotkey: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: [Modifier]

    public init(keyCode: UInt32, modifiers: [Modifier]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public func canonical() -> String {
        let sorted = Set(modifiers).sorted { $0.sortOrder < $1.sortOrder }
        return "\(keyCode):\(sorted.map(\.rawValue).joined(separator: ","))"
    }
}

public struct HotkeySet: Codable, Equatable {
    public var screenshot: Hotkey
    public var clipboard: Hotkey
    public var colorPicker: Hotkey
    public var togglePins: Hotkey
}

public struct AppShortcut: Codable, Equatable, Identifiable {
    public var target: String
    public var path: String
    public var keyCode: UInt32
    public var modifiers: [Modifier]
    public var enabled: Bool
    public var id: String { target }
    public var hotkey: Hotkey { Hotkey(keyCode: keyCode, modifiers: modifiers) }
}

public struct ClipboardOptions: Codable, Equatable {
    public var enabled: Bool
    public var maxItems: UInt32
    public var retentionDays: UInt32
    public var maxImageMb: UInt64
    public var maxTextKb: UInt64
    public var excludedApps: [String]
}

public enum ColorFormat: String, Codable, CaseIterable, Identifiable {
    case hex, rgb, hsl
    public var id: String { rawValue }
}

public struct ScreenshotOptions: Codable, Equatable {
    public var saveDir: String
    public var colorFormat: ColorFormat
    public var restorePins: Bool
}

public struct ResidencyOptions: Codable, Equatable {
    public var launchAtLogin: Bool
}

public struct AppConfig: Codable, Equatable {
    public var version: Int
    public var hotkeys: HotkeySet
    public var shortcuts: [AppShortcut]
    public var clipboard: ClipboardOptions
    public var screenshot: ScreenshotOptions
    public var residency: ResidencyOptions
}

public enum ClipboardKind: String, Codable, Equatable {
    case text, image, file
}

public struct ClipboardItem: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: ClipboardKind
    public var text: String?
    public var filePaths: [String]
    public var imagePath: String?
    public var thumbPath: String?
    public var hash: String
    public var sourceBundle: String?
    public var sourceName: String?
    public var byteSize: Int64
    public var createdAt: Int64
    public var pinned: Bool
}

public struct Pinboard: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var color: String
    public var sortOrder: Int32
    public var createdAt: Int64
    public var itemCount: UInt32
}
