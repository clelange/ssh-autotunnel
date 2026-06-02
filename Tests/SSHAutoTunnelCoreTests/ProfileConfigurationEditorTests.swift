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

    func testReordersProfilesByExactIDListPreservingReferences() throws {
        let first = TunnelProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "First",
            host: "first.example.org",
            localSocksPort: 1200
        )
        let second = TunnelProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Second",
            host: "second.example.org",
            localSocksPort: 1201
        )
        let third = TunnelProfile(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Third",
            host: "third.example.org",
            localSocksPort: 1202
        )
        let configuration = AppConfiguration(
            profiles: [first, second, third],
            pacRules: [
                PACRule(name: "First", domainPattern: "*.first.example.org", profileID: first.id),
                PACRule(name: "Third", domainPattern: "*.third.example.org", profileID: third.id)
            ],
            networkRules: [
                NetworkPolicyRule(name: "Second", match: NetworkMatch(wifiSSID: "Office"), action: .disableProxy, profileID: second.id)
            ]
        )

        let updated = try ProfileConfigurationEditor.reorderProfiles(
            profileIDs: [third.id, first.id, second.id],
            in: configuration
        )

        XCTAssertEqual(updated.profiles.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(updated.pacRules.map(\.profileID), [first.id, third.id])
        XCTAssertEqual(updated.networkRules.map(\.profileID), [second.id])
    }

    func testReorderRejectsDuplicateProfileIDs() {
        let first = TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1200)
        let second = TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1201)
        let configuration = AppConfiguration(profiles: [first, second])

        XCTAssertThrowsError(try ProfileConfigurationEditor.reorderProfiles(profileIDs: [first.id, first.id], in: configuration)) { error in
            guard case .invalidProfileOrder(let reason) = error as? ProfileConfigurationEditorError else {
                return XCTFail("Expected invalid profile order error, got \(error)")
            }
            XCTAssertTrue(reason.contains("duplicate profile id"))
        }
    }

    func testReorderRejectsUnknownProfileIDs() {
        let first = TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1200)
        let second = TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1201)
        let unknownID = UUID()
        let configuration = AppConfiguration(profiles: [first, second])

        XCTAssertThrowsError(try ProfileConfigurationEditor.reorderProfiles(profileIDs: [first.id, unknownID], in: configuration)) { error in
            guard case .invalidProfileOrder(let reason) = error as? ProfileConfigurationEditorError else {
                return XCTFail("Expected invalid profile order error, got \(error)")
            }
            XCTAssertTrue(reason.contains("unknown profile id"))
        }
    }

    func testReorderRejectsMissingProfileIDs() {
        let first = TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1200)
        let second = TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1201)
        let configuration = AppConfiguration(profiles: [first, second])

        XCTAssertThrowsError(try ProfileConfigurationEditor.reorderProfiles(profileIDs: [first.id], in: configuration)) { error in
            guard case .invalidProfileOrder(let reason) = error as? ProfileConfigurationEditorError else {
                return XCTFail("Expected invalid profile order error, got \(error)")
            }
            XCTAssertTrue(reason.contains("missing profile id"))
        }
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
