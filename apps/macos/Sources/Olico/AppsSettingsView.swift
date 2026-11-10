import SwiftUI
import AppKit
import OlicoKit

struct AppsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @Binding var recording: RecordingTarget?

    private var configured: [AppShortcut] {
        store.config.shortcuts.filter(\.enabled)
    }

    var body: some View {
        let filtered = store.filteredApps()
        SettingsPage(
            title: "应用",
            subtitle: "为常用应用分配全局快捷键，按下即可启动或切换。"
        ) {
            if !configured.isEmpty {
                SettingsSectionTitle(text: "已设置")
                SettingsCard {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(configured) { shortcut in
                                HStack(spacing: 7) {
                                    Text(store.name(for: shortcut.target))
                                        .font(.system(size: 12, weight: .medium))
                                    HotkeyKeycaps(hotkey: shortcut.hotkey)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background {
                                    Capsule().fill(Color.accentColor.opacity(0.10))
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }

            SettingsSectionTitle(text: "应用列表")
            SettingsCard {
                HStack(spacing: 10) {
                    SettingsSearchField(text: $store.searchText, placeholder: "搜索应用名称或 Bundle ID")
                    Toggle("仅显示已设置", isOn: $store.onlyConfigured)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                    Button {
                        store.reloadApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("重新扫描应用")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider().padding(.leading, 16)

                if filtered.isEmpty {
                    Text(store.apps.isEmpty ? "没有扫描到应用" : "没有匹配的应用")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { app in
                            AppRow(
                                app: app,
                                shortcut: store.shortcut(for: app.bundleID),
                                failure: store.conflicts[app.bundleID],
                                onRecord: { recording = .app(app) },
                                onClear: { try? store.removeShortcut(bundleID: app.bundleID) }
                            )
                            if app.id != filtered.last?.id {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
            }

            if let error = store.lastError {
                NoticeBanner(text: error, isError: true)
            }
        }
    }
}

private struct AppRow: View {
    let app: AppEntry
    let shortcut: AppShortcut?
    let failure: String?
    let onRecord: () -> Void
    let onClear: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13))
                HStack(spacing: 6) {
                    Text(app.bundleID)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if let failure {
                        Text(failure)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 8)

            if let shortcut {
                HotkeyKeycaps(hotkey: shortcut.hotkey)
                Button("清除", action: onClear)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button(shortcut == nil ? "设置" : "更改", action: onRecord)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.045) : Color.clear)
        .onHover { hovering = $0 }
    }
}
