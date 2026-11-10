import Foundation

public struct AppEntry: Identifiable, Equatable, Hashable {
    public let bundleID: String
    public let name: String
    public let path: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

public final class AppCatalog {
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    private let roots: [URL]
    private let maxDepth: Int
    private let ttl: TimeInterval
    private var cached: [AppEntry] = []
    private var cachedAt: Date?

    public init(roots: [URL] = AppCatalog.defaultRoots, maxDepth: Int = 3, ttl: TimeInterval = 300) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.ttl = ttl
    }

    public func invalidate() {
        cachedAt = nil
    }

    public func scan(force: Bool = false) -> [AppEntry] {
        if !force, let cachedAt, Date().timeIntervalSince(cachedAt) < ttl {
            return cached
        }
        var entries: [AppEntry] = []
        var indexByBundleID: [String: Int] = [:]
        var depthByBundleID: [String: Int] = [:]

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let relativeDepth = url.pathComponents.count - root.pathComponents.count
                if relativeDepth > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()
                guard let entry = makeEntry(at: url) else { continue }

                if let index = indexByBundleID[entry.bundleID] {
                    if relativeDepth < depthByBundleID[entry.bundleID] ?? .max {
                        entries[index] = entry
                        depthByBundleID[entry.bundleID] = relativeDepth
                    }
                } else {
                    indexByBundleID[entry.bundleID] = entries.count
                    depthByBundleID[entry.bundleID] = relativeDepth
                    entries.append(entry)
                }
            }
        }

        cached = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedAt = Date()
        return cached
    }

    public func entry(for bundleID: String) -> AppEntry? {
        scan().first { $0.bundleID == bundleID }
    }

    private func makeEntry(at url: URL) -> AppEntry? {
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty
        else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(bundleID: bundleID, name: name, path: url.path)
    }
}
