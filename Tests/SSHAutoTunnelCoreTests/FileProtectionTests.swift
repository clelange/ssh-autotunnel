import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class FileProtectionTests: XCTestCase {
    func testProtectDirectoryCreatesPrivateDirectory() throws {
        let directory = try temporaryDirectory().appendingPathComponent("state", isDirectory: true)

        try FileProtection.protectDirectory(directory)

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try posixPermissions(of: directory), FileProtection.privateDirectoryPermissions)
    }

    func testProtectFileAppliesPrivatePermissions() throws {
        let url = try temporaryDirectory().appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )

        try FileProtection.protectFile(url)

        XCTAssertEqual(try posixPermissions(of: url), FileProtection.privateFilePermissions)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
