// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExportsSyncer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ExportsSyncer",
            path: "Sources/ExportsSyncer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
