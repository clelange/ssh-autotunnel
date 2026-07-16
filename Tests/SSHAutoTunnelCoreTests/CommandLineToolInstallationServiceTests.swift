import AppKit
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class CommandLineToolInstallationServiceTests: XCTestCase {
    func testReportsNotInstalledWhenDestinationIsAbsent() throws {
        let fixture = try Fixture()
        XCTAssertEqual(fixture.service.status(), .notInstalled)
    }

    func testReportsInstalledForManagedAbsoluteSymlink() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.layout.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.layout.destinationURL,
            withDestinationURL: fixture.layout.helperURL
        )

        XCTAssertEqual(fixture.service.status(), .installed)
    }

    func testReportsConflictForBrokenOrForeignSymlinksAndRegularFiles() throws {
        let broken = try Fixture()
        try FileManager.default.createDirectory(
            at: broken.layout.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: broken.layout.destinationURL.path,
            withDestinationPath: broken.root.appendingPathComponent("missing-helper").path
        )
        guard case .conflict = broken.service.status() else {
            return XCTFail("Expected broken symlink conflict")
        }

        let foreign = try Fixture()
        try FileManager.default.createDirectory(
            at: foreign.layout.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: foreign.layout.destinationURL.path,
            withDestinationPath: "/another/tool"
        )
        guard case .conflict = foreign.service.status() else {
            return XCTFail("Expected foreign symlink conflict")
        }

        let regular = try Fixture()
        try FileManager.default.createDirectory(
            at: regular.layout.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: regular.layout.destinationURL.path, contents: Data()))
        guard case .conflict = regular.service.status() else {
            return XCTFail("Expected regular-file conflict")
        }
    }

    func testRejectsAppOutsideRequiredApplicationsLocation() throws {
        let fixture = try Fixture(appIsAtRequiredLocation: false)
        guard case .unavailable(let reason) = fixture.service.status() else {
            return XCTFail("Expected unavailable status")
        }
        XCTAssertTrue(reason.contains("/Applications"))
        XCTAssertThrowsError(try fixture.service.install()) { error in
            guard case CommandLineToolInstallationError.unavailable = error else {
                return XCTFail("Expected unavailable error, got \(error)")
            }
        }
    }

    func testInstallIsIdempotent() throws {
        let fixture = try Fixture()

        XCTAssertTrue(try fixture.service.install())
        XCTAssertFalse(try fixture.service.install())
        XCTAssertEqual(fixture.service.status(), .installed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.layout.destinationURL.path),
            fixture.layout.helperURL.path
        )
    }

    func testInstallNeverOverwritesConflict() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(
            at: fixture.layout.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("keep me".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: fixture.layout.destinationURL.path, contents: original))

        XCTAssertThrowsError(try fixture.service.install()) { error in
            XCTAssertEqual(
                error as? CommandLineToolInstallationError,
                .destinationConflict(fixture.layout.destinationURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.layout.destinationURL), original)
    }

    func testUninstallIsIdempotentAndOnlyRemovesManagedSymlink() throws {
        let managed = try Fixture()
        _ = try managed.service.install()
        XCTAssertTrue(try managed.service.uninstall())
        XCTAssertFalse(try managed.service.uninstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.layout.destinationURL.path))

        let foreign = try Fixture()
        try FileManager.default.createDirectory(
            at: foreign.layout.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: foreign.layout.destinationURL.path,
            withDestinationPath: "/another/tool"
        )
        XCTAssertThrowsError(try foreign.service.uninstall())
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: foreign.layout.destinationURL.path),
            "/another/tool"
        )
    }

    func testPermissionErrorsRequestAdministratorFallback() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertTrue(CommandLineToolInstallationService.requiresAdministratorPrivileges(for: posix))

        let cocoa = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteNoPermission.rawValue,
            userInfo: [NSUnderlyingErrorKey: posix]
        )
        XCTAssertTrue(CommandLineToolInstallationService.requiresAdministratorPrivileges(for: cocoa))
        XCTAssertFalse(CommandLineToolInstallationService.requiresAdministratorPrivileges(for: CocoaError(.fileNoSuchFile)))
    }

    func testPrivilegedScriptUsesAppleScriptAndShellQuotingWithElevatedRevalidation() {
        let appURL = URL(fileURLWithPath: "/Applications/SSH \"Quoted\" \\ Test.app", isDirectory: true)
        let layout = CommandLineToolInstallationLayout(
            appBundleURL: appURL,
            requiredAppBundleURL: appURL,
            destinationURL: URL(fileURLWithPath: "/usr/local/bin/ssh autotunnel's ctl")
        )

        let install = CommandLineToolPrivilegedScript.source(operation: .install, layout: layout)
        XCTAssertTrue(install.contains("set helperArg to quoted form of helperPath"))
        XCTAssertTrue(install.contains("set destinationArg to quoted form of destinationPath"))
        XCTAssertTrue(install.contains("shellCommand & \" \" & helperArg"))
        XCTAssertTrue(install.contains("SSH \\\"Quoted\\\" \\\\ Test.app"))
        XCTAssertTrue(install.contains("with administrator privileges"))
        XCTAssertTrue(install.contains("/usr/bin/readlink"))
        XCTAssertTrue(install.contains("will not be replaced") == false)

        let uninstall = CommandLineToolPrivilegedScript.source(operation: .uninstall, layout: layout)
        XCTAssertTrue(uninstall.contains("/usr/bin/readlink"))
        XCTAssertTrue(uninstall.contains("/bin/rm"))
        XCTAssertFalse(uninstall.contains("/bin/rm -f"))
        XCTAssertNotNil(NSAppleScript(source: install))
        XCTAssertNotNil(NSAppleScript(source: uninstall))
    }
}

private final class Fixture {
    let root: URL
    let layout: CommandLineToolInstallationLayout
    let service: CommandLineToolInstallationService

    init(appIsAtRequiredLocation: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandLineToolInstallationServiceTests-\(UUID().uuidString)", isDirectory: true)
        let requiredApp = root
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("SSHAutoTunnel.app", isDirectory: true)
        let runningApp = appIsAtRequiredLocation
            ? requiredApp
            : root.appendingPathComponent("Downloads/SSHAutoTunnel.app", isDirectory: true)
        let helper = runningApp
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("ssh-autotunnelctl")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data("helper".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        layout = CommandLineToolInstallationLayout(
            appBundleURL: runningApp,
            requiredAppBundleURL: requiredApp,
            destinationURL: root.appendingPathComponent("usr/local/bin/ssh-autotunnelctl")
        )
        service = CommandLineToolInstallationService(layout: layout)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
