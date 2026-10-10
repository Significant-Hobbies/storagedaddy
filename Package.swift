// swift-tools-version: 6.0
import PackageDescription
import Foundation
let sparkleTestFrameworks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64").path
let package = Package(name: "StorageDaddy", platforms: [.macOS(.v14)], products: [
    .library(name: "DiskCore", targets: ["DiskCore"]),
    .executable(name: "StorageDaddy", targets: ["StorageDaddy"]),
    .executable(name: "StorageBench", targets: ["StorageBench"])
], dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"), .package(url: "https://github.com/sass-maker/app-health", exact: "0.1.0"), .package(url: "https://github.com/sass-maker/ui-library", from: "0.1.14")], targets: [
    .target(name: "DiskCore"),
    .executableTarget(name: "StorageDaddy", dependencies: [.product(name: "SaaSMakerUI", package: "ui-library"), "DiskCore", .product(name: "Sparkle", package: "Sparkle"), .product(name: "AppHealth", package: "app-health")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .executableTarget(name: "StorageBench", dependencies: ["DiskCore"]),
    .testTarget(name: "DiskCoreTests", dependencies: ["DiskCore"]),
    .testTarget(name: "StorageDaddyTests", dependencies: ["StorageDaddy"],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", sparkleTestFrameworks])])
])
