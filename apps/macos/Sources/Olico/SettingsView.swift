import SwiftUI
import AppKit
import OlicoKit

enum RecordingTarget: Identifiable {
    case builtin(HotkeySlot)
    case app(AppEntry)

    var id: String {
        switch self {
        case .builtin(let slot): return "builtin-\(slot.rawValue)"
        case .app(let app): return "app-\(app.bundleID)"
        }
    }

    var title: String {
        switch self {
        case .builtin(let slot): return "录制「\(slot.label)」快捷键"
        case .app(let app): return "录制「\(app.name)」快捷键"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let launchAgent: LaunchAgent
    let logger: AppLogger

    @State private var selection: SettingsSection = SettingsView.initialSection()
    @State private var recording: RecordingTarget?

    // TEMP screenshot hook
    private static func initialSection() -> SettingsSection {
        switch ProcessInfo.processInfo.environment["OLICO_DEBUG_SECTION"] {
        case "clipboard": return .clipboard
        case "screenshot": return .screenshot
        case "general": return .general
        default: return .apps
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    VisualEffectView(material: .underWindowBackground).ignoresSafeArea()
                }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(item: $recording) { target in
            HotkeyRecorderView(title: target.title) { hotkey in
                switch target {
                case .builtin(let slot): try store.setBuiltinHotkey(slot, hotkey)
                case .app(let app): try store.setShortcut(app: app, hotkey: hotkey)
                }
                recording = nil
            } onCancel: {
                recording = nil
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .apps:
            AppsSettingsView(store: store, recording: $recording)
        case .clipboard:
            ClipboardSettingsView(store: store)
        case .screenshot:
            ScreenshotSettingsView(store: store)
        case .general:
            GeneralSettingsView(store: store, launchAgent: launchAgent, logger: logger, recording: $recording)
        }
    }
}
