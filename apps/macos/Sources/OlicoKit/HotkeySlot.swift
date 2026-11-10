import Foundation

public enum HotkeySlot: String, CaseIterable, Identifiable {
    case screenshot, clipboard, colorPicker, togglePins

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .screenshot: return "截图"
        case .clipboard: return "剪贴板"
        case .colorPicker: return "取色"
        case .togglePins: return "隐藏/显示贴图"
        }
    }
}

public enum HotkeyAction: Equatable {
    case builtin(HotkeySlot)
    case app(target: String, path: String)
}
