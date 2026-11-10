import SwiftUI
import AppKit
import OlicoKit

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CardBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

struct HotkeyKeycaps: View {
    let hotkey: Hotkey

    private var orderedModifiers: [Modifier] {
        let order: [Modifier: Int] = [.cmd: 0, .opt: 1, .ctrl: 2, .shift: 3]
        return Set(hotkey.modifiers).sorted { (order[$0] ?? 9) < (order[$1] ?? 9) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(orderedModifiers, id: \.self) { modifier in
                Keycap(text: HotkeyFormatter.symbol(for: modifier))
            }
            Keycap(text: HotkeyFormatter.keyName(for: hotkey.keyCode), wide: true)
        }
    }
}

private struct Keycap: View {
    let text: String
    var wide = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, wide ? 7 : 6)
            .frame(minWidth: 22, minHeight: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 1)
    }
}

struct SettingsSearchField: View {
    @Binding var text: String
    var placeholder = "搜索"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct NoticeBanner: View {
    let text: String
    var isError = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text)
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? Color.red : Color.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((isError ? Color.red : Color.green).opacity(0.09))
        }
    }
}
