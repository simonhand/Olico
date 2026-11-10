import AppKit
import ApplicationServices
import SwiftUI
import OlicoKit

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var query = ""
    @Published var items: [ClipboardItem] = []
    @Published var selectedIndex = 0
    @Published var toast: String?

    var onChoose: ((ClipboardItem) -> Void)?

    private let client: CoreClient
    private var toastWorkItem: DispatchWorkItem?

    init(client: CoreClient) {
        self.client = client
    }

    func reload(resetSelection: Bool = false) {
        do {
            let result = try client.clipboardList(text: query, limit: 200)
            items = result
            if resetSelection {
                selectedIndex = 0
            } else {
                selectedIndex = min(selectedIndex, max(result.count - 1, 0))
            }
        } catch {
            showToast("读取剪贴板失败：\(error.localizedDescription)")
        }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + delta))
    }

    func chooseSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        onChoose?(items[selectedIndex])
    }

    func choose(_ item: ClipboardItem) {
        onChoose?(item)
    }

    func select(index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    func togglePin(_ item: ClipboardItem) {
        do {
            try client.clipboardPin(id: item.id, pinned: !item.pinned)
            reload()
        } catch {
            showToast("置顶失败：\(error.localizedDescription)")
        }
    }

    func delete(_ item: ClipboardItem) {
        do {
            try client.clipboardDelete(id: item.id)
            reload()
        } catch {
            showToast("删除失败：\(error.localizedDescription)")
        }
    }

    func showToast(_ text: String) {
        toastWorkItem?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func clearToast() {
        toastWorkItem?.cancel()
        toast = nil
    }
}

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let viewModel: ClipboardViewModel
    private let logger: AppLogger
    private var panel: ClipboardPanel?
    private var keyMonitor: Any?
    // Must be strong: NSWorkspace drops its NSRunningApplication instance for
    // an app as soon as it stops being frontmost, which happens right after we
    // activate the panel. A weak reference goes nil before the user hits Enter.
    private var previousApp: NSRunningApplication?
    private var shownAt = Date.distantPast

    init(client: CoreClient, logger: AppLogger) {
        let viewModel = ClipboardViewModel(client: client)
        self.viewModel = viewModel
        self.logger = logger
        super.init()
        viewModel.onChoose = { [weak self] item in
            self?.performPaste(item)
        }
    }

    func toggle() {
        if panel?.isVisible == true {
            hidePanel(reactivatePrevious: true)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        viewModel.query = ""
        viewModel.clearToast()
        viewModel.reload(resetSelection: true)
        installKeyMonitor()
        NSRunningApplication.current.activate(
            options: [.activateAllWindows, .activateIgnoringOtherApps]
        )
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        logger.log("clipboard panel show prev=\(previousApp?.bundleIdentifier ?? "nil")")
    }

    func hidePanel(reactivatePrevious: Bool = false) {
        removeKeyMonitor()
        panel?.orderOut(nil)
        if reactivatePrevious {
            previousApp?.activate()
        }
        logger.log("clipboard panel hide")
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: ClipboardPanelView(viewModel: viewModel)
        )
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - panel.frame.height - 110
        ))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            switch event.keyCode {
            case 126:
                self.viewModel.move(-1)
                return nil
            case 125:
                self.viewModel.move(1)
                return nil
            case 36, 76:
                self.viewModel.chooseSelected()
                return nil
            case 53:
                self.hidePanel(reactivatePrevious: true)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func performPaste(_ item: ClipboardItem) {
        guard write(item) else {
            viewModel.showToast("无法写入剪贴板")
            return
        }
        guard AXIsProcessTrusted() else {
            logger.log("clipboard paste: accessibility not trusted, copied only")
            viewModel.showToast("已复制，切换到目标窗口按 ⌘V 粘贴（授权辅助功能后可自动粘贴）")
            let previous = previousApp
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                self?.hidePanel()
                previous?.activate(options: [.activateAllWindows])
            }
            return
        }
        guard let target = previousApp else {
            logger.log("clipboard paste: no target app, copied only")
            viewModel.showToast("已复制到剪贴板")
            return
        }
        logger.log("clipboard paste: target=\(target.bundleIdentifier ?? "unknown")")
        hidePanel()
        pasteWhenActive(target, attemptsLeft: 8)
    }

    // Activation is asynchronous, and posting ⌘V before the target app regains
    // focus would paste into whatever happens to be frontmost instead.
    private func pasteWhenActive(_ target: NSRunningApplication, attemptsLeft: Int) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            Self.postCommandV()
            return
        }
        guard attemptsLeft > 0 else {
            logger.log("paste skipped: target app did not become frontmost")
            return
        }
        target.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.pasteWhenActive(target, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func write(_ item: ClipboardItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            return pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            guard let path = item.imagePath, let image = NSImage(contentsOfFile: path) else {
                return false
            }
            return pasteboard.writeObjects([image])
        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            return pasteboard.writeObjects(urls)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel?.isVisible == true else { return }
        // Activation settles asynchronously; ignore the transient resign that
        // happens while the panel is still coming to front.
        guard Date().timeIntervalSince(shownAt) > 0.5 else { return }
        logger.log("clipboard panel resign key")
        hidePanel(reactivatePrevious: false)
    }
}

private struct ClipboardPanelView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @FocusState private var searchFocused: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索剪贴板历史", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                Text("\(viewModel.items.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider().opacity(0.4)

            HStack(spacing: 0) {
                listColumn
                    .frame(width: 300)
                Divider().opacity(0.4)
                previewColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().opacity(0.4)

            HStack(spacing: 14) {
                hint("↑↓", "选择")
                hint("↵", "直接粘贴")
                hint("双击", "粘贴")
                hint("esc", "关闭")
                if !AXIsProcessTrusted() {
                    Text("辅助功能未授权，↵ 暂只复制")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("⌘⇧V")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .frame(width: 780, height: 480)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10))
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toast {
                Text(toast)
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 42)
            }
        }
        .onAppear { searchFocused = true }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.reload(resetSelection: true)
        }
    }

    private var selectedItem: ClipboardItem? {
        guard viewModel.items.indices.contains(viewModel.selectedIndex) else { return nil }
        return viewModel.items[viewModel.selectedIndex]
    }

    @ViewBuilder private var listColumn: some View {
        if viewModel.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clipboard")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            ClipboardRow(
                                item: item,
                                selected: index == viewModel.selectedIndex,
                                relativeTime: relativeTime(for: item),
                                onSelect: { viewModel.select(index: index) },
                                onChoose: {
                                    viewModel.select(index: index)
                                    viewModel.choose(item)
                                },
                                onPin: { viewModel.togglePin(item) },
                                onDelete: { viewModel.delete(item) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: viewModel.selectedIndex) { _, index in
                    guard viewModel.items.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(viewModel.items[index].id)
                    }
                }
            }
        }
    }

    @ViewBuilder private var previewColumn: some View {
        if let item = selectedItem {
            ClipboardPreview(item: item, relativeTime: relativeTime(for: item))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("选择左侧条目查看预览")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("按 ↵ 直接粘贴到当前输入框")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyText: String {
        if !viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "没有匹配的记录"
        }
        return "复制一些内容后会出现在这里"
    }

    private func relativeTime(for item: ClipboardItem) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000)
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ClipboardPreview: View {
    let item: ClipboardItem
    let relativeTime: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            previewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(kindLabel)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.primary.opacity(0.07), in: Capsule())
            if let source = item.sourceName, !source.isEmpty {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let detailLabel {
                Text(detailLabel)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Text(relativeTime)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder private var previewBody: some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        case .image:
            if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            } else {
                missingPreview("图片文件已不可用")
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.filePaths, id: \.self) { path in
                        HStack(alignment: .top, spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(path)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    private var detailLabel: String? {
        switch item.kind {
        case .text:
            let count = (item.text ?? "").count
            return count > 0 ? "\(count) 字符" : nil
        case .image, .file:
            guard item.byteSize > 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)
        }
    }

    private func missingPreview(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let selected: Bool
    let relativeTime: String
    let onSelect: () -> Void
    let onChoose: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preview)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let source = item.sourceName, !source.isEmpty {
                            Text(source)
                        }
                        Text(relativeTime)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onChoose)
            .onTapGesture(count: 1, perform: onSelect)

            Button(action: onPin) {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5))
                    .foregroundStyle(item.pinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(item.pinned ? "取消置顶" : "置顶")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if item.kind == .image, let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
        }
    }

    private var systemImage: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private var preview: String {
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            return text.replacingOccurrences(of: "\n", with: " ")
        case .image:
            return "图片"
        case .file:
            return item.filePaths
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: ", ")
        }
    }
}
