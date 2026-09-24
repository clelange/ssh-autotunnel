// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ssh-autotunnel",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "SSHAutoTunnelCore", targets: ["SSHAutoTunnelCore"]),
        .executable(name: "SSHAutoTunnel", targets: ["SSHAutoTunnelApp"]),
        .executable(name: "ssh-autotunnelctl", targets: ["SSHAutoTunnelCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "SSHAutoTunnelCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN")
            ]
        ),
        .executableTarget(
            name: "SSHAutoTunnelApp",
            dependencies: ["SSHAutoTunnelCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AppIntents"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "SSHAutoTunnelCLI",
            dependencies: ["SSHAutoTunnelCore"]
        ),
        .testTarget(
            name: "SSHAutoTunnelCoreTests",
            dependencies: ["SSHAutoTunnelCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
