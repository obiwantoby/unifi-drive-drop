// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DriveDrop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DriveDrop",
            path: "Sources/DriveDrop",
            // Swift 6 mode is on for the app; language mode 5 keeps the
            // URLSession delegate concurrency pragmatic.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
