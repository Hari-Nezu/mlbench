// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "mlbench",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "mlbench",
            path: "Sources/mlbench",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
