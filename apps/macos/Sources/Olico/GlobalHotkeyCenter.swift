import AppKit
import Carbon.HIToolbox
import OlicoKit

public final class GlobalHotkeyCenter {
    private let signature: OSType = 0x4F4C4943 // 'OLIC'
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: HotkeyAction] = [:]
    private let lock = NSLock()
    private var isSuspended = false

    public var onAction: ((HotkeyAction) -> Void)?

    public init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    center.dispatch(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    deinit {
        unregisterAll()
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.count
    }

    public func suspend() {
        isSuspended = true
        unregisterAll()
    }

    @discardableResult
    public func resume(config: AppConfig) -> [String: String] {
        isSuspended = false
        return reload(config: config)
    }

    @discardableResult
    public func reload(config: AppConfig) -> [String: String] {
        guard !isSuspended else { return [:] }
        unregisterAll()
        var failures: [String: String] = [:]
        var nextID: UInt32 = 1
        for slot in HotkeySlot.allCases {
            let hotkey = hotkey(for: slot, config: config)
            register(hotkey, action: .builtin(slot), id: nextID, label: slot.label, failures: &failures)
            nextID += 1
        }
        for shortcut in config.shortcuts where shortcut.enabled {
            register(
                shortcut.hotkey,
                action: .app(target: shortcut.target, path: shortcut.path),
                id: nextID,
                label: shortcut.target,
                failures: &failures
            )
            nextID += 1
        }
        for link in config.links where link.enabled {
            register(
                link.hotkey,
                action: .link(id: link.id),
                id: nextID,
                label: link.title,
                failures: &failures
            )
            nextID += 1
        }
        return failures
    }

    private func hotkey(for slot: HotkeySlot, config: AppConfig) -> Hotkey {
        switch slot {
        case .screenshot: return config.hotkeys.screenshot
        case .clipboard: return config.hotkeys.clipboard
        case .colorPicker: return config.hotkeys.colorPicker
        case .togglePins: return config.hotkeys.togglePins
        }
    }

    private func register(
        _ hotkey: Hotkey,
        action: HotkeyAction,
        id: UInt32,
        label: String,
        failures: inout [String: String]
    ) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            carbonModifiers(hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            failures[label] = "注册失败（\(status)），可能被系统或其他应用占用"
            return
        }
        lock.lock()
        registrations[id] = ref
        actions[id] = action
        lock.unlock()
    }

    private func carbonModifiers(_ modifiers: [Modifier]) -> UInt32 {
        modifiers.reduce(0) { partial, modifier in
            switch modifier {
            case .cmd: return partial | UInt32(cmdKey)
            case .opt: return partial | UInt32(optionKey)
            case .ctrl: return partial | UInt32(controlKey)
            case .shift: return partial | UInt32(shiftKey)
            }
        }
    }

    private func dispatch(id: UInt32) {
        lock.lock()
        let action = actions[id]
        lock.unlock()
        guard let action else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }

    public func unregisterAll() {
        lock.lock()
        let refs = registrations.values
        registrations.removeAll()
        actions.removeAll()
        lock.unlock()
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
    }
}
