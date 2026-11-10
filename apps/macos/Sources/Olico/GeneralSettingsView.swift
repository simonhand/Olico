import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import UniformTypeIdentifiers
import OlicoKit

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    let launchAgent: LaunchAgent
    let logger: AppLogger
    @Binding var recording: RecordingTarget?

    @State private var launchAtLogin = false
    @State private var agentEnabled = false
    @State private var pendingImport: AppConfig?
    @State private var showImportConfirm = false
    @State private var notice: TransferNotice?

    var body: some View {
        SettingsPage(
            title: "通用",
            subtitle: "内置快捷键、后台常驻、系统权限与配置迁移。"
        ) {
            SettingsSectionTitle(text: "内置快捷键")
            SettingsCard {
                ForEach(HotkeySlot.allCases) { slot in
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRow(slot.label) {
                            HStack(spacing: 8) {
                                HotkeyKeycaps(hotkey: hotkey(for: slot))
                                Button("录制") { recording = .builtin(slot) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        if let failure = store.conflicts[slot.label] {
                            Text(failure)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                                .padding(.leading, 16)
                                .padding(.bottom, 6)
                        }
                    }
                    if slot != HotkeySlot.allCases.last {
                        SettingsDivider()
                    }
                }
            }

            SettingsSectionTitle(text: "常驻")
            SettingsCard {
                SettingsRow("登录时启动", subtitle: "由 launchd 托管，崩溃后自动拉起。") {
                    Toggle("", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow("守护状态") {
                    StatusPill(text: agentStatusText, color: agentStatusColor)
                }
            }

            SettingsSectionTitle(text: "权限")
            SettingsCard {
                permissionRow(
                    title: "辅助功能",
                    granted: AXIsProcessTrusted(),
                    request: {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                    },
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                SettingsDivider()
                permissionRow(
                    title: "屏幕录制",
                    granted: CGPreflightScreenCaptureAccess(),
                    request: { _ = CGRequestScreenCaptureAccess() },
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
                Divider().padding(.leading, 16)
                Text("截图与取色需要屏幕录制权限；控件识别与自动粘贴需要辅助功能权限。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(16)
            }

            SettingsSectionTitle(text: "配置")
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("导出或导入全部设置。配置文件只包含快捷键与偏好，不含剪贴板内容和截图。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            importConfiguration()
                        } label: {
                            Label("导入…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            exportConfiguration()
                        } label: {
                            Label("导出…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let notice {
                        NoticeBanner(text: notice.text, isError: notice.isError)
                    }
                }
                .padding(12)
            }

            SettingsSectionTitle(text: "其他")
            SettingsCard {
                SettingsRow("版本") {
                    Text(AppInfo.version)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow("日志") {
                    Button("打开日志目录") {
                        NSWorkspace.shared.open(logger.directoryURL)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            launchAtLogin = store.config.residency.launchAtLogin
            refreshAgent()
        }
        .alert("导入配置？", isPresented: $showImportConfirm) {
            Button("覆盖并导入", role: .destructive) { applyImport() }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: {
            Text("当前全部设置将被文件中的配置替换。")
        }
    }

    private var agentStatusText: String {
        if agentEnabled { return "常驻中" }
        return launchAtLogin ? "未生效" : "已关闭"
    }

    private var agentStatusColor: Color {
        if agentEnabled { return .green }
        return launchAtLogin ? .orange : .secondary
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

    private func permissionRow(
        title: String,
        granted: Bool,
        request: @escaping () -> Void,
        settingsURL: String
    ) -> some View {
        SettingsRow(title) {
            HStack(spacing: 10) {
                StatusPill(text: granted ? "已授权" : "未授权", color: granted ? .green : .orange)
                Button("打开系统设置") {
                    // Ask the system first so Olico is registered in the pane;
                    // after a TCC reset the app is absent from the list.
                    if !granted { request() }
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "olicoconfig.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ConfigTransfer.encode(store.config)
            try data.write(to: url, options: .atomic)
            notice = TransferNotice(text: "已导出到 \(url.lastPathComponent)", isError: false)
        } catch {
            notice = TransferNotice(text: "导出失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let config = try ConfigTransfer.decode(Data(contentsOf: url))
            pendingImport = config
            showImportConfirm = true
        } catch {
            notice = TransferNotice(text: "导入失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func applyImport() {
        guard let config = pendingImport else { return }
        do {
            try store.importConfig(config, agent: launchAgent)
            launchAtLogin = store.config.residency.launchAtLogin
            refreshAgent()
            notice = TransferNotice(text: "已导入配置", isError: false)
        } catch {
            notice = TransferNotice(text: "导入失败：\(error.localizedDescription)", isError: true)
        }
        pendingImport = nil
    }
}

private struct TransferNotice {
    let text: String
    let isError: Bool
}
