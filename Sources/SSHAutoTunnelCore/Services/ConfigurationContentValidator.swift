import Foundation

public struct ConfigurationContentValidationError: LocalizedError, Equatable, Sendable {
    public var messages: [String]

    public var errorDescription: String? {
        "Invalid configuration content: \(messages.joined(separator: "; "))"
    }
}

public enum ConfigurationContentValidator {
    public static func validate(_ configuration: AppConfiguration) throws {
        var messages: [String] = []

        for account in configuration.templateAccounts {
            messages += validationMessages(for: account)
        }
        for profile in configuration.profiles {
            messages += validationMessages(for: profile)
        }
        for rule in configuration.pacRules {
            messages += validationMessages(for: rule)
        }
        for rule in configuration.networkRules {
            messages += validationMessages(for: rule)
        }
        messages += validationMessages(for: configuration.pacAppendSource)
        messages += validationMessages(for: configuration.interactiveTerminal)

        if !messages.isEmpty {
            throw ConfigurationContentValidationError(messages: messages)
        }
    }

    public static func validate(profile: TunnelProfile) throws {
        let messages = validationMessages(for: profile)
        if !messages.isEmpty {
            throw ConfigurationContentValidationError(messages: messages)
        }
    }

    public static func validate(pacRule: PACRule) throws {
        let messages = validationMessages(for: pacRule)
        if !messages.isEmpty {
            throw ConfigurationContentValidationError(messages: messages)
        }
    }

    public static func validate(networkRule: NetworkPolicyRule) throws {
        let messages = validationMessages(for: networkRule)
        if !messages.isEmpty {
            throw ConfigurationContentValidationError(messages: messages)
        }
    }

    public static func warnings(for configuration: AppConfiguration) -> [String] {
        configuration.profiles.flatMap(warnings(for:))
    }

    public static func warnings(for profile: TunnelProfile) -> [String] {
        riskyExtraSSHOptionWarnings(for: profile)
    }

    public static func validationMessages(for profile: TunnelProfile) -> [String] {
        var messages: [String] = []
        messages += invalidTextMessages([
            ("Profile '\(profile.name)' name", profile.name),
            ("Profile '\(profile.name)' host", profile.host),
            ("Profile '\(profile.name)' user", profile.user),
            ("Profile '\(profile.name)' interactive host", profile.interactiveHost),
            ("Profile '\(profile.name)' jump host", profile.jumpHost),
            ("Profile '\(profile.name)' Keychain account", profile.keychain.account),
            ("Profile '\(profile.name)' password Keychain service", profile.keychain.passwordService),
            ("Profile '\(profile.name)' TOTP Keychain service", profile.keychain.totpService),
            ("Profile '\(profile.name)' health probe host", profile.healthProbe?.host),
            ("Profile '\(profile.name)' SSH bind address", profile.curatedSSHOptions.bindAddress),
            ("Profile '\(profile.name)' SSH proxy command", profile.curatedSSHOptions.proxyCommand)
        ])
        for (index, tag) in profile.tags.enumerated() {
            messages += invalidTextMessages([("Profile '\(profile.name)' tag \(index + 1)", tag)])
        }
        for (index, path) in profile.curatedSSHOptions.identityFiles.enumerated() {
            messages += invalidTextMessages([("Profile '\(profile.name)' identity file \(index + 1)", path)])
        }
        for (index, path) in profile.curatedSSHOptions.certificateFiles.enumerated() {
            messages += invalidTextMessages([("Profile '\(profile.name)' certificate file \(index + 1)", path)])
        }
        for (index, forwarding) in profile.localPortForwardings.enumerated() {
            messages += invalidTextMessages([
                ("Profile '\(profile.name)' local forward \(index + 1) bind address", forwarding.bindAddress),
                ("Profile '\(profile.name)' local forward \(index + 1) target host", forwarding.targetHost)
            ])
        }
        if hasProxyJump(profile), hasProxyCommand(profile) {
            messages.append("Profile '\(profile.name)' cannot define both ProxyJump and ProxyCommand")
        }
        if let maxReconnectAttempts = profile.curatedSSHOptions.maxReconnectAttempts, maxReconnectAttempts < 0 {
            messages.append("Profile '\(profile.name)' reconnect attempt limit must be zero or greater")
        }
        for (index, option) in profile.extraSSHOptions.enumerated() {
            messages += invalidTextMessages([("Profile '\(profile.name)' extra SSH option \(index + 1)", option)])
        }
        return messages
    }

    public static func validationMessages(for rule: PACRule) -> [String] {
        invalidTextMessages([
            ("PAC rule '\(rule.name)' name", rule.name),
            ("PAC rule '\(rule.name)' domain pattern", rule.domainPattern)
        ])
    }

    public static func validationMessages(for rule: NetworkPolicyRule) -> [String] {
        var messages = invalidTextMessages([
            ("Network rule '\(rule.name)' name", rule.name),
            ("Network rule '\(rule.name)' Wi-Fi SSID", rule.match.wifiSSID),
            ("Network rule '\(rule.name)' Wi-Fi BSSID", rule.match.wifiBSSID),
            ("Network rule '\(rule.name)' service name match", rule.match.serviceNameContains),
            ("Network rule '\(rule.name)' search domain match", rule.match.searchDomainContains),
            ("Network rule '\(rule.name)' gateway", rule.match.gateway)
        ])
        if rule.match.isEmpty {
            messages.append("Network rule '\(rule.name)' must define at least one match field")
        }
        return messages
    }

    private static func validationMessages(for account: ConnectionTemplateAccount) -> [String] {
        invalidTextMessages([
            ("Template account '\(account.displayName)' display name", account.displayName),
            ("Template account '\(account.displayName)' username", account.username),
            ("Template account '\(account.displayName)' credential host", account.credentialHost),
            ("Template account '\(account.displayName)' interactive host", account.interactiveHost),
            ("Template account '\(account.displayName)' tunnel host", account.tunnelHost),
            ("Template account '\(account.displayName)' jump host", account.jumpHost),
            ("Template account '\(account.displayName)' PAC domain pattern", account.pacDomainPattern),
            ("Template account '\(account.displayName)' Keychain account", account.keychain.account),
            ("Template account '\(account.displayName)' password Keychain service", account.keychain.passwordService),
            ("Template account '\(account.displayName)' TOTP Keychain service", account.keychain.totpService)
        ])
    }

    private static func validationMessages(for source: PACAppendSource) -> [String] {
        invalidTextMessages([("Existing PAC source location", source.location)])
    }

    private static func validationMessages(for preference: InteractiveTerminalPreference) -> [String] {
        invalidTextMessages([("Custom terminal application path", preference.customApplicationPath)])
    }

    private static func hasProxyJump(_ profile: TunnelProfile) -> Bool {
        let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !jumpHost.isEmpty
    }

    private static func hasProxyCommand(_ profile: TunnelProfile) -> Bool {
        let proxyCommand = profile.curatedSSHOptions.proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !proxyCommand.isEmpty
    }

    private static func invalidTextMessages(_ fields: [(String, String?)]) -> [String] {
        fields.compactMap { label, value in
            guard let value, containsUnsafeControlCharacter(value) else { return nil }
            return "\(label) contains a control character or newline"
        }
    }

    private static func containsUnsafeControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || scalar.value == 0x2028
                || scalar.value == 0x2029
        }
    }

    private static func riskyExtraSSHOptionWarnings(for profile: TunnelProfile) -> [String] {
        var warnings: [String] = []
        let options = profile.extraSSHOptions

        for index in options.indices {
            let option = options[index]
            let lower = option.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let candidate: String?
            if lower == "-o", options.indices.contains(index + 1) {
                candidate = options[index + 1]
            } else if lower.hasPrefix("-o") {
                candidate = String(option.dropFirst(2))
            } else {
                candidate = option
            }

            guard let candidate else { continue }
            if let warning = riskyWarning(profileName: profile.name, option: candidate), !warnings.contains(warning) {
                warnings.append(warning)
            }
        }

        return warnings
    }

    private static func riskyWarning(profileName: String, option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")

        if lower.hasPrefix("proxycommand") {
            return "Profile '\(profileName)' uses ProxyCommand; only import or run this profile if the SSH option source is trusted"
        }
        if lower.hasPrefix("localcommand") {
            return "Profile '\(profileName)' uses LocalCommand; connecting may execute a local command"
        }
        if compact.hasPrefix("permitlocalcommand=yes") || compact == "permitlocalcommandyes" {
            return "Profile '\(profileName)' enables PermitLocalCommand; connecting may execute a local command"
        }
        if compact.hasPrefix("stricthostkeychecking=no") {
            return "Profile '\(profileName)' disables strict host-key checking"
        }
        if compact.hasPrefix("userknownhostsfile=/dev/null") {
            return "Profile '\(profileName)' ignores known-host persistence"
        }
        return nil
    }
}
