import Foundation

public struct SSHConfigInstallResult: Equatable, Sendable {
    public var managedConfigURL: URL
    public var mainConfigURL: URL
    public var backupURL: URL?
    public var managedConfigBackupURL: URL?
    public var wroteManagedConfig: Bool
    public var updatedMainConfig: Bool
    public var profileCount: Int

    public init(
        managedConfigURL: URL,
        mainConfigURL: URL,
        backupURL: URL?,
        managedConfigBackupURL: URL?,
        wroteManagedConfig: Bool,
        updatedMainConfig: Bool,
        profileCount: Int
    ) {
        self.managedConfigURL = managedConfigURL
        self.mainConfigURL = mainConfigURL
        self.backupURL = backupURL
        self.managedConfigBackupURL = managedConfigBackupURL
        self.wroteManagedConfig = wroteManagedConfig
        self.updatedMainConfig = updatedMainConfig
        self.profileCount = profileCount
    }
}

public enum SSHConfigSetupError: LocalizedError, Equatable, Sendable {
    case noJumpHostProfiles
    case unsafeField(String)
    case adapterAliasConflict(alias: String, path: String, line: Int)

    public var errorDescription: String? {
        switch self {
        case .noJumpHostProfiles:
            "No jump-host profiles are configured"
        case .unsafeField(let label):
            "\(label) cannot be represented safely in OpenSSH config"
        case .adapterAliasConflict(let alias, let path, let line):
            "Readable adapter alias \(alias) is already declared at \(path):\(line). Rename the profile or the existing Host alias before installing."
        }
    }
}

public enum SSHConfigSetupService {
    public static let managedConfigVersion = 3
    public static let managedIncludeStart = "# SSH AutoTunnel managed include"
    public static let managedIncludeEnd = "# End SSH AutoTunnel managed include"
    public static let managedConfigRelativePath = "config.d/ssh-autotunnel.conf"

    public static func adapterAliases(
        for configuration: AppConfiguration,
        preservingAliasesFrom existingManagedContent: String? = nil
    ) -> HopAdapterAliasCatalog {
        HopAdapterNameResolver.resolve(
            profiles: configuration.profiles,
            historicalAliases: historicalAliases(from: existingManagedContent, profiles: configuration.profiles)
        )
    }

    public static func managedSnippet(
        for configuration: AppConfiguration,
        layout: HopControlPathLayout? = nil,
        preservingAliasesFrom existingManagedContent: String? = nil
    ) throws -> String {
        let profiles = configuration.profiles
            .filter { normalizedJumpHost($0.jumpHost) != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try validateManagedConfigFields(profiles)
        guard !profiles.isEmpty else {
            return [
                "# SSH AutoTunnel managed SSH config v\(managedConfigVersion)",
                "# No jump-host profiles are configured."
            ].joined(separator: "\n") + "\n"
        }

        let catalog = adapterAliases(for: configuration, preservingAliasesFrom: existingManagedContent)
        let resolvedLayout = try layout ?? HopControlPathLayout.default()
        var adapters: [HopEndpointKey: ManagedHopAdapterConfig] = [:]
        var finalHosts: [String: FinalHostConfig] = [:]

        for profile in profiles {
            let endpoint = try HopEndpointKey(profile: profile)
            let signature = HopSessionSignature(profile: profile, endpoint: endpoint)
            if let existing = adapters[endpoint], existing.signature != signature {
                throw HopControlMasterError.incompatibleConfiguration(endpoint: endpoint)
            }
            let paths = try resolvedLayout.paths(for: endpoint)
            adapters[endpoint] = ManagedHopAdapterConfig(
                endpoint: endpoint,
                signature: signature,
                controlPath: paths.controlPath,
                adapterHosts: catalog.aliases(for: endpoint)?.adapterHosts ?? [endpoint.adapterHost],
                profileNames: catalog.aliases(for: endpoint)?.profileNames ?? [profile.name]
            )

            let profileAdapterHost = catalog.adapterHost(for: profile.id) ?? endpoint.adapterHost
            for host in finalSSHHosts(for: profile) {
                let finalHost = FinalHostConfig(
                    host: host,
                    user: normalizedValue(profile.user) ?? normalizedValue(profile.keychain.account),
                    proxyJump: profileAdapterHost
                )
                let key = "\(finalHost.host)|\(endpoint.stableHash)"
                if let existing = finalHosts[key] {
                    finalHosts[key] = existing.proxyJump < finalHost.proxyJump ? existing : finalHost
                } else {
                    finalHosts[key] = finalHost
                }
            }
        }

        var lines: [String] = [
            "# SSH AutoTunnel managed SSH config v\(managedConfigVersion)",
            "# Safe to replace from SSH AutoTunnel.",
            "# Internal hop adapters fail closed unless the app-owned ControlMaster is running.",
            ""
        ]

        for adapter in adapters.values.sorted(by: { $0.endpoint.adapterHost < $1.endpoint.adapterHost }) {
            lines += [
                "# Profiles: \(adapter.profileNames.joined(separator: ", ")); endpoint: \(adapter.endpoint.destination):\(adapter.endpoint.port)",
                "Host \(adapter.adapterHosts.joined(separator: " "))",
                "  HostName hop-not-connected.start-ssh-autotunnel.invalid",
                "  User unused",
                "  ProxyJump none",
                "  ControlMaster no",
                "  ControlPersist no",
                "  ControlPath \(adapter.controlPath)",
                "  BatchMode yes",
                "  ClearAllForwardings yes",
                ""
            ]
        }

        for finalHost in finalHosts.values.sorted(by: { $0.host < $1.host }) {
            lines.append("Host \(finalHost.host)")
            if let user = finalHost.user {
                lines.append("  User \(user)")
            }
            lines += [
                "  ProxyJump \(finalHost.proxyJump)",
                ""
            ]
        }

        return lines.joined(separator: "\n")
    }

    public static func installManagedConfig(
        for configuration: AppConfiguration,
        sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true),
        now: Date = Date(),
        layout: HopControlPathLayout? = nil
    ) throws -> SSHConfigInstallResult {
        let profileCount = configuration.profiles.filter { normalizedJumpHost($0.jumpHost) != nil }.count
        guard profileCount > 0 else {
            throw SSHConfigSetupError.noJumpHostProfiles
        }

        let fileManager = FileManager.default
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        let managedConfigURL = sshDirectory.appendingPathComponent(managedConfigRelativePath)
        let mainConfigURL = sshDirectory.appendingPathComponent("config")

        try FileProtection.protectDirectory(sshDirectory)
        try FileProtection.protectDirectory(configDirectory)

        let oldManagedContent = try? String(contentsOf: managedConfigURL, encoding: .utf8)
        let catalog = adapterAliases(for: configuration, preservingAliasesFrom: oldManagedContent)
        let literalAliases = SSHConfigAuditService.literalHostAliasLocations(
            sshDirectory: sshDirectory,
            excluding: managedConfigURL
        )
        for endpointAliases in catalog.endpoints {
            for alias in endpointAliases.adapterHosts where alias != endpointAliases.endpoint.adapterHost {
                if let location = literalAliases[alias.lowercased()]?.first {
                    throw SSHConfigSetupError.adapterAliasConflict(
                        alias: alias,
                        path: location.path,
                        line: location.line
                    )
                }
            }
        }
        let snippet = try managedSnippet(
            for: configuration,
            layout: layout,
            preservingAliasesFrom: oldManagedContent
        )
        let wroteManagedConfig = oldManagedContent != snippet
        let managedConfigBackupURL: URL?
        if wroteManagedConfig {
            if fileManager.fileExists(atPath: managedConfigURL.path) {
                let backup = availableBackupURL(
                    in: managedConfigURL.deletingLastPathComponent(),
                    baseName: "ssh-autotunnel.conf.ssh-autotunnel-backup-\(timestamp(now))"
                )
                try fileManager.copyItem(at: managedConfigURL, to: backup)
                try FileProtection.protectFile(backup)
                managedConfigBackupURL = backup
            } else {
                managedConfigBackupURL = nil
            }
            try snippet.write(to: managedConfigURL, atomically: true, encoding: .utf8)
            try FileProtection.protectFile(managedConfigURL)
        } else {
            managedConfigBackupURL = nil
        }

        let includeBlock = includeBlockText()
        let existingMainConfig = (try? String(contentsOf: mainConfigURL, encoding: .utf8)) ?? ""
        let updatedMainConfig: Bool
        let backupURL: URL?

        if containsManagedInclude(in: existingMainConfig) {
            updatedMainConfig = false
            backupURL = nil
            if !fileManager.fileExists(atPath: mainConfigURL.path) {
                try existingMainConfig.write(to: mainConfigURL, atomically: true, encoding: .utf8)
                try FileProtection.protectFile(mainConfigURL)
            }
        } else {
            backupURL = fileManager.fileExists(atPath: mainConfigURL.path)
                ? availableBackupURL(
                    in: mainConfigURL.deletingLastPathComponent(),
                    baseName: "config.ssh-autotunnel-backup-\(timestamp(now))"
                )
                : nil
            if let backupURL {
                try fileManager.copyItem(at: mainConfigURL, to: backupURL)
                try FileProtection.protectFile(backupURL)
            }
            let updated = insertingIncludeBlock(includeBlock, into: existingMainConfig)
            try updated.write(to: mainConfigURL, atomically: true, encoding: .utf8)
            try FileProtection.protectFile(mainConfigURL)
            updatedMainConfig = true
        }

        return SSHConfigInstallResult(
            managedConfigURL: managedConfigURL,
            mainConfigURL: mainConfigURL,
            backupURL: backupURL,
            managedConfigBackupURL: managedConfigBackupURL,
            wroteManagedConfig: wroteManagedConfig,
            updatedMainConfig: updatedMainConfig,
            profileCount: profileCount
        )
    }

    private static func includeBlockText() -> String {
        [
            managedIncludeStart,
            "Include ~/.ssh/\(managedConfigRelativePath)",
            managedIncludeEnd
        ].joined(separator: "\n")
    }

    public static func containsManagedInclude(in text: String) -> Bool {
        let acceptedPaths: Set<String> = [
            "~/.ssh/\(managedConfigRelativePath)",
            "~/.ssh/config.d/ssh-autotunnel.conf",
            managedConfigRelativePath
        ]
        return text.components(separatedBy: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("#") else { return false }
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            guard tokens.first?.lowercased() == "include" else { return false }
            return tokens.dropFirst().contains(where: acceptedPaths.contains)
        }
    }

    private static func insertingIncludeBlock(_ includeBlock: String, into existing: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return includeBlock + "\n"
        }
        return includeBlock + "\n\n" + existing
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func availableBackupURL(in directory: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        var suffix = 1
        var candidate = directory.appendingPathComponent("\(baseName).bak")
        while fileManager.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix).bak")
        }
        return candidate
    }

    private static func finalSSHHosts(for profile: TunnelProfile) -> [String] {
        var hosts = [profile.host]
        if let interactiveHost = normalizedValue(profile.interactiveHost), interactiveHost != profile.host {
            hosts.append(interactiveHost)
        }
        return Array(Set(hosts.compactMap(normalizedValue))).sorted()
    }

    private static func validateManagedConfigFields(_ profiles: [TunnelProfile]) throws {
        for profile in profiles {
            if containsOpenSSHConfigUnsafeCharacters(profile.host) {
                throw SSHConfigSetupError.unsafeField("Profile '\(profile.name)' host")
            }
            if let interactiveHost = normalizedValue(profile.interactiveHost),
               containsOpenSSHConfigUnsafeCharacters(interactiveHost) {
                throw SSHConfigSetupError.unsafeField("Profile '\(profile.name)' interactive host")
            }
            if let user = normalizedValue(profile.user),
               containsOpenSSHConfigUnsafeCharacters(user) {
                throw SSHConfigSetupError.unsafeField("Profile '\(profile.name)' user")
            }
            if containsOpenSSHConfigUnsafeCharacters(profile.keychain.account) {
                throw SSHConfigSetupError.unsafeField("Profile '\(profile.name)' Keychain account")
            }
            if let jumpHost = normalizedJumpHost(profile.jumpHost) {
                try validateProxyJumpTarget(jumpHost, profileName: profile.name)
            }
        }
    }

    private static func validateProxyJumpTarget(_ value: String, profileName: String) throws {
        let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            if containsOpenSSHConfigUnsafeCharacters(parts[0]) {
                throw SSHConfigSetupError.unsafeField("Profile '\(profileName)' jump host user")
            }
            if containsOpenSSHConfigUnsafeCharacters(parts[1]) {
                throw SSHConfigSetupError.unsafeField("Profile '\(profileName)' jump host")
            }
        } else if containsOpenSSHConfigUnsafeCharacters(value) {
            throw SSHConfigSetupError.unsafeField("Profile '\(profileName)' jump host")
        }
    }

    private static func containsOpenSSHConfigUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 0x2028
                || scalar.value == 0x2029
        }
    }

    private static func normalizedJumpHost(_ value: String?) -> String? {
        normalizedValue(value)
    }

    private static func normalizedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func historicalAliases(
        from existingManagedContent: String?,
        profiles: [TunnelProfile]
    ) -> [HopEndpointKey: Set<String>] {
        guard let existingManagedContent,
              existingManagedContent.contains("# SSH AutoTunnel managed SSH config v3") else { return [:] }
        let endpoints = profiles.compactMap { try? HopEndpointKey(profile: $0) }
        let endpointByLegacyAlias = Dictionary(
            endpoints.map { ($0.adapterHost, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [HopEndpointKey: Set<String>] = [:]
        for line in existingManagedContent.components(separatedBy: "\n") {
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.first?.lowercased() == "host",
                  let endpoint = tokens.dropFirst().compactMap({ endpointByLegacyAlias[$0] }).first else { continue }
            let aliases = tokens.dropFirst().filter {
                $0 != endpoint.adapterHost && HopAdapterNameResolver.isSafeAdapterHost($0)
            }
            result[endpoint, default: []].formUnion(aliases)
        }
        return result
    }
}

private struct ManagedHopAdapterConfig: Equatable {
    var endpoint: HopEndpointKey
    var signature: HopSessionSignature
    var controlPath: String
    var adapterHosts: [String]
    var profileNames: [String]
}

private struct FinalHostConfig: Equatable {
    var host: String
    var user: String?
    var proxyJump: String
}
