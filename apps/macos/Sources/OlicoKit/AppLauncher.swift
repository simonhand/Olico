import AppKit

public enum AppLaunchError: Error, LocalizedError {
    case notFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let target): return "未找到应用 \(target)"
        case .launchFailed(let reason): return "启动失败：\(reason)"
        }
    }
}

public enum AppLauncher {
    public static func activateOrLaunch(_ entry: AppEntry) throws {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first {
            running.unhide()
            if running.activate(options: [.activateAllWindows]) {
                return
            }
        }
        let url = URL(fileURLWithPath: entry.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppLaunchError.notFound(entry.name)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            failure = error
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            throw AppLaunchError.launchFailed(failure.localizedDescription)
        }
    }
}
