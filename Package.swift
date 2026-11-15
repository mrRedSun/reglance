// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Reglance",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Reglance", targets: ["Reglance"]),
        .executable(name: "reglance-cli", targets: ["reglance-cli"]),
    ],
    targets: [
        // Claude CLI client, chat model, persistence. No UI.
        .target(name: "ChatCore"),
        // The menu bar app: floating panel, hotkey, main window.
        .executableTarget(
            name: "Reglance",
            dependencies: ["ChatCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Debug entry point that drives ChatCore from the terminal.
        .executableTarget(name: "reglance-cli", dependencies: ["ChatCore"]),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),
        .testTarget(name: "ReglanceTests", dependencies: ["Reglance"],
                    swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
