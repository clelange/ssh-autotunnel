import XCTest
@testable import SSHAutoTunnelCore

final class ProfileKeychainCleanupPlannerTests: XCTestCase {
    func testPlansUniqueProfileKeychainItems() {
        let profile = TunnelProfile(
            name: "Remove",
            host: "remove.example.org",
            localSocksPort: 1200,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "remove-password",
                totpService: "remove-totp"
            )
        )
        let configuration = AppConfiguration(profiles: [profile])

        let items = ProfileKeychainCleanupPlanner.removableItems(
            removingProfileID: profile.id,
            from: configuration
        )

        XCTAssertEqual(items, [
            GenericPasswordItemReference(service: "remove-password", account: "alice"),
            GenericPasswordItemReference(service: "remove-totp", account: "alice")
        ])
    }

    func testDoesNotPlanItemsStillReferencedByRemainingProfiles() {
        let keep = TunnelProfile(
            name: "Keep",
            host: "keep.example.org",
            localSocksPort: 1200,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "shared-password",
                totpService: "shared-totp"
            )
        )
        let remove = TunnelProfile(
            name: "Remove",
            host: "remove.example.org",
            localSocksPort: 1201,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "shared-password",
                totpService: "remove-totp"
            )
        )
        let configuration = AppConfiguration(profiles: [keep, remove])

        let items = ProfileKeychainCleanupPlanner.removableItems(
            removingProfileID: remove.id,
            from: configuration
        )

        XCTAssertEqual(items, [
            GenericPasswordItemReference(service: "remove-totp", account: "alice")
        ])
    }

    func testDeduplicatesItemsWhenRemovingMultipleProfiles() {
        let first = TunnelProfile(
            name: "First",
            host: "first.example.org",
            localSocksPort: 1200,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "shared-password",
                totpService: "shared-totp"
            )
        )
        let second = TunnelProfile(
            name: "Second",
            host: "second.example.org",
            localSocksPort: 1201,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "shared-password",
                totpService: "shared-totp"
            )
        )
        let configuration = AppConfiguration(profiles: [first, second])

        let items = ProfileKeychainCleanupPlanner.removableItems(
            removingProfileIDs: [first.id, second.id],
            from: configuration
        )

        XCTAssertEqual(items, [
            GenericPasswordItemReference(service: "shared-password", account: "alice"),
            GenericPasswordItemReference(service: "shared-totp", account: "alice")
        ])
    }

    func testIgnoresProfilesWithoutConfiguredServices() {
        let profile = TunnelProfile(
            name: "No Keychain",
            host: "none.example.org",
            localSocksPort: 1200,
            keychain: KeychainReference(account: "alice")
        )
        let configuration = AppConfiguration(profiles: [profile])

        let items = ProfileKeychainCleanupPlanner.removableItems(
            removingProfileID: profile.id,
            from: configuration
        )

        XCTAssertTrue(items.isEmpty)
    }
}
