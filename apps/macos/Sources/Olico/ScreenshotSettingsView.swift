import SwiftUI
import AppKit
import OlicoKit

struct ScreenshotSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage(
            title: "截图",
            subtitle: "保存位置、取色格式与唤醒后的贴图恢复。"
        ) {
            SettingsSectionTitle(text: "保存")
            SettingsCard {
                SettingsRow("保存目录") {
                    HStack(spacing: 8) {
                        TextField("~/Pictures/Olico", text: $store.config.screenshot.saveDir)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(width: 260, height: 28)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06))
                            }
                        Button("选择…") { chooseDirectory() }
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
            }

            SettingsSectionTitle(text: "取色")
            SettingsCard {
                SettingsRow("颜色格式") {
                    Picker("", selection: $store.config.screenshot.colorFormat) {
                        ForEach(ColorFormat.allCases) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            SettingsSectionTitle(text: "贴图")
            SettingsCard {
                SettingsRow("唤醒后恢复贴图", subtitle: "屏幕重新连接或系统唤醒时，重新显示上次的贴图。") {
                    Toggle("", isOn: $store.config.screenshot.restorePins)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            SettingsCard {
                HStack {
                    Text("修改保存目录、取色格式或贴图设置后，点击保存生效。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(
            fileURLWithPath: (store.config.screenshot.saveDir as NSString).expandingTildeInPath
        )
        if panel.runModal() == .OK, let url = panel.url {
            store.config.screenshot.saveDir = url.path
        }
    }
}
