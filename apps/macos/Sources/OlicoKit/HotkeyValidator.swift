import Foundation

public enum HotkeyValidationError: Error, Equatable, LocalizedError {
    case tooSimple
    case reserved
    case conflicts(String)

    public var errorDescription: String? {
        switch self {
        case .tooSimple: return "请至少按下一个修饰键，或使用功能键"
        case .reserved: return "该组合被系统占用（⌘⇧3/4/5）"
        case .conflicts(let label): return "与「\(label)」冲突"
        }
    }
}

public enum HotkeyValidator {
    public static func validate(
        hotkey: Hotkey,
        conflictsWith existing: [(label: String, hotkey: Hotkey)]
    ) -> HotkeyValidationError? {
        if hotkey.modifiers.isEmpty, !HotkeyFormatter.functionKeyCodes.contains(hotkey.keyCode) {
            return .tooSimple
        }
        let reservedCodes: Set<UInt32> = [20, 21, 23]
        let modifiers = Set(hotkey.modifiers)
        if modifiers == [.cmd, .shift], reservedCodes.contains(hotkey.keyCode) {
            return .reserved
        }
        let canonical = hotkey.canonical()
        if let match = existing.first(where: { $0.hotkey.canonical() == canonical }) {
            return .conflicts(match.label)
        }
        return nil
    }
}
