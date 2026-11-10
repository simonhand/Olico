import AppKit

public enum LinkLauncher {
    public static let chromeBundleID = "com.google.Chrome"

    public static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    public static func open(_ url: URL) {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
