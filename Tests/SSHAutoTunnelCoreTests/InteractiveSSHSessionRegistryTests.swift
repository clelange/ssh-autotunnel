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

    func testKeepsPIDBackedMarkerOnlyWhileProcessIsRunning() throws {
        let directory = try temporaryDirectory()
        var runningPIDs: Set<Int32> = [12345]
        let registry = InteractiveSSHSessionRegistry(
            directoryProvider: { directory },
            processIsRunning: { runningPIDs.contains($0) }
        )
        let session = ActiveInteractiveSSHSession(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            profileID: UUID(),
            profileName: "PSI Tier-3",
            jumpHost: "alice@t3hop01.psi.ch"
        )
        let markerURL = try registry.createMarker(for: session)
        let pidURL = directory.appendingPathComponent("33333333-3333-3333-3333-333333333333.pid")
        try Data("12345\n".utf8).write(to: pidURL)

        XCTAssertEqual(registry.activeSessions(), [session])

        runningPIDs.removeAll()

        XCTAssertTrue(registry.activeSessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
    }

    func testPrunesLegacyMarkerWithoutPIDAfterGraceInterval() throws {
        let directory = try temporaryDirectory()
        let now = Date(timeIntervalSince1970: 100)
        let registry = InteractiveSSHSessionRegistry(
            directoryProvider: { directory },
            pidWriteGraceInterval: 10,
            now: { now }
        )
        let session = ActiveInteractiveSSHSession(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            profileID: UUID(),
            profileName: "PSI Tier-3",
            jumpHost: "alice@t3hop01.psi.ch"
        )
        let markerURL = try registry.createMarker(for: session)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 80)],
            ofItemAtPath: markerURL.path
        )

        XCTAssertTrue(registry.activeSessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
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
