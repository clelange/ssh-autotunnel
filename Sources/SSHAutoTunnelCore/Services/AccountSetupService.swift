import Foundation

public struct AccountSetupPreset: Identifiable, Equatable, Sendable {
    public var id: AccountPresetID
    public var displayName: String
    public var credentialHost: String
    public var interactiveHost: String?
    public var defaultTunnelHost: String
    public var suggestedTunnelHosts: [String]
    public var defaultTunnelEnabled: Bool
    public var tunnelHostRequired: Bool
    public var defaultLocalSocksPort: Int
    public var passwordService: String
    public var totpService: String
    public var helpURLs: [String]

    public init(
        id: AccountPresetID,
        displayName: String,
        credentialHost: String,
        interactiveHost: String? = nil,
        defaultTunnelHost: String,
        suggestedTunnelHosts: [String] = [],
        defaultTunnelEnabled: Bool,
        tunnelHostRequired: Bool,
        defaultLocalSocksPort: Int,
        passwordService: String,
        totpService: String,
        helpURLs: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.credentialHost = credentialHost
        self.interactiveHost = interactiveHost
        self.defaultTunnelHost = defaultTunnelHost
        self.suggestedTunnelHosts = suggestedTunnelHosts
        self.defaultTunnelEnabled = defaultTunnelEnabled
        self.tunnelHostRequired = tunnelHostRequired
        self.defaultLocalSocksPort = defaultLocalSocksPort
        self.passwordService = passwordService
        self.totpService = totpService
        self.helpURLs = helpURLs
    }

    public var profileName: String {
        switch id {
        case .cernLxPlus: "CERN LxPlus"
        case .psiTier3: "PSI CMS Tier-3"
        case .psiGeneral: "PSI General"
        }
    }

    public var pacRuleName: String {
        switch id {
        case .cernLxPlus: "CERN"
        case .psiTier3: "PSI Tier-3"
        case .psiGeneral: "PSI"
        }
    }

    public func jumpHost(username: String) -> String? {
        switch id {
        case .cernLxPlus:
            nil
        case .psiTier3:
            "\(username)@t3hop01.psi.ch"
        case .psiGeneral:
            "\(username)@hopx.psi.ch"
        }
    }

    public func pacDomainPattern(tunnelHost: String) -> String? {
        switch id {
        case .cernLxPlus:
            "*.cern.ch"
        case .psiTier3:
            AccountSetupService.trimmed(tunnelHost)
        case .psiGeneral:
            "*.psi.ch"
        }
    }
}

public struct AccountSetupInput: Identifiable, Equatable, Sendable {
    public var id: AccountPresetID
    public var isSelected: Bool
    public var username: String
    public var passwordAvailable: Bool
    public var totpSeedAvailable: Bool
    public var useForTunnelling: Bool
    public var tunnelHost: String

    public init(
        id: AccountPresetID,
        isSelected: Bool = true,
        username: String = NSUserName(),
        passwordAvailable: Bool = false,
        totpSeedAvailable: Bool = false,
        useForTunnelling: Bool,
        tunnelHost: String
    ) {
        self.id = id
        self.isSelected = isSelected
        self.username = username
        self.passwordAvailable = passwordAvailable
        self.totpSeedAvailable = totpSeedAvailable
        self.useForTunnelling = useForTunnelling
        self.tunnelHost = tunnelHost
    }
}

public struct AccountSetupCredentialStatus: Identifiable, Equatable, Sendable {
    public var id: AccountPresetID
    public var passwordState: KeychainCredentialState
    public var totpSeedState: KeychainCredentialState

    public init(id: AccountPresetID, passwordState: KeychainCredentialState, totpSeedState: KeychainCredentialState) {
        self.id = id
        self.passwordState = passwordState
        self.totpSeedState = totpSeedState
    }
}

public struct AccountSetupResult: Equatable, Sendable {
    public var configuredAccounts: Int
    public var createdProfiles: Int
    public var updatedProfiles: Int
    public var removedProfiles: Int
    public var createdPACRules: Int
    public var updatedPACRules: Int

    public init(
        configuredAccounts: Int = 0,
        createdProfiles: Int = 0,
        updatedProfiles: Int = 0,
        removedProfiles: Int = 0,
        createdPACRules: Int = 0,
        updatedPACRules: Int = 0
    ) {
        self.configuredAccounts = configuredAccounts
        self.createdProfiles = createdProfiles
        self.updatedProfiles = updatedProfiles
        self.removedProfiles = removedProfiles
        self.createdPACRules = createdPACRules
        self.updatedPACRules = updatedPACRules
    }
}

public enum AccountSetupError: LocalizedError, Equatable, Sendable {
    case unknownPreset(AccountPresetID)
    case missingUsername(AccountPresetID)
    case missingPassword(AccountPresetID)
    case missingTunnelHost(AccountPresetID)

    public var errorDescription: String? {
        switch self {
        case .unknownPreset(let id):
            "Unknown setup account preset '\(id.rawValue)'."
        case .missingUsername(let id):
            "\(displayName(for: id)) requires a username."
        case .missingPassword(let id):
            "\(displayName(for: id)) requires a password in Keychain before setup can finish."
        case .missingTunnelHost(let id):
            "\(displayName(for: id)) requires a final tunnel server."
        }
    }

    private func displayName(for id: AccountPresetID) -> String {
        AccountSetupService.preset(for: id)?.displayName ?? id.rawValue
    }
}

public enum AccountSetupService {
    public static let presets: [AccountSetupPreset] = [
        AccountSetupPreset(
            id: .cernLxPlus,
            displayName: "CERN LxPlus",
            credentialHost: "lxplus.cern.ch",
            interactiveHost: "lxplus.cern.ch",
            defaultTunnelHost: "lxtunnel.cern.ch",
            defaultTunnelEnabled: true,
            tunnelHostRequired: true,
            defaultLocalSocksPort: 1081,
            passwordService: SSHAuto2FAPresets.cernLxplusPasswordService,
            totpService: SSHAuto2FAPresets.cernLxplusTOTPService,
            helpURLs: [
                "https://users-portal.web.cern.ch/",
                "https://cern.service-now.com/service-portal?id=outage&n=OTG0156449"
            ]
        ),
        AccountSetupPreset(
            id: .psiTier3,
            displayName: "PSI CMS Tier-3",
            credentialHost: "t3hop01.psi.ch",
            defaultTunnelHost: "",
            suggestedTunnelHosts: ["t3ui06.psi.ch", "t3ui07.psi.ch"],
            defaultTunnelEnabled: false,
            tunnelHostRequired: true,
            defaultLocalSocksPort: 1082,
            passwordService: SSHAuto2FAPresets.psiTier3PasswordService,
            totpService: SSHAuto2FAPresets.psiTier3TOTPService,
            helpURLs: [
                "https://tier3.pages.psi.ch/tier3-access/T3HopGateway/",
                "https://tier3.pages.psi.ch/tier3-access/HowToSetupYourAccount/"
            ]
        ),
        AccountSetupPreset(
            id: .psiGeneral,
            displayName: "PSI General",
            credentialHost: "hopx.psi.ch",
            defaultTunnelHost: "login.psi.ch",
            defaultTunnelEnabled: true,
            tunnelHostRequired: true,
            defaultLocalSocksPort: 1083,
            passwordService: SSHAuto2FAPresets.psiGeneralPasswordService,
            totpService: SSHAuto2FAPresets.psiGeneralTOTPService,
            helpURLs: [
                "https://www.psi.ch/en/computing/ssh-hop-ng",
                "https://www.psi.ch/en/computing/vpn"
            ]
        )
    ]

    public static func preset(for id: AccountPresetID) -> AccountSetupPreset? {
        presets.first { $0.id == id }
    }

    public static func defaultInputs(
        in configuration: AppConfiguration,
        defaultUsername: String = NSUserName()
    ) -> [AccountSetupInput] {
        presets.map { preset in
            let account = configuration.accounts.first { $0.id == preset.id }
            let profile = configuration.profiles.first { $0.name == preset.profileName }
            return AccountSetupInput(
                id: preset.id,
                isSelected: account != nil || profile != nil || configuration.accounts.isEmpty,
                username: account?.username ?? profile?.user ?? defaultUsername,
                passwordAvailable: false,
                totpSeedAvailable: false,
                useForTunnelling: account?.tunnelEnabled ?? (profile != nil || preset.defaultTunnelEnabled),
                tunnelHost: account?.tunnelHost ?? profile?.host ?? preset.defaultTunnelHost
            )
        }
    }

    public static func credentialStatus(
        for input: AccountSetupInput,
        checker: GenericPasswordExistenceChecking
    ) -> AccountSetupCredentialStatus {
        guard let preset = preset(for: input.id), !trimmed(input.username).isEmpty else {
            return AccountSetupCredentialStatus(id: input.id, passwordState: .missing, totpSeedState: .missing)
        }
        return AccountSetupCredentialStatus(
            id: input.id,
            passwordState: state(service: preset.passwordService, account: input.username, checker: checker),
            totpSeedState: state(service: preset.totpService, account: input.username, checker: checker)
        )
    }

    public static func apply(
        inputs: [AccountSetupInput],
        to configuration: AppConfiguration
    ) throws -> (AppConfiguration, AccountSetupResult) {
        try validate(inputs)

        var updated = configuration
        var result = AccountSetupResult()

        for input in inputs {
            guard let preset = preset(for: input.id) else {
                throw AccountSetupError.unknownPreset(input.id)
            }

            if !input.isSelected {
                removeAccountAndGeneratedTunnel(for: preset, from: &updated, result: &result)
                continue
            }

            result.configuredAccounts += 1
            let username = trimmed(input.username)
            let tunnelHost = trimmed(input.tunnelHost)
            let jumpHost = input.useForTunnelling ? preset.jumpHost(username: username) : nil
            let pacDomainPattern = input.useForTunnelling ? preset.pacDomainPattern(tunnelHost: tunnelHost) : nil
            let keychain = KeychainReference(
                account: username,
                passwordService: preset.passwordService,
                totpService: input.totpSeedAvailable ? preset.totpService : nil
            )
            let account = AccountConfiguration(
                id: preset.id,
                displayName: preset.displayName,
                username: username,
                credentialHost: preset.credentialHost,
                interactiveHost: preset.interactiveHost,
                tunnelEnabled: input.useForTunnelling,
                tunnelHost: input.useForTunnelling ? tunnelHost : nil,
                jumpHost: jumpHost,
                localSocksPort: input.useForTunnelling ? localSocksPort(for: preset, in: updated) : nil,
                pacDomainPattern: pacDomainPattern,
                keychain: keychain
            )
            upsertAccount(account, in: &updated)

            if input.useForTunnelling {
                let profileID = upsertProfile(
                    preset: preset,
                    username: username,
                    tunnelHost: tunnelHost,
                    jumpHost: jumpHost,
                    keychain: keychain,
                    hasTOTPSeed: input.totpSeedAvailable,
                    in: &updated,
                    result: &result
                )
                if let pacDomainPattern {
                    ensurePACRule(
                        name: preset.pacRuleName,
                        pattern: pacDomainPattern,
                        profileID: profileID,
                        in: &updated,
                        result: &result
                    )
                }
            } else {
                removeGeneratedTunnel(for: preset, from: &updated, result: &result)
            }
        }

        orderPACRules(&updated)
        try PortConfigurationValidator.validate(updated)
        return (updated, result)
    }

    public static func validate(_ inputs: [AccountSetupInput]) throws {
        for input in inputs where input.isSelected {
            guard preset(for: input.id) != nil else {
                throw AccountSetupError.unknownPreset(input.id)
            }
            guard !trimmed(input.username).isEmpty else {
                throw AccountSetupError.missingUsername(input.id)
            }
            guard input.passwordAvailable else {
                throw AccountSetupError.missingPassword(input.id)
            }
            if input.useForTunnelling, trimmed(input.tunnelHost).isEmpty {
                throw AccountSetupError.missingTunnelHost(input.id)
            }
        }
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func state(
        service: String,
        account: String,
        checker: GenericPasswordExistenceChecking
    ) -> KeychainCredentialState {
        do {
            return try checker.genericPasswordExists(service: service, account: account) ? .available : .missing
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    private static func upsertAccount(_ account: AccountConfiguration, in configuration: inout AppConfiguration) {
        if let index = configuration.accounts.firstIndex(where: { $0.id == account.id }) {
            configuration.accounts[index] = account
        } else {
            configuration.accounts.append(account)
        }
    }

    private static func upsertProfile(
        preset: AccountSetupPreset,
        username: String,
        tunnelHost: String,
        jumpHost: String?,
        keychain: KeychainReference,
        hasTOTPSeed: Bool,
        in configuration: inout AppConfiguration,
        result: inout AccountSetupResult
    ) -> UUID {
        if let index = configuration.profiles.firstIndex(where: { $0.name == preset.profileName }) {
            configuration.profiles[index].host = tunnelHost
            configuration.profiles[index].user = username
            configuration.profiles[index].jumpHost = jumpHost
            configuration.profiles[index].authMode = hasTOTPSeed ? .passwordAndTOTP : .password
            configuration.profiles[index].keychain = keychain
            configuration.profiles[index].healthProbe = HealthProbe(host: tunnelHost, port: 22)
            result.updatedProfiles += 1
            return configuration.profiles[index].id
        }

        let profile = TunnelProfile(
            name: preset.profileName,
            host: tunnelHost,
            user: username,
            localSocksPort: nextFreePort(preferred: preset.defaultLocalSocksPort, profiles: configuration.profiles),
            jumpHost: jumpHost,
            authMode: hasTOTPSeed ? .passwordAndTOTP : .password,
            keychain: keychain,
            healthProbe: HealthProbe(host: tunnelHost, port: 22)
        )
        configuration.profiles.append(profile)
        result.createdProfiles += 1
        return profile.id
    }

    private static func ensurePACRule(
        name: String,
        pattern: String,
        profileID: UUID,
        in configuration: inout AppConfiguration,
        result: inout AccountSetupResult
    ) {
        if let index = configuration.pacRules.firstIndex(where: { $0.name == name || $0.domainPattern == pattern }) {
            configuration.pacRules[index].name = name
            configuration.pacRules[index].domainPattern = pattern
            configuration.pacRules[index].profileID = profileID
            configuration.pacRules[index].enabled = true
            configuration.pacRules[index].failureMode = .failClosed
            result.updatedPACRules += 1
            return
        }

        configuration.pacRules.append(PACRule(name: name, domainPattern: pattern, profileID: profileID))
        result.createdPACRules += 1
    }

    private static func removeAccountAndGeneratedTunnel(
        for preset: AccountSetupPreset,
        from configuration: inout AppConfiguration,
        result: inout AccountSetupResult
    ) {
        configuration.accounts.removeAll { $0.id == preset.id }
        removeGeneratedTunnel(for: preset, from: &configuration, result: &result)
    }

    private static func removeGeneratedTunnel(
        for preset: AccountSetupPreset,
        from configuration: inout AppConfiguration,
        result: inout AccountSetupResult
    ) {
        let removedProfileIDs = configuration.profiles
            .filter { $0.name == preset.profileName }
            .map(\.id)
        if !removedProfileIDs.isEmpty {
            result.removedProfiles += removedProfileIDs.count
            configuration.profiles.removeAll { removedProfileIDs.contains($0.id) }
        }
        configuration.pacRules.removeAll { rule in
            removedProfileIDs.contains(rule.profileID) || rule.name == preset.pacRuleName
        }
    }

    private static func localSocksPort(for preset: AccountSetupPreset, in configuration: AppConfiguration) -> Int {
        configuration.profiles.first { $0.name == preset.profileName }?.localSocksPort
            ?? nextFreePort(preferred: preset.defaultLocalSocksPort, profiles: configuration.profiles)
    }

    private static func nextFreePort(preferred: Int, profiles: [TunnelProfile]) -> Int {
        let used = Set(profiles.map(\.localSocksPort))
        var port = preferred
        while used.contains(port) {
            port += 1
        }
        return port
    }

    private static func orderPACRules(_ configuration: inout AppConfiguration) {
        let tier3Rules = configuration.pacRules.filter { $0.name == AccountSetupPreset.psiTier3RuleName }
        guard !tier3Rules.isEmpty else { return }
        configuration.pacRules.removeAll { $0.name == AccountSetupPreset.psiTier3RuleName }
        let broadPSIIndex = configuration.pacRules.firstIndex { $0.domainPattern == "*.psi.ch" } ?? configuration.pacRules.endIndex
        configuration.pacRules.insert(contentsOf: tier3Rules, at: broadPSIIndex)
    }
}

private extension AccountSetupPreset {
    static let psiTier3RuleName = "PSI Tier-3"
}
