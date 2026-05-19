import XCTest
@testable import SSHAutoTunnelCore

final class ProfileConfigurationEditorTests: XCTestCase {
    func testCreatesProfileAfterPortValidation() throws {
        let profile = TunnelProfile(name: "Example", host: "ssh.example.org", localSocksPort: 1200)

        let configuration = try ProfileConfigurationEditor.create(profile: profile, in: AppConfiguration())

        XCTAssertEqual(configuration.profiles, [profile])
    }

    func testCreateRejectsDuplicateProfileID() {
        let profile = TunnelProfile(name: "Example", host: "ssh.example.org", localSocksPort: 1200)
        let configuration = AppConfiguration(profiles: [profile])

        XCTAssertThrowsError(try ProfileConfigurationEditor.create(profile: profile, in: configuration)) { error in
            XCTAssertEqual(error as? ProfileConfigurationEditorError, .duplicateProfileID(profile.id))
        }
    }

    func testUpdatesProfileWhilePreservingExistingIDAndReferences() throws {
        let existingID = UUID()
        let incomingID = UUID()
        let existing = TunnelProfile(id: existingID, name: "Example", host: "old.example.org", localSocksPort: 1200)
        let incoming = TunnelProfile(id: incomingID, name: "Example", host: "new.example.org", localSocksPort: 1201)
        let configuration = AppConfiguration(
            profiles: [existing],
            pacRules: [PACRule(name: "Example", domainPattern: "*.example.org", profileID: existingID)],
            networkRules: [NetworkPolicyRule(name: "Trusted", match: NetworkMatch(wifiSSID: "Office"), action: .disableProxy, profileID: existingID)]
        )

        let updated = try ProfileConfigurationEditor.update(profile: incoming, matchingName: "Example", in: configuration)

        XCTAssertEqual(updated.profiles[0].id, existingID)
        XCTAssertEqual(updated.profiles[0].host, "new.example.org")
        XCTAssertEqual(updated.profiles[0].localSocksPort, 1201)
        XCTAssertEqual(updated.pacRules[0].profileID, existingID)
        XCTAssertEqual(updated.networkRules[0].profileID, existingID)
    }

    func testDeleteRemovesProfileAndDependentRules() throws {
        let keep = TunnelProfile(name: "Keep", host: "keep.example.org", localSocksPort: 1200)
        let remove = TunnelProfile(name: "Remove", host: "remove.example.org", localSocksPort: 1201)
        let configuration = AppConfiguration(
            profiles: [keep, remove],
            pacRules: [
                PACRule(name: "Keep", domainPattern: "*.keep.example.org", profileID: keep.id),
                PACRule(name: "Remove", domainPattern: "*.remove.example.org", profileID: remove.id)
            ],
            networkRules: [
                NetworkPolicyRule(name: "Keep", match: NetworkMatch(wifiSSID: "Keep"), action: .disableProxy, profileID: keep.id),
                NetworkPolicyRule(name: "Remove", match: NetworkMatch(wifiSSID: "Remove"), action: .disableProxy, profileID: remove.id)
            ]
        )

        let updated = try ProfileConfigurationEditor.delete(profileName: "remove", in: configuration)

        XCTAssertEqual(updated.profiles.map(\.id), [keep.id])
        XCTAssertEqual(updated.pacRules.map(\.profileID), [keep.id])
        XCTAssertEqual(updated.networkRules.map(\.profileID), [keep.id])
    }

    func testDeleteRequiresExistingProfile() {
        XCTAssertThrowsError(try ProfileConfigurationEditor.delete(profileName: "missing", in: AppConfiguration())) { error in
            XCTAssertEqual(error as? ProfileConfigurationEditorError, .profileNotFound)
        }
    }
}
