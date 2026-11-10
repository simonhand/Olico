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

public struct LinkShortcut: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public var keyCode: UInt32
    public var modifiers: [Modifier]
    public var enabled: Bool

    public var hotkey: Hotkey { Hotkey(keyCode: keyCode, modifiers: modifiers) }

    public init(
        id: String,
        title: String,
        url: String,
        keyCode: UInt32,
        modifiers: [Modifier],
        enabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }
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
    public var links: [LinkShortcut]
    public var clipboard: ClipboardOptions
    public var screenshot: ScreenshotOptions
    public var residency: ResidencyOptions

    public init(
        version: Int,
        hotkeys: HotkeySet,
        shortcuts: [AppShortcut],
        links: [LinkShortcut] = [],
        clipboard: ClipboardOptions,
        screenshot: ScreenshotOptions,
        residency: ResidencyOptions
    ) {
        self.version = version
        self.hotkeys = hotkeys
        self.shortcuts = shortcuts
        self.links = links
        self.clipboard = clipboard
        self.screenshot = screenshot
        self.residency = residency
    }

    private enum CodingKeys: String, CodingKey {
        case version, hotkeys, shortcuts, links, clipboard, screenshot, residency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        hotkeys = try container.decode(HotkeySet.self, forKey: .hotkeys)
        shortcuts = try container.decode([AppShortcut].self, forKey: .shortcuts)
        // Configs written before link shortcuts existed have no links key.
        links = try container.decodeIfPresent([LinkShortcut].self, forKey: .links) ?? []
        clipboard = try container.decode(ClipboardOptions.self, forKey: .clipboard)
        screenshot = try container.decode(ScreenshotOptions.self, forKey: .screenshot)
        residency = try container.decode(ResidencyOptions.self, forKey: .residency)
    }
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
