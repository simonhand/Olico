import Foundation
import Darwin

public enum LaunchAgentStatus: String {
    case enabled, disabled, unknown
}

public struct LaunchAgent {
    public static let label = "com.olico.app"

    public let plistURL: URL
    public let executablePath: String

    public init(plistURL: URL, executablePath: String) {
        self.plistURL = plistURL
        self.executablePath = executablePath
    }

    public static func defaultPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public func plistContents() -> String {
        let escaped = executablePath
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(Self.label)</string>
          <key>ProgramArguments</key>
          <array><string>\(escaped)</string><string>--login-item</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key>
          <dict><key>SuccessfulExit</key><false/></dict>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
    }

    public func install() throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plistContents().write(to: plistURL, atomically: true, encoding: .utf8)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        let status = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        if status != 0 {
            throw NSError(domain: "Olico.LaunchAgent", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "launchctl bootstrap 失败（\(status)）",
            ])
        }
    }

    public func uninstall() throws {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public func isEnabled() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(Self.label)"]) == 0
    }

    public func installedExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
