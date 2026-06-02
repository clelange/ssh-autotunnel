import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class InteractiveTerminalDiscoveryTests: XCTestCase {
    func testDiscoversSupportedTerminalBundleIdentifiers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = directory.appendingPathComponent("Applications", isDirectory: true)
        let ghostty = try makeApp(
            "Ghostty.app",
            bundleIdentifier: "com.mitchellh.ghostty",
            in: applications
        )
        let iterm = try makeApp(
            "Nested/iTerm.app",
            bundleIdentifier: "com.googlecode.iterm2",
            in: applications
        )
        let discovery = InteractiveTerminalDiscovery(searchRoots: [applications])

        let installations = discovery.discoverInstalledTerminals()

        XCTAssertEqual(installations.map(\.app), [.iTerm2, .ghostty])
        XCTAssertEqual(installations.first { $0.app == .ghostty }?.applicationPath, ghostty.path)
        XCTAssertEqual(installations.first { $0.app == .iTerm2 }?.applicationPath, iterm.path)
    }

    func testDiscoversSystemTerminalOutsideApplicationsRoot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = directory.appendingPathComponent("Applications", isDirectory: true)
        let systemUtilities = directory
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Utilities", isDirectory: true)
        let terminal = try makeApp(
            "Terminal.app",
            bundleIdentifier: "com.apple.Terminal",
            in: systemUtilities
        )
        let discovery = InteractiveTerminalDiscovery(searchRoots: [applications, systemUtilities])

        let installations = discovery.discoverInstalledTerminals()

        XCTAssertEqual(installations, [
            InteractiveTerminalInstallation(
                app: .terminal,
                bundleIdentifier: "com.apple.Terminal",
                applicationPath: terminal.path
            )
        ])
    }

    func testIgnoresUnknownAppsThatDeclareExecutableDocumentSupport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = directory.appendingPathComponent("Applications", isDirectory: true)
        try makeApp(
            "Instruments.app",
            bundleIdentifier: "com.apple.dt.Instruments",
            in: applications,
            documentTypes: [
                [
                    "CFBundleTypeName": "Executable",
                    "LSItemContentTypes": ["public.unix-executable"]
                ]
            ]
        )
        let discovery = InteractiveTerminalDiscovery(searchRoots: [applications])

        XCTAssertEqual(discovery.discoverInstalledTerminals(), [])
    }

    func testDuplicateBundleIdentifiersUseDeterministicPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let applications = directory.appendingPathComponent("Applications", isDirectory: true)
        let preferred = try makeApp(
            "A-Ghostty.app",
            bundleIdentifier: "com.mitchellh.ghostty",
            in: applications
        )
        try makeApp(
            "Z-Ghostty.app",
            bundleIdentifier: "com.mitchellh.ghostty",
            in: applications
        )
        let discovery = InteractiveTerminalDiscovery(searchRoots: [applications])

        let installations = discovery.discoverInstalledTerminals()

        XCTAssertEqual(installations, [
            InteractiveTerminalInstallation(
                app: .ghostty,
                bundleIdentifier: "com.mitchellh.ghostty",
                applicationPath: preferred.path
            )
        ])
    }

    func testOptionsPreserveUnavailableCurrentSelection() {
        let installations = [
            InteractiveTerminalInstallation(
                app: .terminal,
                bundleIdentifier: "com.apple.Terminal",
                applicationPath: "/System/Applications/Utilities/Terminal.app"
            )
        ]

        let options = InteractiveTerminalDiscovery.options(
            for: installations,
            currentApp: .ghostty
        )

        XCTAssertEqual(options.map(\.app), [.terminal, .ghostty, .custom])
        XCTAssertEqual(options.first { $0.app == .terminal }?.isInstalled, true)
        XCTAssertEqual(options.first { $0.app == .ghostty }?.isInstalled, false)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-terminal-discovery-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func makeApp(
        _ relativePath: String,
        bundleIdentifier: String,
        in root: URL,
        documentTypes: [[String: Any]] = []
    ) throws -> URL {
        let applicationURL = root.appendingPathComponent(relativePath, isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": applicationURL.deletingPathExtension().lastPathComponent
        ]
        if !documentTypes.isEmpty {
            info["CFBundleDocumentTypes"] = documentTypes
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return applicationURL
    }
}
