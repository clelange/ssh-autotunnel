// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ssh-autotunnel",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SSHAutoTunnelCore", targets: ["SSHAutoTunnelCore"]),
        .executable(name: "SSHAutoTunnel", targets: ["SSHAutoTunnelApp"]),
        .executable(name: "ssh-autotunnelctl", targets: ["SSHAutoTunnelCLI"])
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
            dependencies: ["SSHAutoTunnelCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AppIntents")
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
    ]
)
