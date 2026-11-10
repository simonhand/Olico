import SwiftUI
import AppKit
import OlicoKit

struct LinksSettingsView: View {
    @ObservedObject var store: SettingsStore
    let hotkeyCenter: GlobalHotkeyCenter

    @State private var showingNew = false
    @State private var editing: LinkShortcut?

    private var links: [LinkShortcut] {
        store.config.links.filter(\.enabled)
    }

    var body: some View {
        SettingsPage(
            title: "链接",
            subtitle: "为常用网址分配全局快捷键，按下即可用 Chrome 打开。"
        ) {
            SettingsCard {
                SettingsRow("链接列表", subtitle: "按下快捷键会用 Chrome 打开对应网址") {
                    Button {
                        showingNew = true
                    } label: {
                        Label("添加链接", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider().padding(.leading, 16)

                if links.isEmpty {
                    Text("还没有链接，点击「添加链接」开始。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(links) { link in
                            LinkRow(
                                link: link,
                                failure: store.conflicts[link.title],
                                onEdit: { editing = link },
                                onDelete: { try? store.removeLink(id: link.id) }
                            )
                            if link.id != links.last?.id {
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
        .sheet(isPresented: $showingNew) {
            LinkEditorSheet(store: store, hotkeyCenter: hotkeyCenter, existing: nil)
        }
        .sheet(item: $editing) { link in
            LinkEditorSheet(store: store, hotkeyCenter: hotkeyCenter, existing: link)
        }
    }
}

private struct LinkRow: View {
    let link: LinkShortcut
    let failure: String?
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.green)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .font(.system(size: 13))
                HStack(spacing: 6) {
                    Text(link.url)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let failure {
                        Text(failure)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 8)

            HotkeyKeycaps(hotkey: link.hotkey)
            Button("删除", action: onDelete)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("更改", action: onEdit)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.045) : Color.clear)
        .onHover { hovering = $0 }
    }
}

private struct LinkEditorSheet: View {
    @ObservedObject var store: SettingsStore
    let hotkeyCenter: GlobalHotkeyCenter
    let existing: LinkShortcut?

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var url: String
    @State private var isRecording = false
    @State private var errorText: String?

    init(store: SettingsStore, hotkeyCenter: GlobalHotkeyCenter, existing: LinkShortcut?) {
        _store = ObservedObject(wrappedValue: store)
        self.hotkeyCenter = hotkeyCenter
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _url = State(initialValue: existing?.url ?? "")
    }

    var body: some View {
        Group {
            if isRecording {
                HotkeyRecorderView(title: "录制「\(title.trimmingCharacters(in: .whitespacesAndNewlines))」快捷键") { hotkey in
                    try store.saveLink(id: existing?.id, title: title, url: url, hotkey: hotkey)
                    dismiss()
                } onCancel: {
                    isRecording = false
                }
                // Carbon hotkeys consume their chord process-wide, so the
                // assigned one could not be re-recorded while still registered.
                .onAppear { hotkeyCenter.suspend() }
                .onDisappear {
                    store.conflicts = hotkeyCenter.resume(config: store.persistedConfig())
                }
            } else {
                form
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "添加链接" : "编辑链接")
                .font(.system(size: 15, weight: .semibold))

            labeledField("名称", placeholder: "例如：团队文档", text: $title)
            labeledField("链接", placeholder: "https://example.com", text: $url)

            if let errorText {
                NoticeBanner(text: errorText, isError: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                if let existing {
                    Button("更改快捷键") {
                        if validate() { isRecording = true }
                    }
                    .buttonStyle(.bordered)
                    Button("保存") {
                        guard validate() else { return }
                        do {
                            try store.saveLink(id: existing.id, title: title, url: url, hotkey: existing.hotkey)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步：录制快捷键") {
                        if validate() { isRecording = true }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    @discardableResult
    private func validate() -> Bool {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorText = LinkValidationError.emptyTitle.localizedDescription
            return false
        }
        if LinkLauncher.normalizedURL(url) == nil {
            errorText = LinkValidationError.invalidURL.localizedDescription
            return false
        }
        errorText = nil
        return true
    }
}
