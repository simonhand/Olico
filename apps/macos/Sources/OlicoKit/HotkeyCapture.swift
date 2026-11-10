import AppKit

public enum HotkeyCapture {
    public static let cancelKeyCode: UInt32 = 53

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> [Modifier] {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [Modifier] = []
        if flags.contains(.command) { modifiers.append(.cmd) }
        if flags.contains(.option) { modifiers.append(.opt) }
        if flags.contains(.control) { modifiers.append(.ctrl) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        return modifiers
    }

    public static func hotkey(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Hotkey? {
        guard keyCode != cancelKeyCode else { return nil }
        return Hotkey(keyCode: keyCode, modifiers: modifiers(from: flags))
    }
}
