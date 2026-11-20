// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NuvoPlayer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NuvoKit", targets: ["NuvoKit"]),
        .executable(name: "nuvoctl", targets: ["nuvoctl"]),
        .executable(name: "NuvoPlayer", targets: ["NuvoPlayerApp"]),
    ],
    targets: [
        // All protocol logic. No UI, no third-party dependencies.
        .target(name: "NuvoKit"),
        // Command-line tool for poking real hardware.
        .executableTarget(name: "nuvoctl", dependencies: ["NuvoKit"]),
        // SwiftUI macOS app.
        .executableTarget(name: "NuvoPlayerApp", dependencies: ["NuvoKit"]),
        .testTarget(
            name: "NuvoKitTests",
            dependencies: ["NuvoKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
