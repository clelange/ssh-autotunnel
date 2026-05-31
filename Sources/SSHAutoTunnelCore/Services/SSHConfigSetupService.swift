import Foundation

public struct SSHConfigInstallResult: Equatable, Sendable {
    public var managedConfigURL: URL
    public var mainConfigURL: URL
    public var backupURL: URL?
    public var wroteManagedConfig: Bool
    public var updatedMainConfig: Bool
    public var profileCount: Int

    public init(
        managedConfigURL: URL,
        mainConfigURL: URL,
        backupURL: URL?,
        wroteManagedConfig: Bool,
        updatedMainConfig: Bool,
        profileCount: Int
    ) {
        self.managedConfigURL = managedConfigURL
        self.mainConfigURL = mainConfigURL
        self.backupURL = backupURL
        self.wroteManagedConfig = wroteManagedConfig
        self.updatedMainConfig = updatedMainConfig
        self.profileCount = profileCount
    }
}

public enum SSHConfigSetupService {
    public static let managedIncludeStart = "# SSH AutoTunnel managed include"
    public static let managedIncludeEnd = "# End SSH AutoTunnel managed include"
    public static let managedConfigRelativePath = "config.d/ssh-autotunnel.conf"

    public static func managedSnippet(for configuration: AppConfiguration) -> String {
        let profiles = configuration.profiles
            .filter { normalizedJumpHost($0.jumpHost) != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !profiles.isEmpty else {
            return [
                "# SSH AutoTunnel managed SSH config",
                "# No jump-host profiles are configured."
            ].joined(separator: "\n") + "\n"
        }

        var jumpHosts: [String: JumpHostConfig] = [:]
        var finalHosts: [String: FinalHostConfig] = [:]

        for profile in profiles {
            guard let jumpHost = normalizedJumpHost(profile.jumpHost) else { continue }
            let jump = JumpHostConfig(jumpHost: jumpHost, fallbackUser: profile.user ?? profile.keychain.account)
            jumpHosts[jump.host] = jumpHosts[jump.host] ?? jump

            for host in finalSSHHosts(for: profile) {
                let finalHost = FinalHostConfig(
                    host: host,
                    user: normalizedValue(profile.user) ?? normalizedValue(profile.keychain.account),
                    proxyJump: jump.proxyJumpTarget
                )
                finalHosts["\(finalHost.host)|\(finalHost.proxyJump)"] = finalHost
            }
        }

        var lines: [String] = [
            "# SSH AutoTunnel managed SSH config",
            "# Safe to replace from SSH AutoTunnel.",
            ""
        ]

        for jump in jumpHosts.values.sorted(by: { $0.host < $1.host }) {
            lines += [
                "Host \(jump.host)",
                "  HostName \(jump.host)"
            ]
            if let user = jump.user {
                lines.append("  User \(user)")
            }
            lines += [
                "  ProxyJump none",
                "  ControlMaster auto",
                "  ControlPath ~/.ssh/sockets/%C",
                "  ControlPersist 600",
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
        now: Date = Date()
    ) throws -> SSHConfigInstallResult {
        let snippet = managedSnippet(for: configuration)
        let profileCount = configuration.profiles.filter { normalizedJumpHost($0.jumpHost) != nil }.count
        guard profileCount > 0 else {
            throw NSError(domain: "SSHConfigSetupService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No jump-host profiles are configured"])
        }

        let fileManager = FileManager.default
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        let managedConfigURL = sshDirectory.appendingPathComponent(managedConfigRelativePath)
        let mainConfigURL = sshDirectory.appendingPathComponent("config")

        try FileProtection.protectDirectory(sshDirectory)
        try FileProtection.protectDirectory(configDirectory)

        let oldManagedContent = try? String(contentsOf: managedConfigURL, encoding: .utf8)
        let wroteManagedConfig = oldManagedContent != snippet
        if wroteManagedConfig {
            try snippet.write(to: managedConfigURL, atomically: true, encoding: .utf8)
            try FileProtection.protectFile(managedConfigURL)
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
                ? mainConfigURL.deletingLastPathComponent()
                    .appendingPathComponent("config.ssh-autotunnel-backup-\(timestamp(now)).bak")
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

    private static func containsManagedInclude(in text: String) -> Bool {
        text.contains(managedIncludeStart)
            || text.contains("Include ~/.ssh/\(managedConfigRelativePath)")
            || text.contains("Include ~/.ssh/config.d/ssh-autotunnel.conf")
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

    private static func finalSSHHosts(for profile: TunnelProfile) -> [String] {
        var hosts = [profile.host]
        if let interactiveHost = normalizedValue(profile.interactiveHost), interactiveHost != profile.host {
            hosts.append(interactiveHost)
        }
        return Array(Set(hosts.compactMap(normalizedValue))).sorted()
    }

    private static func normalizedJumpHost(_ value: String?) -> String? {
        normalizedValue(value)
    }

    private static func normalizedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct JumpHostConfig: Equatable {
    var host: String
    var user: String?

    init(jumpHost: String, fallbackUser: String?) {
        let parts = jumpHost.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            user = parts[0]
            host = parts[1]
        } else {
            user = normalized(fallbackUser)
            host = jumpHost
        }
    }

    var proxyJumpTarget: String {
        guard let user else { return host }
        return "\(user)@\(host)"
    }
}

private struct FinalHostConfig: Equatable {
    var host: String
    var user: String?
    var proxyJump: String
}

private func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}
