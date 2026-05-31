import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class InteractiveSSHSessionRegistryTests: XCTestCase {
    func testCreatesAndListsActiveSessionMarkers() throws {
        let directory = try temporaryDirectory()
        let registry = InteractiveSSHSessionRegistry(directoryProvider: { directory })
        let older = ActiveInteractiveSSHSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            profileID: UUID(),
            profileName: "PSI General",
            jumpHost: "alice@hopx.psi.ch",
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = ActiveInteractiveSSHSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            profileID: UUID(),
            profileName: "PSI Tier-3",
            jumpHost: "alice@t3hop01.psi.ch",
            startedAt: Date(timeIntervalSince1970: 20)
        )

        let olderURL = try registry.createMarker(for: older)
        _ = try registry.createMarker(for: newer)

        XCTAssertEqual(registry.activeSessions(), [older, newer])
        XCTAssertEqual(try FileProtection.posixPermissions(of: olderURL), FileProtection.privateFilePermissions)
    }

    func testIgnoresMalformedMarkersAndRemovesMarkers() throws {
        let directory = try temporaryDirectory()
        let registry = InteractiveSSHSessionRegistry(directoryProvider: { directory })
        let session = ActiveInteractiveSSHSession(
            profileID: UUID(),
            profileName: "PSI Tier-3",
            jumpHost: "alice@t3hop01.psi.ch"
        )
        let markerURL = try registry.createMarker(for: session)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        XCTAssertEqual(registry.activeSessions(), [session])

        registry.removeMarker(at: markerURL)

        XCTAssertTrue(registry.activeSessions().isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
