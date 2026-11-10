// swift-tools-version:5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorDir = "\(packageDir)/Vendor"

let package = Package(
    name: "Olico",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Olico", targets: ["Olico"]),
        .library(name: "OlicoKit", targets: ["OlicoKit"]),
    ],
    targets: [
        .target(
            name: "COlicoFFI",
            path: "Sources/COlicoFFI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OlicoKit",
            dependencies: ["COlicoFFI"],
            path: "Sources/OlicoKit",
            linkerSettings: [.unsafeFlags(["-L\(vendorDir)", "-lolico_ffi"])]
        ),
        .executableTarget(
            name: "Olico",
            dependencies: ["OlicoKit"],
            path: "Sources/Olico",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OlicoKitTests",
            dependencies: ["OlicoKit"],
            path: "Tests/OlicoKitTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
