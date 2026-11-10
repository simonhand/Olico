import SwiftUI
import OlicoKit

struct ClipboardSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var confirmClear = false

    var body: some View {
        SettingsPage(
            title: "剪贴板",
            subtitle: "历史记录只保存在本机，敏感应用可以排除。"
        ) {
            SettingsSectionTitle(text: "历史")
            SettingsCard {
                SettingsRow("记录剪贴板历史") {
                    Toggle("", isOn: $store.config.clipboard.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                stepperRow(
                    "最多保留",
                    value: Binding(
                        get: { Int(store.config.clipboard.maxItems) },
                        set: { store.config.clipboard.maxItems = UInt32($0) }
                    ),
                    range: 10...5000,
                    unit: "条"
                )
                SettingsDivider()
                stepperRow(
                    "保留时间",
                    value: Binding(
                        get: { Int(store.config.clipboard.retentionDays) },
                        set: { store.config.clipboard.retentionDays = UInt32($0) }
                    ),
                    range: 1...365,
                    unit: "天"
                )
                SettingsDivider()
                stepperRow(
                    "单张图片上限",
                    value: Binding(
                        get: { Int(store.config.clipboard.maxImageMb) },
                        set: { store.config.clipboard.maxImageMb = UInt64($0) }
                    ),
                    range: 1...500,
                    unit: "MB"
                )
                SettingsDivider()
                stepperRow(
                    "单条文本上限",
                    value: Binding(
                        get: { Int(store.config.clipboard.maxTextKb) },
                        set: { store.config.clipboard.maxTextKb = UInt64($0) }
                    ),
                    range: 1...8192,
                    unit: "KB"
                )
            }

            SettingsSectionTitle(text: "排除应用")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("com.example.app, com.example.two", text: excludedAppsBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06))
                        }
                    Text("Bundle ID 以逗号分隔。来自这些应用的复制不会写入历史。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            SettingsCard {
                HStack {
                    Button("清空历史…") { confirmClear = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    Spacer()
                    Button("保存") { try? store.saveConfig() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }

            if let error = store.lastError {
                NoticeBanner(text: error, isError: true)
            }
        }
        .alert("清空剪贴板历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clearClipboard() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("未置顶且未加入分类板的条目会被删除。")
        }
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String
    ) -> some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                Text("\(value.wrappedValue) \(unit)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: value, in: range).labelsHidden()
            }
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
