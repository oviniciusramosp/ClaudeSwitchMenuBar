// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ClaudeSwitchMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClaudeSwitchMenuBar",
            targets: ["ClaudeSwitchMenuBar"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSwitchMenuBar"
        ),
        .testTarget(
            name: "ClaudeSwitchMenuBarTests",
            dependencies: ["ClaudeSwitchMenuBar"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
