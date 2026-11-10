import XCTest
@testable import OlicoKit

final class AppCatalogTests: XCTestCase {
    private func makeApp(root: URL, relative: String, bundleID: String, name: String) throws {
        let app = root.appendingPathComponent(relative)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testScansAndDedupesByBundleID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp(root: root, relative: "A.app", bundleID: "com.example.a", name: "Alpha")
        try makeApp(root: root, relative: "sub/B.app", bundleID: "com.example.a", name: "Alpha Copy")
        try makeApp(root: root, relative: "C.app", bundleID: "com.example.c", name: "Gamma")

        let catalog = AppCatalog(roots: [root], maxDepth: 3, ttl: 60)
        let apps = catalog.scan(force: true)
        XCTAssertEqual(apps.map(\.bundleID), ["com.example.a", "com.example.c"])
        XCTAssertEqual(apps.first?.name, "Alpha")
    }

    func testDepthLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp(root: root, relative: "a/b/c/Deep.app", bundleID: "com.example.deep", name: "Deep")
        let catalog = AppCatalog(roots: [root], maxDepth: 2, ttl: 60)
        XCTAssertTrue(catalog.scan(force: true).isEmpty)
    }

    func testNameFallsBackToFileStem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("NoName.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.noname"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        let catalog = AppCatalog(roots: [root], maxDepth: 3, ttl: 60)
        XCTAssertEqual(catalog.scan(force: true).first?.name, "NoName")
    }

    func testAppBundlePathCanBeUsedAsRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeApp(root: root, relative: "Finderish.app", bundleID: "com.example.finderish", name: "Finderish")
        let app = root.appendingPathComponent("Finderish.app")
        let catalog = AppCatalog(roots: [app], maxDepth: 3, ttl: 60)
        let apps = catalog.scan(force: true)
        XCTAssertEqual(apps.map(\.bundleID), ["com.example.finderish"])
    }

    func testDefaultRootsIncludeCoreServicesApps() {
        XCTAssertTrue(AppCatalog.defaultRoots.contains(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")))
        XCTAssertTrue(AppCatalog.defaultRoots.contains(URL(fileURLWithPath: "/System/Library/CoreServices/Applications")))
    }
}
