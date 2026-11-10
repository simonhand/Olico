import Foundation

public final class AppLogger {
    private let directory: URL
    private let maxBytes: Int
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "com.olico.logger")

    public init(directory: URL, maxBytes: Int = 5 * 1024 * 1024, maxFiles: Int = 3) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var directoryURL: URL { directory }

    public func log(_ message: String) {
        queue.async { [self] in
            let formatter = ISO8601DateFormatter()
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let current = directory.appendingPathComponent("olico.log")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded(current)
            if let handle = try? FileHandle(forWritingTo: current) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: current, atomically: true, encoding: .utf8)
            }
        }
    }

    private func rotateIfNeeded(_ current: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxBytes else { return }
        let manager = FileManager.default
        if maxFiles > 1 {
            for index in stride(from: maxFiles - 1, through: 1, by: -1) {
                let source = directory.appendingPathComponent(index == 1 ? "olico.log" : "olico.log.\(index - 1)")
                let destination = directory.appendingPathComponent("olico.log.\(index)")
                if manager.fileExists(atPath: source.path) {
                    try? manager.removeItem(at: destination)
                    try? manager.moveItem(at: source, to: destination)
                }
            }
        } else {
            try? manager.removeItem(at: current)
        }
    }
}
