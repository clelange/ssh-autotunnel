import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class SSHAuto2FAKeychainInspectorTests: XCTestCase {
    func testDefaultRequirementsUseKnownServiceNames() {
        let requirements = SSHAuto2FAKeychainInspector.defaultRequirements(account: "lange_c")

        XCTAssertEqual(requirements.map(\.service), [
            "cern-lxplus-otp-secret",
            "psit3-password",
            "psit3-otp-secret"
        ])
        XCTAssertEqual(Set(requirements.map(\.account)), ["lange_c"])
        XCTAssertEqual(requirements.map(\.kind), [.totpSeed, .password, .totpSeed])
    }

    func testInspectorMarksAvailableMissingAndUnreadableServices() {
        let requirements = [
            SSHAuto2FAServiceRequirement(profileName: "Available", kind: .password, service: "available", account: "me"),
            SSHAuto2FAServiceRequirement(profileName: "Missing", kind: .totpSeed, service: "missing", account: "me"),
            SSHAuto2FAServiceRequirement(profileName: "Unreadable", kind: .totpSeed, service: "unreadable", account: "me")
        ]
        let statuses = SSHAuto2FAKeychainInspector.inspect(
            requirements: requirements,
            reader: FakeGenericPasswordReader(results: [
                "available|me": .success("secret"),
                "missing|me": .failure(KeychainServiceError.itemNotFound(service: "missing", account: "me")),
                "unreadable|me": .failure(FakeReaderError.denied)
            ])
        )

        XCTAssertEqual(statuses.map(\.state), [
            .available,
            .missing,
            .unreadable("Access denied")
        ])
    }

    func testServiceStatusIsCodable() throws {
        let status = SSHAuto2FAServiceStatus(
            requirement: SSHAuto2FAServiceRequirement(
                profileName: "PSI Tier-3",
                kind: .password,
                service: "psit3-password",
                account: "lange_c"
            ),
            state: .unreadable("Access denied")
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SSHAuto2FAServiceStatus.self, from: data)

        XCTAssertEqual(decoded, status)
    }
}

private struct FakeGenericPasswordReader: GenericPasswordReading {
    var results: [String: Result<String, Error>]

    func readGenericPassword(service: String, account: String) throws -> String {
        try results["\(service)|\(account)", default: .failure(KeychainServiceError.itemNotFound(service: service, account: account))].get()
    }
}

private enum FakeReaderError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Access denied"
    }
}
