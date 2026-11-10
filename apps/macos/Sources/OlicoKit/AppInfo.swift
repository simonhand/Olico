import Foundation

public enum AppInfo {
    public static let bundleIdentifier = "com.olico.app"

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
