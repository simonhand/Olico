import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
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

    @State private var recording: RecordingTarget?
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            AppsSettingsView(store: store, recording: $recording)
                .tabItem { Label("应用", systemImage: "square.grid.2x2") }
                .tag(0)
            ClipboardSettingsView(store: store)
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }
                .tag(1)
            ScreenshotSettingsView(store: store)
                .tabItem { Label("截图", systemImage: "camera.viewfinder") }
                .tag(2)
            GeneralSettingsView(store: store, launchAgent: launchAgent, logger: logger, recording: $recording)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(3)
        }
        .padding(12)
        .frame(minWidth: 860, minHeight: 560)
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
}

private struct AppsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @Binding var recording: RecordingTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            configuredOverview
            HStack(spacing: 8) {
                TextField("搜索应用名称或 Bundle ID", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle("仅显示已设置", isOn: $store.onlyConfigured)
                Button("刷新") { store.reloadApps() }
            }
            List(store.filteredApps()) { app in
                row(for: app)
            }
            .listStyle(.inset)
            .overlay {
                if store.apps.isEmpty {
                    Text("没有扫描到应用").foregroundStyle(.secondary)
                } else if store.filteredApps().isEmpty {
                    Text("没有匹配的应用").foregroundStyle(.secondary)
                }
            }
            if let error = store.lastError {
                ErrorBanner(message: error)
            }
        }
    }

    @ViewBuilder private var configuredOverview: some View {
        let configured = store.config.shortcuts.filter(\.enabled)
        if !configured.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(configured) { shortcut in
                        HStack(spacing: 6) {
                            Text(store.name(for: shortcut.target))
                            Text(HotkeyFormatter.display(shortcut.hotkey))
                                .font(.caption)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func row(for app: AppEntry) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                if let failure = store.conflicts[app.bundleID] {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let shortcut = store.shortcut(for: app.bundleID) {
                Text(HotkeyFormatter.display(shortcut.hotkey))
                    .font(.body)
                Button("清除") { try? store.removeShortcut(bundleID: app.bundleID) }
            }
            Button("录制") { recording = .app(app) }
        }
        .padding(.vertical, 2)
    }
}

private struct ClipboardSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("历史") {
                Toggle("记录剪贴板历史", isOn: $store.config.clipboard.enabled)
                Stepper(
                    "最多保留 \(store.config.clipboard.maxItems) 条",
                    value: $store.config.clipboard.maxItems,
                    in: 10...5000
                )
                Stepper(
                    "保留 \(store.config.clipboard.retentionDays) 天",
                    value: $store.config.clipboard.retentionDays,
                    in: 1...365
                )
                Stepper(
                    "单张图片上限 \(store.config.clipboard.maxImageMb) MB",
                    value: $store.config.clipboard.maxImageMb,
                    in: 1...500
                )
                Stepper(
                    "单条文本上限 \(store.config.clipboard.maxTextKb) KB",
                    value: $store.config.clipboard.maxTextKb,
                    in: 1...8192
                )
            }
            Section("排除应用") {
                TextField("Bundle ID，逗号分隔", text: excludedAppsBinding)
            }
            Section {
                HStack {
                    Button("清空历史…") { confirmClear = true }
                    Spacer()
                    Button("保存") { try? store.saveConfig() }
                }
                if let error = store.lastError {
                    ErrorBanner(message: error)
                }
            }
        }
        .formStyle(.grouped)
        .alert("清空剪贴板历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clearClipboard() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("未置顶且未加入分类板的条目会被删除。")
        }
    }

    private var excludedAppsBinding: Binding<String> {
        Binding(
            get: { store.config.clipboard.excludedApps.joined(separator: ", ") },
            set: { text in
                store.config.clipboard.excludedApps = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

private struct ScreenshotSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("保存") {
                HStack {
                    TextField("保存目录", text: $store.config.screenshot.saveDir)
                    Button("选择…") { chooseDirectory() }
                }
            }
            Section("取色") {
                Picker("颜色格式", selection: $store.config.screenshot.colorFormat) {
                    ForEach(ColorFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
            }
            Section("贴图") {
                Toggle("唤醒后恢复贴图", isOn: $store.config.screenshot.restorePins)
            }
            Section {
                HStack {
                    Spacer()
                    Button("保存") { try? store.saveConfig() }
                }
                if let error = store.lastError {
                    ErrorBanner(message: error)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: store.config.screenshot.saveDir)
        if panel.runModal() == .OK, let url = panel.url {
            store.config.screenshot.saveDir = url.path
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    let launchAgent: LaunchAgent
    let logger: AppLogger
    @Binding var recording: RecordingTarget?

    @State private var launchAtLogin = false
    @State private var agentEnabled = false

    var body: some View {
        Form {
            Section("内置快捷键") {
                ForEach(HotkeySlot.allCases) { slot in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(slot.label)
                            Spacer()
                            Text(HotkeyFormatter.display(hotkey(for: slot)))
                                .font(.body)
                            Button("录制") { recording = .builtin(slot) }
                        }
                        if let failure = store.conflicts[slot.label] {
                            Text(failure).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section("常驻") {
                Toggle("登录时启动", isOn: launchAtLoginBinding)
                HStack {
                    Text("守护状态")
                    Spacer()
                    Text(agentStatusText)
                        .foregroundStyle(agentEnabled ? Color.green : Color.secondary)
                }
                if let error = store.lastError {
                    ErrorBanner(message: error)
                }
            }
            Section("权限") {
                permissionRow(
                    title: "辅助功能",
                    granted: AXIsProcessTrusted(),
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                permissionRow(
                    title: "屏幕录制",
                    granted: CGPreflightScreenCaptureAccess(),
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
                Text("截图与取色需要屏幕录制权限；控件识别与自动粘贴需要辅助功能权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("其他") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(AppInfo.version).foregroundStyle(.secondary)
                }
                Button("打开日志目录") { NSWorkspace.shared.open(logger.directoryURL) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = store.config.residency.launchAtLogin
            refreshAgent()
        }
    }

    private var agentStatusText: String {
        if agentEnabled { return "常驻中（崩溃自动拉起）" }
        return launchAtLogin ? "未生效" : "已关闭"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                do {
                    try store.setLaunchAtLogin(newValue, agent: launchAgent)
                } catch {
                    launchAtLogin = store.config.residency.launchAtLogin
                }
                refreshAgent()
            }
        )
    }

    private func hotkey(for slot: HotkeySlot) -> Hotkey {
        switch slot {
        case .screenshot: return store.config.hotkeys.screenshot
        case .clipboard: return store.config.hotkeys.clipboard
        case .colorPicker: return store.config.hotkeys.colorPicker
        case .togglePins: return store.config.hotkeys.togglePins
        }
    }

    private func refreshAgent() {
        agentEnabled = launchAgent.isEnabled()
    }

    private func permissionRow(title: String, granted: Bool, settingsURL: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "已授权" : "未授权")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Button("打开系统设置") {
                if let url = URL(string: settingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
    }
}
