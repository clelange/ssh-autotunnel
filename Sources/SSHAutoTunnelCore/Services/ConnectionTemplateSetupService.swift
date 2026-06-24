import Foundation

public enum ConnectionTemplatePACDomain: Equatable, Sendable {
    case fixed(String)
    case tunnelHost

    public func pattern(tunnelHost: String) -> String? {
        switch self {
        case .fixed(let pattern):
            return pattern
        case .tunnelHost:
            let trimmed = ConnectionTemplateSetupService.trimmed(tunnelHost)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

public struct ConnectionTemplate: Identifiable, Equatable, Sendable {
    public var id: ConnectionTemplateID
    public var displayName: String
    public var profileName: String
    public var pacRuleName: String
    public var credentialHost: String
    public var interactiveHost: String?
    public var defaultTunnelHost: String
    public var suggestedTunnelHosts: [String]
    public var defaultTunnelEnabled: Bool
    public var tunnelHostRequired: Bool
    public var defaultLocalSocksPort: Int
    public var jumpHostFormat: String?
    public var pacDomain: ConnectionTemplatePACDomain?
    public var passwordService: String
    public var totpService: String
    public var helpURLs: [String]

    public init(
        id: ConnectionTemplateID,
        displayName: String,
        profileName: String,
        pacRuleName: String,
        credentialHost: String,
        interactiveHost: String? = nil,
        defaultTunnelHost: String,
        suggestedTunnelHosts: [String] = [],
        defaultTunnelEnabled: Bool,
        tunnelHostRequired: Bool,
        defaultLocalSocksPort: Int,
        jumpHostFormat: String? = nil,
        pacDomain: ConnectionTemplatePACDomain? = nil,
        passwordService: String,
        totpService: String,
        helpURLs: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.profileName = profileName
        self.pacRuleName = pacRuleName
        self.credentialHost = credentialHost
        self.interactiveHost = interactiveHost
        self.defaultTunnelHost = defaultTunnelHost
        self.suggestedTunnelHosts = suggestedTunnelHosts
        self.defaultTunnelEnabled = defaultTunnelEnabled
        self.tunnelHostRequired = tunnelHostRequired
        self.defaultLocalSocksPort = defaultLocalSocksPort
        self.jumpHostFormat = jumpHostFormat
        self.pacDomain = pacDomain
        self.passwordService = passwordService
        self.totpService = totpService
        self.helpURLs = helpURLs
    }

    public func jumpHost(username: String) -> String? {
        jumpHostFormat?.replacingOccurrences(of: "{username}", with: username)
    }

    public func pacDomainPattern(tunnelHost: String) -> String? {
        pacDomain?.pattern(tunnelHost: tunnelHost)
    }
}

public struct ConnectionTemplateSetupInput: Identifiable, Equatable, Sendable {
    public var id: ConnectionTemplateID
    public var username: String
    public var passwordAvailable: Bool
    public var totpSeedAvailable: Bool
    public var useForTunnelling: Bool
    public var tunnelHost: String

    public init(
        id: ConnectionTemplateID,
        username: String = NSUserName(),
        passwordAvailable: Bool = false,
        totpSeedAvailable: Bool = false,
        useForTunnelling: Bool,
        tunnelHost: String
    ) {
        self.id = id
        self.username = username
        self.passwordAvailable = passwordAvailable
        self.totpSeedAvailable = totpSeedAvailable
        self.useForTunnelling = useForTunnelling
        self.tunnelHost = tunnelHost
    }
}

public struct ConnectionTemplateCredentialStatus: Identifiable, Equatable, Sendable {
    public var id: ConnectionTemplateID
    public var passwordState: KeychainCredentialState
    public var totpSeedState: KeychainCredentialState

    public init(id: ConnectionTemplateID, passwordState: KeychainCredentialState, totpSeedState: KeychainCredentialState) {
        self.id = id
        self.passwordState = passwordState
        self.totpSeedState = totpSeedState
    }
}

public struct ConnectionTemplateSetupResult: Equatable, Sendable {
    public var configuredTemplates: Int
    public var createdProfiles: Int
    public var updatedProfiles: Int
    public var removedProfiles: Int
    public var createdPACRules: Int
    public var updatedPACRules: Int

    public init(
        configuredTemplates: Int = 0,
        createdProfiles: Int = 0,
        updatedProfiles: Int = 0,
        removedProfiles: Int = 0,
        createdPACRules: Int = 0,
        updatedPACRules: Int = 0
    ) {
        self.configuredTemplates = configuredTemplates
        self.createdProfiles = createdProfiles
        self.updatedProfiles = updatedProfiles
        self.removedProfiles = removedProfiles
        self.createdPACRules = createdPACRules
        self.updatedPACRules = updatedPACRules
    }
}

public enum ConnectionTemplateSetupError: LocalizedError, Equatable, Sendable {
    case unknownTemplate(ConnectionTemplateID)
    case missingUsername(ConnectionTemplateID)
    case missingPassword(ConnectionTemplateID)
    case missingTunnelHost(ConnectionTemplateID)

    public var errorDescription: String? {
        switch self {
        case .unknownTemplate(let id):
            "Unknown connection template '\(id.rawValue)'."
        case .missingUsername(let id):
            "\(displayName(for: id)) requires a username."
        case .missingPassword(let id):
            "\(displayName(for: id)) requires a password in Keychain before setup can finish."
        case .missingTunnelHost(let id):
            "\(displayName(for: id)) requires a final tunnel server."
        }
    }

    private func displayName(for id: ConnectionTemplateID) -> String {
        ConnectionTemplateSetupService.template(for: id)?.displayName ?? id.rawValue
    }
}

public enum ConnectionTemplateSetupService {
    public static let templates: [ConnectionTemplate] = [
        ConnectionTemplate(
            id: .cernLxPlus,
            displayName: "CERN LxPlus",
            profileName: "CERN LxPlus",
            pacRuleName: "CERN",
            credentialHost: "lxplus.cern.ch",
            interactiveHost: "lxplus.cern.ch",
            defaultTunnelHost: "lxtunnel.cern.ch",
            defaultTunnelEnabled: true,
            tunnelHostRequired: true,
            defaultLocalSocksPort: 1081,
            pacDomain: .fixed("*.cern.ch"),
            passwordService: SSHAuto2FAPresets.cernLxplusPasswordService,
            totpService: SSHAuto2FAPresets.cernLxplusTOTPService,
            helpURLs: [
                "https://users-portal.web.cern.ch/",
                "https://cern.service-now.com/service-portal?id=outage&n=OTG0156449"
            ]
        ),
        ConnectionTemplate(
            id: .psiTier3,
            displayName: "PSI CMS Tier-3",
            profileName: "PSI CMS Tier-3",
            pacRuleName: "PSI Tier-3",
            credentialHost: "t3hop01.psi.ch",
            defaultTunnelHost: "",
            suggestedTunnelHosts: ["t3ui06.psi.ch", "t3ui07.psi.ch"],
            defaultTunnelEnabled: false,
            tunnelHostRequired: true,
            defaultLocalSocksPort: 1082,
            jumpHostFormat: "{username}@t3hop01.psi.ch",
            pacDomain: .tunnelHost,
            passwordService: SSHAuto2FAPresets.psiTier3PasswordService,
            totpService: SSHAuto2FAPresets.psiTier3TOTPService,
            helpURLs: [
                "https://tier3.pages.psi.ch/tier3-access/T3HopGateway/",
                "https://tier3.pages.psi.ch/tier3-access/HowToSetupYourAccount/"
            ]
        ),
        ConnectionTemplate(
            id: .psiGeneral,
            displayName: "PSI General",
            profileName: "PSI General",
            pacRuleName: "PSI",
            credentialHost: "hopx.psi.ch",
            defaultTunnelHost: "login.psi.ch",
            defaultTunnelEnabled: true,
            tunnelHostRequired: true,
            defaultLocalSocksPort: 1083,
            jumpHostFormat: "{username}@hopx.psi.ch",
            pacDomain: .fixed("*.psi.ch"),
            passwordService: SSHAuto2FAPresets.psiGeneralPasswordService,
            totpService: SSHAuto2FAPresets.psiGeneralTOTPService,
            helpURLs: [
                "https://www.psi.ch/en/computing/ssh-hop-ng",
                "https://www.psi.ch/en/computing/vpn"
            ]
        )
    ]

    public static func template(for id: ConnectionTemplateID) -> ConnectionTemplate? {
        templates.first { $0.id == id }
    }

    public static func defaultInput(
        for templateID: ConnectionTemplateID,
        in configuration: AppConfiguration,
        defaultUsername: String = NSUserName()
    ) -> ConnectionTemplateSetupInput {
        let template = template(for: templateID)
        let account = configuration.accounts.first { $0.id == templateID }
        let profile = template.flatMap { template in
            configuration.profiles.first { $0.name == template.profileName }
        }
        return ConnectionTemplateSetupInput(
            id: templateID,
            username: account?.username ?? profile?.user ?? defaultUsername,
            passwordAvailable: false,
            totpSeedAvailable: false,
            useForTunnelling: account?.tunnelEnabled ?? (profile != nil || template?.defaultTunnelEnabled ?? true),
            tunnelHost: account?.tunnelHost ?? profile?.host ?? template?.defaultTunnelHost ?? ""
        )
    }

    public static func credentialStatus(
        for input: ConnectionTemplateSetupInput,
        checker: GenericPasswordExistenceChecking
    ) -> ConnectionTemplateCredentialStatus {
        guard let template = template(for: input.id), !trimmed(input.username).isEmpty else {
            return ConnectionTemplateCredentialStatus(id: input.id, passwordState: .missing, totpSeedState: .missing)
        }
        return ConnectionTemplateCredentialStatus(
            id: input.id,
            passwordState: state(service: template.passwordService, account: input.username, checker: checker),
            totpSeedState: state(service: template.totpService, account: input.username, checker: checker)
        )
    }

    public static func apply(
        input: ConnectionTemplateSetupInput,
        to configuration: AppConfiguration
    ) throws -> (AppConfiguration, ConnectionTemplateSetupResult) {
        try validate(input)

        var updated = configuration
        var result = ConnectionTemplateSetupResult()

        guard let template = template(for: input.id) else {
            throw ConnectionTemplateSetupError.unknownTemplate(input.id)
        }

        result.configuredTemplates += 1
        let username = trimmed(input.username)
        let tunnelHost = trimmed(input.tunnelHost)
        let jumpHost = input.useForTunnelling ? template.jumpHost(username: username) : nil
        let interactiveHost = interactiveHost(for: template, tunnelHost: tunnelHost)
        let pacDomainPattern = input.useForTunnelling ? template.pacDomainPattern(tunnelHost: tunnelHost) : nil
        let keychain = KeychainReference(
            account: username,
            passwordService: template.passwordService,
            totpService: input.totpSeedAvailable ? template.totpService : nil
        )
        let account = AccountConfiguration(
            id: template.id,
            displayName: template.displayName,
            username: username,
            credentialHost: template.credentialHost,
            interactiveHost: interactiveHost,
            tunnelEnabled: input.useForTunnelling,
            tunnelHost: input.useForTunnelling ? tunnelHost : nil,
            jumpHost: jumpHost,
            localSocksPort: input.useForTunnelling ? localSocksPort(for: template, in: updated) : nil,
            pacDomainPattern: pacDomainPattern,
            keychain: keychain
        )
        upsertAccount(account, in: &updated)

        if input.useForTunnelling {
            let profileID = upsertProfile(
                template: template,
                username: username,
                tunnelHost: tunnelHost,
                interactiveHost: interactiveHost,
                jumpHost: jumpHost,
                keychain: keychain,
                hasTOTPSeed: input.totpSeedAvailable,
                in: &updated,
                result: &result
            )
            if let pacDomainPattern {
                ensurePACRule(
                    name: template.pacRuleName,
                    pattern: pacDomainPattern,
                    profileID: profileID,
                    in: &updated,
                    result: &result
                )
            }
        } else {
            removeGeneratedTunnel(for: template, from: &updated, result: &result)
        }

        orderPACRules(&updated)
        try PortConfigurationValidator.validate(updated)
        return (updated, result)
    }

    public static func validate(_ input: ConnectionTemplateSetupInput) throws {
        guard template(for: input.id) != nil else {
            throw ConnectionTemplateSetupError.unknownTemplate(input.id)
        }
        guard !trimmed(input.username).isEmpty else {
            throw ConnectionTemplateSetupError.missingUsername(input.id)
        }
        guard input.passwordAvailable else {
            throw ConnectionTemplateSetupError.missingPassword(input.id)
        }
        if input.useForTunnelling, trimmed(input.tunnelHost).isEmpty {
            throw ConnectionTemplateSetupError.missingTunnelHost(input.id)
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
        template: ConnectionTemplate,
        username: String,
        tunnelHost: String,
        interactiveHost: String?,
        jumpHost: String?,
        keychain: KeychainReference,
        hasTOTPSeed: Bool,
        in configuration: inout AppConfiguration,
        result: inout ConnectionTemplateSetupResult
    ) -> UUID {
        if let index = configuration.profiles.firstIndex(where: { $0.name == template.profileName }) {
            configuration.profiles[index].host = tunnelHost
            configuration.profiles[index].user = username
            configuration.profiles[index].interactiveHost = interactiveHost
            configuration.profiles[index].jumpHost = jumpHost
            configuration.profiles[index].authMode = hasTOTPSeed ? .passwordAndTOTP : .password
            configuration.profiles[index].keychain = keychain
            configuration.profiles[index].healthProbe = HealthProbe(host: tunnelHost, port: 22)
            result.updatedProfiles += 1
            return configuration.profiles[index].id
        }

        let profile = TunnelProfile(
            name: template.profileName,
            host: tunnelHost,
            user: username,
            localSocksPort: nextFreePort(preferred: template.defaultLocalSocksPort, profiles: configuration.profiles),
            interactiveHost: interactiveHost,
            jumpHost: jumpHost,
            authMode: hasTOTPSeed ? .passwordAndTOTP : .password,
            keychain: keychain,
            healthProbe: HealthProbe(host: tunnelHost, port: 22)
        )
        configuration.profiles.append(profile)
        result.createdProfiles += 1
        return profile.id
    }

    private static func interactiveHost(for template: ConnectionTemplate, tunnelHost: String) -> String? {
        if let interactiveHost = template.interactiveHost.map(trimmed), !interactiveHost.isEmpty {
            return interactiveHost
        }
        let tunnelHost = trimmed(tunnelHost)
        return tunnelHost.isEmpty ? nil : tunnelHost
    }

    private static func ensurePACRule(
        name: String,
        pattern: String,
        profileID: UUID,
        in configuration: inout AppConfiguration,
        result: inout ConnectionTemplateSetupResult
    ) {
        if let index = configuration.pacRules.firstIndex(where: { $0.name == name || $0.domainPattern == pattern }) {
            configuration.pacRules[index].name = name
            configuration.pacRules[index].domainPattern = pattern
            configuration.pacRules[index].profileID = profileID
            configuration.pacRules[index].enabled = true
            result.updatedPACRules += 1
            return
        }

        configuration.pacRules.append(PACRule(name: name, domainPattern: pattern, profileID: profileID))
        result.createdPACRules += 1
    }

    private static func removeGeneratedTunnel(
        for template: ConnectionTemplate,
        from configuration: inout AppConfiguration,
        result: inout ConnectionTemplateSetupResult
    ) {
        let removedProfileIDs = configuration.profiles
            .filter { $0.name == template.profileName }
            .map(\.id)
        if !removedProfileIDs.isEmpty {
            result.removedProfiles += removedProfileIDs.count
            configuration.profiles.removeAll { removedProfileIDs.contains($0.id) }
        }
        configuration.pacRules.removeAll { rule in
            removedProfileIDs.contains(rule.profileID) || rule.name == template.pacRuleName
        }
    }

    private static func localSocksPort(for template: ConnectionTemplate, in configuration: AppConfiguration) -> Int {
        configuration.profiles.first { $0.name == template.profileName }?.localSocksPort
            ?? nextFreePort(preferred: template.defaultLocalSocksPort, profiles: configuration.profiles)
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
        let tier3Rules = configuration.pacRules.filter { $0.name == ConnectionTemplate.psiTier3RuleName }
        guard !tier3Rules.isEmpty else { return }
        configuration.pacRules.removeAll { $0.name == ConnectionTemplate.psiTier3RuleName }
        let broadPSIIndex = configuration.pacRules.firstIndex { $0.domainPattern == "*.psi.ch" } ?? configuration.pacRules.endIndex
        configuration.pacRules.insert(contentsOf: tier3Rules, at: broadPSIIndex)
    }
}

private extension ConnectionTemplate {
    static let psiTier3RuleName = "PSI Tier-3"
}
