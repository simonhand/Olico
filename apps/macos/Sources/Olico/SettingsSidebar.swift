import SwiftUI
import OlicoKit

enum SettingsSection: CaseIterable, Identifiable {
    case apps, clipboard, screenshot, general

    var id: Self { self }

    var title: String {
        switch self {
        case .apps: return "应用"
        case .clipboard: return "剪贴板"
        case .screenshot: return "截图"
        case .general: return "通用"
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .screenshot: return "camera.viewfinder"
        case .general: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .apps: return .blue
        case .clipboard: return .purple
        case .screenshot: return .orange
        case .general: return .gray
        }
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Olico")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 46)
                .padding(.bottom, 12)

            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, isSelected: selection == section) {
                    selection = section
                }
            }

            Spacer(minLength: 12)

            Text("v\(AppInfo.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            VisualEffectView(material: .sidebar).ignoresSafeArea()
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [section.tint.opacity(0.78), section.tint],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}
