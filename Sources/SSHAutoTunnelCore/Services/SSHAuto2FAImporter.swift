import Foundation

public struct SSHAuto2FAImportResult: Equatable, Sendable {
    public var createdProfiles: Int
    public var updatedProfiles: Int
    public var createdPACRules: Int
}

public enum SSHAuto2FAImporter {
    public static func backfillPresetSSHUsers(in configuration: AppConfiguration) -> (AppConfiguration, Bool) {
        var configuration = configuration
        var didUpdate = false

        for index in configuration.profiles.indices {
            switch configuration.profiles[index].name {
            case "CERN lxplus":
                didUpdate = backfillUser(in: &configuration.profiles[index]) || didUpdate
                didUpdate = backfillCERNInteractiveHost(in: &configuration.profiles[index]) || didUpdate
            case "PSI Tier-3":
                didUpdate = backfillUser(in: &configuration.profiles[index]) || didUpdate
                didUpdate = backfillInteractiveHostFromTunnelHost(in: &configuration.profiles[index]) || didUpdate
                didUpdate = backfillPSIJumpHost(in: &configuration.profiles[index]) || didUpdate
            default:
                break
            }
        }

        return (configuration, didUpdate)
    }

    public static func apply(
        to configuration: AppConfiguration,
        account: String = NSUserName(),
        accountByService: [String: String] = [:]
    ) -> (AppConfiguration, SSHAuto2FAImportResult) {
        var configuration = configuration
        var result = SSHAuto2FAImportResult(createdProfiles: 0, updatedProfiles: 0, createdPACRules: 0)

        let cernAccount = accountByService[SSHAuto2FAPresets.cernLxplusTOTPService] ?? account
        let psiAccount = sharedAccount(
            services: [
                SSHAuto2FAPresets.psiTier3PasswordService,
                SSHAuto2FAPresets.psiTier3TOTPService
            ],
            fallback: account,
            accountByService: accountByService
        )

        let lxplusID = upsertProfile(
            in: &configuration,
            result: &result,
            named: "CERN lxplus",
            host: "lxtunnel.cern.ch",
            interactiveHost: "lxplus.cern.ch",
            preferredPort: 1081,
            user: cernAccount,
            authMode: .kerberosAndTOTP,
            keychain: KeychainReference(account: cernAccount, totpService: SSHAuto2FAPresets.cernLxplusTOTPService)
        )
        ensurePACRule(
            in: &configuration,
            result: &result,
            name: "CERN",
            pattern: "*.cern.ch",
            profileID: lxplusID
        )

        let tier3ID = upsertProfile(
            in: &configuration,
            result: &result,
            named: "PSI Tier-3",
            host: "t3ui07.psi.ch",
            interactiveHost: "t3ui07.psi.ch",
            preferredPort: 1082,
            user: psiAccount,
            jumpHost: "\(psiAccount)@t3hop01.psi.ch",
            authMode: .passwordAndTOTP,
            keychain: KeychainReference(
                account: psiAccount,
                passwordService: SSHAuto2FAPresets.psiTier3PasswordService,
                totpService: SSHAuto2FAPresets.psiTier3TOTPService
            )
        )
        ensurePACRule(
            in: &configuration,
            result: &result,
            name: "PSI Tier-3",
            pattern: "*.psi.ch",
            profileID: tier3ID
        )

        return (configuration, result)
    }

    private static func upsertProfile(
        in configuration: inout AppConfiguration,
        result: inout SSHAuto2FAImportResult,
        named name: String,
        host: String,
        interactiveHost: String? = nil,
        preferredPort: Int,
        user: String,
        jumpHost: String? = nil,
        authMode: TunnelAuthMode,
        keychain: KeychainReference
    ) -> UUID {
        if let index = configuration.profiles.firstIndex(where: { $0.name == name }) {
            configuration.profiles[index].host = host
            configuration.profiles[index].user = user
            configuration.profiles[index].interactiveHost = interactiveHost
            configuration.profiles[index].jumpHost = jumpHost
            configuration.profiles[index].authMode = authMode
            configuration.profiles[index].keychain = keychain
            result.updatedProfiles += 1
            return configuration.profiles[index].id
        }

        let profile = TunnelProfile(
            name: name,
            host: host,
            user: user,
            localSocksPort: nextFreePort(preferred: preferredPort, profiles: configuration.profiles),
            interactiveHost: interactiveHost,
            jumpHost: jumpHost,
            authMode: authMode,
            keychain: keychain
        )
        configuration.profiles.append(profile)
        result.createdProfiles += 1
        return profile.id
    }

    private static func ensurePACRule(
        in configuration: inout AppConfiguration,
        result: inout SSHAuto2FAImportResult,
        name: String,
        pattern: String,
        profileID: UUID
    ) {
        if let index = configuration.pacRules.firstIndex(where: { $0.name == name || $0.domainPattern == pattern }) {
            configuration.pacRules[index].name = name
            configuration.pacRules[index].domainPattern = pattern
            configuration.pacRules[index].profileID = profileID
            configuration.pacRules[index].enabled = true
            return
        }

        configuration.pacRules.append(PACRule(name: name, domainPattern: pattern, profileID: profileID))
        result.createdPACRules += 1
    }

    private static func nextFreePort(preferred: Int, profiles: [TunnelProfile]) -> Int {
        let used = Set(profiles.map(\.localSocksPort))
        var port = preferred
        while used.contains(port) {
            port += 1
        }
        return port
    }

    private static func sharedAccount(
        services: [String],
        fallback: String,
        accountByService: [String: String]
    ) -> String {
        let discovered = services.compactMap { accountByService[$0] }
        guard !discovered.isEmpty else { return fallback }
        let unique = Set(discovered)
        return unique.count == 1 ? discovered[0] : fallback
    }

    private static func backfillUser(in profile: inout TunnelProfile) -> Bool {
        guard profile.user?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return false
        }
        profile.user = profile.keychain.account
        return true
    }

    private static func backfillCERNInteractiveHost(in profile: inout TunnelProfile) -> Bool {
        var didUpdate = false
        if (profile.interactiveHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.interactiveHost = "lxplus.cern.ch"
            didUpdate = true
        }
        if profile.host == "lxplus.cern.ch" {
            profile.host = "lxtunnel.cern.ch"
            if profile.healthProbe?.host == "lxplus.cern.ch" {
                profile.healthProbe?.host = "lxtunnel.cern.ch"
            }
            didUpdate = true
        }
        return didUpdate
    }

    private static func backfillInteractiveHostFromTunnelHost(in profile: inout TunnelProfile) -> Bool {
        guard (profile.interactiveHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        profile.interactiveHost = profile.host
        return true
    }

    private static func backfillPSIJumpHost(in profile: inout TunnelProfile) -> Bool {
        let account = profile.user?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? profile.user!
            : profile.keychain.account
        let current = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == nil || current == "" || current == "t3hop01.psi.ch" else {
            return false
        }
        profile.jumpHost = "\(account)@t3hop01.psi.ch"
        return current != profile.jumpHost
    }
}
