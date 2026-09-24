import CryptoKit
import Darwin
import Foundation

public enum SSHConfigAuditCategory: String, Codable, CaseIterable, Sendable {
    case safeReplacement = "safe_replacement"
    case manualRecommendation = "manual_recommendation"
    case information
}

public enum SSHConfigAuditFindingCode: String, Codable, Sendable {
    case equivalentProxyJump = "equivalent_proxy_jump"
    case missingCanonicalHostName = "missing_canonical_host_name"
    case configuredDestinationMissingRoute = "configured_destination_missing_route"
    case configuredDestinationDifferentRoute = "configured_destination_different_route"
    case intentionalDirectRoute = "intentional_direct_route"
    case proxyCommandUntouched = "proxy_command_untouched"
    case multiHopUntouched = "multi_hop_untouched"
    case dynamicMatch = "dynamic_match"
    case wildcardScope = "wildcard_scope"
    case unrelatedProxyJump = "unrelated_proxy_jump"
    case similarProxyJumpEndpoint = "similar_proxy_jump_endpoint"
    case managedAdapterAlreadyUsed = "managed_adapter_already_used"
    case legacyManagedAdapter = "legacy_managed_adapter"
    case unsupportedSyntax = "unsupported_syntax"
}

public enum SSHConfigAuditWarningCode: String, Codable, Sendable {
    case missingRootConfig = "missing_root_config"
    case unreadableFile = "unreadable_file"
    case includeCycle = "include_cycle"
    case includeDepthExceeded = "include_depth_exceeded"
    case unmatchedInclude = "unmatched_include"
    case unsafeMetadata = "unsafe_metadata"
    case unsupportedEncoding = "unsupported_encoding"
}

public struct SSHConfigSourceLocation: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var line: Int

    public init(path: String, line: Int) {
        self.path = path
        self.line = line
    }
}

public struct SSHConfigFileSnapshot: Codable, Equatable, Sendable {
    public var path: String
    public var contentHash: String
    public var device: UInt64
    public var inode: UInt64
    public var ownerUID: UInt32
    public var groupGID: UInt32
    public var permissions: UInt16
    public var size: UInt64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool
    public var isInsideSSHDirectory: Bool
    public var appearsGenerated: Bool
    public var canAutoFix: Bool

    public init(
        path: String,
        contentHash: String,
        device: UInt64,
        inode: UInt64,
        ownerUID: UInt32,
        groupGID: UInt32,
        permissions: UInt16,
        size: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64,
        isRegularFile: Bool,
        isSymbolicLink: Bool,
        isInsideSSHDirectory: Bool,
        appearsGenerated: Bool,
        canAutoFix: Bool
    ) {
        self.path = path
        self.contentHash = contentHash
        self.device = device
        self.inode = inode
        self.ownerUID = ownerUID
        self.groupGID = groupGID
        self.permissions = permissions
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.isInsideSSHDirectory = isInsideSSHDirectory
        self.appearsGenerated = appearsGenerated
        self.canAutoFix = canAutoFix
    }
}

public struct SSHConfigAuditFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var category: SSHConfigAuditCategory
    public var code: SSHConfigAuditFindingCode
    public var location: SSHConfigSourceLocation
    public var title: String
    public var reasoning: String
    public var context: String
    public var beforeText: String
    public var afterText: String?
    public var canApply: Bool

    public init(
        id: String,
        category: SSHConfigAuditCategory,
        code: SSHConfigAuditFindingCode,
        location: SSHConfigSourceLocation,
        title: String,
        reasoning: String,
        context: String,
        beforeText: String,
        afterText: String?,
        canApply: Bool
    ) {
        self.id = id
        self.category = category
        self.code = code
        self.location = location
        self.title = title
        self.reasoning = reasoning
        self.context = context
        self.beforeText = beforeText
        self.afterText = afterText
        self.canApply = canApply
    }
}

public struct SSHConfigAuditWarning: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var code: SSHConfigAuditWarningCode
    public var path: String
    public var line: Int?
    public var message: String

    public init(code: SSHConfigAuditWarningCode, path: String, line: Int? = nil, message: String) {
        id = StableSSHHash.short("\(code.rawValue)\u{0}\(path)\u{0}\(line ?? 0)\u{0}\(message)", length: 32)
        self.code = code
        self.path = path
        self.line = line
        self.message = message
    }
}

public struct SSHConfigAuditEndpoint: Codable, Equatable, Sendable {
    public var endpoint: HopEndpointKey
    public var adapterHost: String
    public var preferredAdapterHost: String
    public var adapterHosts: [String]
    public var profileNames: [String]

    public init(endpointAliases: HopAdapterEndpointAliases) {
        endpoint = endpointAliases.endpoint
        adapterHost = endpointAliases.endpoint.adapterHost
        preferredAdapterHost = endpointAliases.preferredAdapterHost
        adapterHosts = endpointAliases.adapterHosts
        profileNames = endpointAliases.profileNames
    }

    public init(endpoint: HopEndpointKey) {
        self.endpoint = endpoint
        adapterHost = endpoint.adapterHost
        preferredAdapterHost = endpoint.adapterHost
        adapterHosts = [endpoint.adapterHost]
        profileNames = []
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case adapterHost
        case preferredAdapterHost
        case adapterHosts
        case profileNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(HopEndpointKey.self, forKey: .endpoint)
        adapterHost = try container.decodeIfPresent(String.self, forKey: .adapterHost) ?? endpoint.adapterHost
        preferredAdapterHost = try container.decodeIfPresent(String.self, forKey: .preferredAdapterHost) ?? adapterHost
        adapterHosts = try container.decodeIfPresent([String].self, forKey: .adapterHosts) ?? [adapterHost]
        profileNames = try container.decodeIfPresent([String].self, forKey: .profileNames) ?? []
    }
}

public enum SSHConfigManagedIntegrationStatus: String, Codable, Equatable, Sendable {
    case current
    case notInstalled = "not_installed"
    case updateRequired = "update_required"
    case conflict
}

public struct SSHConfigManagedIntegration: Codable, Equatable, Sendable {
    public var status: SSHConfigManagedIntegrationStatus
    public var detail: String
    public var managedConfigPath: String
    public var configurationFingerprint: String?
    public var mainConfigHash: String?
    public var managedConfigHash: String?

    public init(
        status: SSHConfigManagedIntegrationStatus,
        detail: String,
        managedConfigPath: String,
        configurationFingerprint: String? = nil,
        mainConfigHash: String? = nil,
        managedConfigHash: String? = nil
    ) {
        self.status = status
        self.detail = detail
        self.managedConfigPath = managedConfigPath
        self.configurationFingerprint = configurationFingerprint
        self.mainConfigHash = mainConfigHash
        self.managedConfigHash = managedConfigHash
    }
}

public struct SSHConfigAuditReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var rootConfigPath: String
    public var sshDirectoryPath: String
    public var managedIntegration: SSHConfigManagedIntegration
    public var endpoints: [SSHConfigAuditEndpoint]
    public var files: [SSHConfigFileSnapshot]
    public var findings: [SSHConfigAuditFinding]
    public var warnings: [SSHConfigAuditWarning]

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case rootConfigPath
        case sshDirectoryPath
        case managedIntegration
        case endpoints
        case files
        case findings
        case warnings
    }

    public init(
        generatedAt: Date,
        rootConfigPath: String,
        sshDirectoryPath: String,
        managedIntegration: SSHConfigManagedIntegration? = nil,
        endpoints: [SSHConfigAuditEndpoint],
        files: [SSHConfigFileSnapshot],
        findings: [SSHConfigAuditFinding],
        warnings: [SSHConfigAuditWarning]
    ) {
        self.generatedAt = generatedAt
        self.rootConfigPath = rootConfigPath
        self.sshDirectoryPath = sshDirectoryPath
        self.managedIntegration = managedIntegration ?? SSHConfigManagedIntegration(
            status: .notInstalled,
            detail: "Managed OpenSSH integration status was not recorded.",
            managedConfigPath: URL(fileURLWithPath: sshDirectoryPath)
                .appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath).path
        )
        self.endpoints = endpoints
        self.files = files
        self.findings = findings
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        rootConfigPath = try container.decode(String.self, forKey: .rootConfigPath)
        sshDirectoryPath = try container.decode(String.self, forKey: .sshDirectoryPath)
        managedIntegration = try container.decodeIfPresent(
            SSHConfigManagedIntegration.self,
            forKey: .managedIntegration
        ) ?? SSHConfigManagedIntegration(
            status: .notInstalled,
            detail: "Managed OpenSSH integration status was not recorded.",
            managedConfigPath: URL(fileURLWithPath: sshDirectoryPath)
                .appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath).path
        )
        endpoints = try container.decode([SSHConfigAuditEndpoint].self, forKey: .endpoints)
        files = try container.decode([SSHConfigFileSnapshot].self, forKey: .files)
        findings = try container.decode([SSHConfigAuditFinding].self, forKey: .findings)
        warnings = try container.decode([SSHConfigAuditWarning].self, forKey: .warnings)
    }

    public var safeReplacements: [SSHConfigAuditFinding] {
        findings.filter { $0.category == .safeReplacement }
    }

    public var manualRecommendations: [SSHConfigAuditFinding] {
        findings.filter { $0.category == .manualRecommendation }
    }

    public var information: [SSHConfigAuditFinding] {
        findings.filter { $0.category == .information }
    }
}

public struct SSHConfigAuditService: Sendable {
    public var sshDirectory: URL
    public var now: @Sendable () -> Date

    public init(
        sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sshDirectory = sshDirectory.standardizedFileURL
        self.now = now
    }

    public func check(configuration: AppConfiguration) -> SSHConfigAuditReport {
        let managedConfigURL = sshDirectory.appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath)
        let existingManagedContent = try? String(contentsOf: managedConfigURL, encoding: .utf8)
        let catalog = SSHConfigSetupService.adapterAliases(
            for: configuration,
            preservingAliasesFrom: existingManagedContent
        )
        let endpoints = Dictionary(
            uniqueKeysWithValues: catalog.endpoints.map { ($0.endpoint, $0) }
        )
        let managedIntegration = managedIntegration(
            configuration: configuration,
            catalog: catalog,
            existingManagedContent: existingManagedContent
        )
        var loader = SSHConfigAuditLoader(sshDirectory: sshDirectory)
        let rootURL = sshDirectory.appendingPathComponent("config")
        let loadedLines = loader.loadRoot(rootURL)
        let blocks = SSHConfigAuditParser.blocks(from: loadedLines)
        let snapshotsByPath: [String: SSHConfigFileSnapshot] = Dictionary(
            uniqueKeysWithValues: loader.snapshots.map { ($0.path, $0) }
        )
        let analyzer = SSHConfigAuditAnalyzer(
            blocks: blocks,
            snapshotsByPath: snapshotsByPath,
            endpoints: endpoints,
            configuredDestinations: configuredDestinations(configuration, catalog: catalog),
            managedIntegrationIsCurrent: managedIntegration.status == .current
        )
        return SSHConfigAuditReport(
            generatedAt: now(),
            rootConfigPath: rootURL.path,
            sshDirectoryPath: sshDirectory.path,
            managedIntegration: managedIntegration,
            endpoints: catalog.endpoints.map(SSHConfigAuditEndpoint.init(endpointAliases:)),
            files: loader.snapshots.sorted { $0.path < $1.path },
            findings: analyzer.findings().sorted(by: findingSort),
            warnings: loader.warnings
        )
    }

    static func hasUnconditionalManagedInclude(in text: String) -> Bool {
        let acceptedPaths: Set<String> = [
            "~/.ssh/\(SSHConfigSetupService.managedConfigRelativePath)",
            SSHConfigSetupService.managedConfigRelativePath
        ]
        for (index, text) in text.components(separatedBy: "\n").enumerated() {
            let line = SSHConfigAuditLoadedLine(
                location: SSHConfigSourceLocation(path: "", line: index + 1),
                text: text
            )
            guard let directive = SSHConfigAuditParser.directive(from: line) else { continue }
            switch directive.keyword {
            case "host", "match":
                return false
            case "include":
                // Earlier includes (even earlier arguments on this line) can change
                // scope. Only a first, literal managed include is proven unconditional.
                guard let firstPath = SSHConfigAuditParser.tokens(directive.value).first else { return false }
                return acceptedPaths.contains(firstPath)
            default:
                continue
            }
        }
        return false
    }

    public static func literalHostAliasLocations(
        sshDirectory: URL,
        excluding excludedURL: URL? = nil
    ) -> [String: [SSHConfigSourceLocation]] {
        var loader = SSHConfigAuditLoader(sshDirectory: sshDirectory.standardizedFileURL)
        let lines = loader.loadRoot(sshDirectory.appendingPathComponent("config"))
        let excludedPath = excludedURL?.standardizedFileURL.path
        var result: [String: [SSHConfigSourceLocation]] = [:]
        for block in SSHConfigAuditParser.blocks(from: lines) {
            guard case .host(let patterns) = block.kind,
                  let header = block.header,
                  header.location.path != excludedPath else { continue }
            for pattern in patterns where !pattern.hasPrefix("!")
                && !pattern.contains("*")
                && !pattern.contains("?")
                && !pattern.contains("[") {
                result[pattern.lowercased(), default: []].append(header.location)
            }
        }
        return result
    }

    private func configuredDestinations(
        _ configuration: AppConfiguration,
        catalog: HopAdapterAliasCatalog
    ) -> [String: ConfiguredSSHDestination] {
        var destinations: [String: ConfiguredSSHDestination] = [:]
        for profile in configuration.profiles {
            guard let endpoint = try? HopEndpointKey(profile: profile),
                  let adapterHost = catalog.adapterHost(for: profile.id) else { continue }
            for host in [profile.host, profile.interactiveHost].compactMap({ $0 }) {
                let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                destinations[normalized] = ConfiguredSSHDestination(
                    endpoint: endpoint,
                    adapterHost: adapterHost
                )
            }
        }
        return destinations
    }

    private func managedIntegration(
        configuration: AppConfiguration,
        catalog: HopAdapterAliasCatalog,
        existingManagedContent: String?
    ) -> SSHConfigManagedIntegration {
        let rootURL = sshDirectory.appendingPathComponent("config")
        let managedURL = sshDirectory.appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath)
        let rootContent = try? String(contentsOf: rootURL, encoding: .utf8)
        let rootHash = rootContent.map(contentHash)
        let observedHash = existingManagedContent.map(contentHash)
        let expectedContent: String
        do {
            expectedContent = try SSHConfigSetupService.managedSnippet(
                for: configuration,
                preservingAliasesFrom: existingManagedContent
            )
        } catch {
            return SSHConfigManagedIntegration(
                status: .conflict,
                detail: "Managed OpenSSH config cannot be generated: \(error.localizedDescription)",
                managedConfigPath: managedURL.path,
                mainConfigHash: rootHash,
                managedConfigHash: observedHash
            )
        }
        let expectedHash = contentHash(expectedContent)
        let literalAliases = Self.literalHostAliasLocations(
            sshDirectory: sshDirectory,
            excluding: managedURL
        )
        for endpointAliases in catalog.endpoints {
            for alias in endpointAliases.adapterHosts where alias != endpointAliases.endpoint.adapterHost {
                if let location = literalAliases[alias.lowercased()]?.first {
                    return SSHConfigManagedIntegration(
                        status: .conflict,
                        detail: "Readable adapter alias \(alias) is already declared at \(location.path):\(location.line).",
                        managedConfigPath: managedURL.path,
                        configurationFingerprint: expectedHash,
                        mainConfigHash: rootHash,
                        managedConfigHash: observedHash
                    )
                }
            }
        }
        guard let rootContent,
              let existingManagedContent else {
            return SSHConfigManagedIntegration(
                status: .notInstalled,
                detail: "Install the managed OpenSSH include before applying adapter replacements.",
                managedConfigPath: managedURL.path,
                configurationFingerprint: expectedHash,
                mainConfigHash: rootHash,
                managedConfigHash: observedHash
            )
        }
        guard Self.hasUnconditionalManagedInclude(in: rootContent) else {
            return SSHConfigManagedIntegration(
                status: .updateRequired,
                detail: "Reinstall the managed OpenSSH include at the start of ~/.ssh/config, before Host, Match, or other Include directives.",
                managedConfigPath: managedURL.path,
                configurationFingerprint: expectedHash,
                mainConfigHash: rootHash,
                managedConfigHash: observedHash
            )
        }
        guard existingManagedContent == expectedContent else {
            return SSHConfigManagedIntegration(
                status: .updateRequired,
                detail: "Update the managed OpenSSH include to match the current profiles and readable aliases.",
                managedConfigPath: managedURL.path,
                configurationFingerprint: expectedHash,
                mainConfigHash: rootHash,
                managedConfigHash: observedHash
            )
        }
        return SSHConfigManagedIntegration(
            status: .current,
            detail: "Readable adapters are installed and current. They fail closed unless the app-owned hop master is running.",
            managedConfigPath: managedURL.path,
            configurationFingerprint: expectedHash,
            mainConfigHash: rootHash,
            managedConfigHash: observedHash
        )
    }

    private func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func findingSort(_ lhs: SSHConfigAuditFinding, _ rhs: SSHConfigAuditFinding) -> Bool {
        if lhs.category != rhs.category {
            let order: [SSHConfigAuditCategory] = [.safeReplacement, .manualRecommendation, .information]
            return order.firstIndex(of: lhs.category)! < order.firstIndex(of: rhs.category)!
        }
        if lhs.location.path != rhs.location.path { return lhs.location.path < rhs.location.path }
        if lhs.location.line != rhs.location.line { return lhs.location.line < rhs.location.line }
        return lhs.id < rhs.id
    }
}

private struct ConfiguredSSHDestination {
    var endpoint: HopEndpointKey
    var adapterHost: String
}

private struct SSHConfigAuditLoadedLine: Equatable {
    var location: SSHConfigSourceLocation
    var text: String
}

private struct SSHConfigAuditLoader {
    let sshDirectory: URL
    private(set) var snapshots: [SSHConfigFileSnapshot] = []
    private(set) var warnings: [SSHConfigAuditWarning] = []
    private var snapshotsByPath: [String: SSHConfigFileSnapshot] = [:]
    private let maximumIncludeDepth = 32

    init(sshDirectory: URL) {
        self.sshDirectory = sshDirectory
    }

    mutating func loadRoot(_ url: URL) -> [SSHConfigAuditLoadedLine] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            warnings.append(SSHConfigAuditWarning(
                code: .missingRootConfig,
                path: url.path,
                message: "No ~/.ssh/config file exists; there is nothing to audit."
            ))
            return []
        }
        let lines = load(url.standardizedFileURL, stack: [], depth: 0)
        snapshots = snapshotsByPath.values.sorted { $0.path < $1.path }
        return lines
    }

    private mutating func load(_ url: URL, stack: [String], depth: Int) -> [SSHConfigAuditLoadedLine] {
        let path = url.standardizedFileURL.path
        if stack.contains(path) {
            warnings.append(SSHConfigAuditWarning(
                code: .includeCycle,
                path: path,
                message: "Include cycle detected: \((stack + [path]).joined(separator: " → "))"
            ))
            return []
        }
        guard depth <= maximumIncludeDepth else {
            warnings.append(SSHConfigAuditWarning(
                code: .includeDepthExceeded,
                path: path,
                message: "Include nesting exceeds \(maximumIncludeDepth) levels."
            ))
            return []
        }

        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            warnings.append(SSHConfigAuditWarning(
                code: .unreadableFile,
                path: path,
                message: "Could not inspect included SSH config: \(String(cString: strerror(errno)))"
            ))
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            warnings.append(SSHConfigAuditWarning(
                code: .unreadableFile,
                path: path,
                message: "Could not read SSH config: \(error.localizedDescription)"
            ))
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else {
            warnings.append(SSHConfigAuditWarning(
                code: .unsupportedEncoding,
                path: path,
                message: "SSH config is not valid UTF-8 and was not analyzed."
            ))
            return []
        }

        let snapshot = makeSnapshot(path: path, data: data, text: text, metadata: metadata)
        snapshotsByPath[path] = snapshot
        if !snapshot.canAutoFix {
            warnings.append(SSHConfigAuditWarning(
                code: .unsafeMetadata,
                path: path,
                message: metadataWarning(for: snapshot)
            ))
        }

        let physicalLines = text.components(separatedBy: "\n")
        var output: [SSHConfigAuditLoadedLine] = []
        for (index, line) in physicalLines.enumerated() {
            if index == physicalLines.count - 1, line.isEmpty, text.hasSuffix("\n") { continue }
            let loaded = SSHConfigAuditLoadedLine(
                location: SSHConfigSourceLocation(path: path, line: index + 1),
                text: line
            )
            output.append(loaded)
            guard let directive = SSHConfigAuditParser.directive(from: loaded),
                  directive.keyword == "include" else { continue }
            let includeTokens = SSHConfigAuditParser.tokens(directive.value)
            if includeTokens.isEmpty {
                warnings.append(SSHConfigAuditWarning(
                    code: .unmatchedInclude,
                    path: path,
                    line: index + 1,
                    message: "Include has no path arguments."
                ))
            }
            for token in includeTokens {
                let matches = expandInclude(token)
                if matches.isEmpty {
                    warnings.append(SSHConfigAuditWarning(
                        code: .unmatchedInclude,
                        path: path,
                        line: index + 1,
                        message: "Include pattern did not match a readable path: \(token)"
                    ))
                }
                for includedURL in matches {
                    output += load(includedURL, stack: stack + [path], depth: depth + 1)
                }
            }
        }
        return output
    }

    private func expandInclude(_ token: String) -> [URL] {
        var expanded = token.replacingOccurrences(of: "%d", with: FileManager.default.homeDirectoryForCurrentUser.path)
        if expanded == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if expanded.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(expanded.dropFirst(2))).path
        } else if !expanded.hasPrefix("/") {
            expanded = sshDirectory.appendingPathComponent(expanded).path
        }

        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(expanded, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            guard let value = result.gl_pathv[index] else { return nil }
            return URL(fileURLWithPath: String(cString: value)).standardizedFileURL
        }
    }

    private func makeSnapshot(path: String, data: Data, text: String, metadata: stat) -> SSHConfigFileSnapshot {
        let type = metadata.st_mode & S_IFMT
        let isSymlink = type == S_IFLNK
        let isRegular = type == S_IFREG
        let standardizedSSHDirectory = sshDirectory.standardizedFileURL.path
        let inside = path == standardizedSSHDirectory || path.hasPrefix(standardizedSSHDirectory + "/")
        let appearsGenerated = text.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false)
            .prefix(5)
            .contains { line in
                let lower = line.lowercased()
                return lower.contains("generated by")
                    || lower.contains("do not edit")
                    || lower.contains("ssh autotunnel managed ssh config")
            }
        let permissions = UInt16(metadata.st_mode & 0o7777)
        let safeMetadata = isRegular
            && !isSymlink
            && metadata.st_uid == getuid()
            && (permissions & 0o022) == 0
            && inside
            && !appearsGenerated
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SSHConfigFileSnapshot(
            path: path,
            contentHash: digest,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            ownerUID: metadata.st_uid,
            groupGID: metadata.st_gid,
            permissions: permissions,
            size: UInt64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            isRegularFile: isRegular,
            isSymbolicLink: isSymlink,
            isInsideSSHDirectory: inside,
            appearsGenerated: appearsGenerated,
            canAutoFix: safeMetadata
        )
    }

    private func metadataWarning(for snapshot: SSHConfigFileSnapshot) -> String {
        if snapshot.isSymbolicLink { return "Symbolic-link SSH config files are audit-only and will not be edited." }
        if !snapshot.isRegularFile { return "Only regular SSH config files can be edited." }
        if snapshot.ownerUID != getuid() { return "SSH config is not owned by the current user and will not be edited." }
        if (snapshot.permissions & 0o022) != 0 { return "SSH config is writable by a group or other users and will not be edited." }
        if !snapshot.isInsideSSHDirectory { return "SSH config is outside ~/.ssh and will not be edited." }
        if snapshot.appearsGenerated { return "Generated SSH config files are audit-only and will not be edited." }
        return "SSH config metadata is not safe for automatic edits."
    }
}

private struct SSHConfigAuditDirective: Equatable {
    var keyword: String
    var value: String
    var line: SSHConfigAuditLoadedLine
}

private enum SSHConfigAuditBlockKind: Equatable {
    case global
    case host(patterns: [String])
    case match(tokens: [String], hasExec: Bool)

    var description: String {
        switch self {
        case .global: "Global"
        case .host(let patterns): "Host \(patterns.joined(separator: " "))"
        case .match(let tokens, _): "Match \(tokens.joined(separator: " "))"
        }
    }

    var hasDynamicMatch: Bool {
        if case .match(_, let hasExec) = self { return hasExec }
        return false
    }
}

private struct SSHConfigAuditBlock: Equatable {
    var kind: SSHConfigAuditBlockKind
    var header: SSHConfigAuditLoadedLine?
    var directives: [SSHConfigAuditDirective]
}

private enum SSHConfigAuditParser {
    static func blocks(from lines: [SSHConfigAuditLoadedLine]) -> [SSHConfigAuditBlock] {
        var blocks = [SSHConfigAuditBlock(kind: .global, header: nil, directives: [])]
        for line in lines {
            guard let parsed = directive(from: line) else { continue }
            if parsed.keyword == "host" {
                blocks.append(SSHConfigAuditBlock(
                    kind: .host(patterns: tokens(parsed.value)),
                    header: line,
                    directives: []
                ))
            } else if parsed.keyword == "match" {
                let matchTokens = tokens(parsed.value)
                blocks.append(SSHConfigAuditBlock(
                    kind: .match(
                        tokens: matchTokens,
                        hasExec: matchTokens.contains {
                            $0.trimmingCharacters(in: CharacterSet(charactersIn: "!")).lowercased() == "exec"
                        }
                    ),
                    header: line,
                    directives: []
                ))
            } else {
                blocks[blocks.count - 1].directives.append(parsed)
            }
        }
        return blocks
    }

    static func directive(from line: SSHConfigAuditLoadedLine) -> SSHConfigAuditDirective? {
        let text = line.text
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex, text[index] != "#" else { return nil }
        let keywordStart = index
        while index < text.endIndex, text[index].isLetter || text[index].isNumber {
            index = text.index(after: index)
        }
        guard index > keywordStart else { return nil }
        let keyword = text[keywordStart..<index].lowercased()
        if index < text.endIndex, text[index] == "=" { index = text.index(after: index) }
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        let rawValue = String(text[index...])
        let value = stripComment(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return SSHConfigAuditDirective(keyword: keyword, value: value, line: line)
    }

    static func tokens(_ value: String) -> [String] {
        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var tokenStarted = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                tokenStarted = true
            } else if character == "\\" {
                escaped = true
                tokenStarted = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                tokenStarted = true
            } else if character.isWhitespace {
                appendTokenBoundary(&current, tokenStarted: &tokenStarted, to: &values)
            } else if character == "#", !tokenStarted {
                break
            } else {
                current.append(character)
                tokenStarted = true
            }
        }
        if escaped { current.append("\\") }
        appendTokenBoundary(&current, tokenStarted: &tokenStarted, to: &values)
        return values
    }

    static func replacingValue(in line: String, with replacement: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        while index < line.endIndex, line[index].isLetter || line[index].isNumber { index = line.index(after: index) }
        guard index < line.endIndex else { return nil }
        if line[index] == "=" { index = line.index(after: index) }
        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        let valueStart = index
        let commentStart = commentIndex(in: line, startingAt: valueStart) ?? line.endIndex
        var valueEnd = commentStart
        while valueEnd > valueStart {
            let previous = line.index(before: valueEnd)
            guard line[previous].isWhitespace else { break }
            valueEnd = previous
        }
        return String(line[..<valueStart]) + replacement + String(line[valueEnd...])
    }

    private static func stripComment(_ value: String) -> String {
        guard let index = commentIndex(in: value, startingAt: value.startIndex) else { return value }
        return String(value[..<index])
    }

    private static func commentIndex(in value: String, startingAt start: String.Index) -> String.Index? {
        var quote: Character?
        var escaped = false
        var index = start
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return index
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func appendTokenBoundary(
        _ current: inout String,
        tokenStarted: inout Bool,
        to values: inout [String]
    ) {
        if tokenStarted {
            values.append(current)
            current = ""
            tokenStarted = false
        }
    }
}

private struct SSHConfigEffectiveSettings {
    var hostName: String?
    var user: String?
    var port: Int?
    var proxyJump: String?
    var proxyCommand: String?
    var hasConditionalMatch = false
}

private struct SSHConfigStaticEvaluator {
    let blocks: [SSHConfigAuditBlock]

    func settings(for originalHost: String) -> SSHConfigEffectiveSettings {
        var settings = SSHConfigEffectiveSettings()
        for block in blocks {
            if block.kind.hasDynamicMatch {
                settings.hasConditionalMatch = true
                continue
            }
            guard blockMatches(block.kind, originalHost: originalHost, settings: settings) else { continue }
            for directive in block.directives {
                switch directive.keyword {
                case "hostname" where settings.hostName == nil: settings.hostName = singleValue(directive.value)
                case "user" where settings.user == nil: settings.user = singleValue(directive.value)
                case "port" where settings.port == nil: settings.port = Int(singleValue(directive.value) ?? "")
                case "proxyjump" where settings.proxyJump == nil: settings.proxyJump = singleValue(directive.value)
                case "proxycommand" where settings.proxyCommand == nil: settings.proxyCommand = directive.value
                default: break
                }
            }
        }
        return settings
    }

    private func blockMatches(
        _ kind: SSHConfigAuditBlockKind,
        originalHost: String,
        settings: SSHConfigEffectiveSettings
    ) -> Bool {
        switch kind {
        case .global: return true
        case .host(let patterns): return matches(patterns: patterns, value: originalHost)
        case .match(let tokens, let hasExec):
            if hasExec { return false }
            if tokens.count == 1, tokens[0].lowercased() == "all" { return true }
            var index = 0
            while index < tokens.count {
                let criterion = tokens[index].lowercased()
                guard index + 1 < tokens.count else { return false }
                let patterns = tokens[index + 1].split(separator: ",").map(String.init)
                let candidate: String
                switch criterion {
                case "host": candidate = settings.hostName ?? originalHost
                case "originalhost": candidate = originalHost
                case "user": candidate = settings.user ?? ""
                case "localuser": candidate = NSUserName()
                default: return false
                }
                guard matches(patterns: patterns, value: candidate) else { return false }
                index += 2
            }
            return true
        }
    }

    private func matches(patterns: [String], value: String) -> Bool {
        var matched = false
        for rawPattern in patterns {
            let negated = rawPattern.hasPrefix("!")
            let pattern = negated ? String(rawPattern.dropFirst()) : rawPattern
            if fnmatch(pattern, value, FNM_CASEFOLD) == 0 {
                if negated { return false }
                matched = true
            }
        }
        return matched
    }

    private func singleValue(_ value: String) -> String? {
        let tokens = SSHConfigAuditParser.tokens(value)
        return tokens.count == 1 ? tokens[0] : nil
    }
}

private struct SSHConfigAuditAnalyzer {
    let blocks: [SSHConfigAuditBlock]
    let snapshotsByPath: [String: SSHConfigFileSnapshot]
    let endpoints: [HopEndpointKey: HopAdapterEndpointAliases]
    let configuredDestinations: [String: ConfiguredSSHDestination]
    let managedIntegrationIsCurrent: Bool

    func findings() -> [SSHConfigAuditFinding] {
        var findings: [SSHConfigAuditFinding] = []
        let evaluator = SSHConfigStaticEvaluator(blocks: blocks)
        let adapterEndpoints = Dictionary(
            endpoints.values.flatMap { endpointAliases in
                endpointAliases.adapterHosts.map { ($0.lowercased(), endpointAliases.endpoint) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        for block in blocks {
            if case .host(let patterns) = block.kind,
               patterns.contains(where: containsWildcard),
               let header = block.header {
                findings.append(makeFinding(
                    category: .information,
                    code: .wildcardScope,
                    line: header,
                    title: "Wildcard Host scope left unchanged",
                    reasoning: "The audit does not infer hop routing from wildcard or domain-like scopes.",
                    context: block.kind.description
                ))
            }
            if block.kind.hasDynamicMatch, let header = block.header {
                findings.append(makeFinding(
                    category: .information,
                    code: .dynamicMatch,
                    line: header,
                    title: "Dynamic Match condition is conditional",
                    reasoning: "Match exec is never executed by the audit. Directives in this block are reported with their condition preserved.",
                    context: block.kind.description
                ))
            }

            for directive in block.directives {
                switch directive.keyword {
                case "proxyjump":
                    findings += analyzeProxyJump(
                        directive,
                        block: block,
                        evaluator: evaluator,
                        adapterEndpoints: adapterEndpoints
                    )
                case "proxycommand":
                    findings.append(makeFinding(
                        category: .information,
                        code: .proxyCommandUntouched,
                        line: directive.line,
                        title: "ProxyCommand left unchanged",
                        reasoning: "ProxyCommand can encode arbitrary behavior and is never rewritten by SSH AutoTunnel.",
                        context: block.kind.description
                    ))
                default: break
                }
            }
            findings += canonicalHostNameRecommendations(block, evaluator: evaluator)
            findings += configuredDestinationRecommendations(block, evaluator: evaluator)
        }
        return deduplicated(findings)
    }

    private func analyzeProxyJump(
        _ directive: SSHConfigAuditDirective,
        block: SSHConfigAuditBlock,
        evaluator: SSHConfigStaticEvaluator,
        adapterEndpoints: [String: HopEndpointKey]
    ) -> [SSHConfigAuditFinding] {
        let tokens = SSHConfigAuditParser.tokens(directive.value)
        guard tokens.count == 1 else {
            return [makeFinding(
                category: .information,
                code: .unsupportedSyntax,
                line: directive.line,
                title: "Ambiguous ProxyJump syntax left unchanged",
                reasoning: "The ProxyJump value could not be resolved as one static target.",
                context: block.kind.description
            )]
        }
        let value = tokens[0]
        if value.lowercased() == "none" {
            return [makeFinding(
                category: .information,
                code: .intentionalDirectRoute,
                line: directive.line,
                title: "Intentional direct route",
                reasoning: "ProxyJump none is treated as an explicit decision and is never changed.",
                context: block.kind.description
            )]
        }
        if value.contains(",") {
            return [makeFinding(
                category: .information,
                code: .multiHopUntouched,
                line: directive.line,
                title: "Multi-hop ProxyJump left unchanged",
                reasoning: "V1 only supports equivalent single-hop replacements; hop chains require manual review.",
                context: block.kind.description
            )]
        }
        if let endpoint = adapterEndpoints[value.lowercased()], let aliases = endpoints[endpoint] {
            if aliases.currentAdapterHosts.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                return [makeFinding(
                    category: .information,
                    code: .managedAdapterAlreadyUsed,
                    line: directive.line,
                    title: "Managed hop adapter already in use",
                    reasoning: "This route already uses readable adapter \(value).",
                    context: block.kind.description
                )]
            }
            guard let replacementLine = SSHConfigAuditParser.replacingValue(
                in: directive.line.text,
                with: aliases.preferredAdapterHost
            ) else { return [] }
            return [makeFinding(
                category: .safeReplacement,
                code: .legacyManagedAdapter,
                line: directive.line,
                title: "Use the readable SSH AutoTunnel adapter",
                reasoning: "\(value) is a compatible legacy alias for \(aliases.preferredAdapterHost). The route and app-owned hop endpoint do not change.\(managedPrerequisite)",
                context: block.kind.description,
                afterText: replacementLine,
                canApply: canApply(directive)
            )]
        }
        guard let resolved = resolveProxyJump(value, evaluator: evaluator), let endpointAliases = endpoints[resolved] else {
            if let similarEndpoint = similarEndpoint(for: value, evaluator: evaluator) {
                let resolvedUser = resolvedJumpComponents(value, evaluator: evaluator)?.user
                let userDetail = resolvedUser.map { "username \($0)" } ?? "no explicit username"
                let preferredAdapterHost = endpoints[similarEndpoint]?.preferredAdapterHost
                    ?? similarEndpoint.adapterHost
                return [makeFinding(
                    category: .manualRecommendation,
                    code: .similarProxyJumpEndpoint,
                    line: directive.line,
                    title: "Review a near-matching hop route",
                    reasoning: "The jump target resolves to \(similarEndpoint.host):\(similarEndpoint.port) with \(userDetail), while SSH AutoTunnel owns that endpoint as \(similarEndpoint.destination). Replacing it could change the login identity, so it requires manual review.",
                    context: block.kind.description,
                    afterText: SSHConfigAuditParser.replacingValue(in: directive.line.text, with: preferredAdapterHost)
                )]
            }
            return [makeFinding(
                category: .information,
                code: .unrelatedProxyJump,
                line: directive.line,
                title: "ProxyJump does not match an app hop",
                reasoning: "The single-hop target does not resolve to a configured SSH AutoTunnel endpoint and was left unchanged.",
                context: block.kind.description
            )]
        }
        guard let replacementLine = SSHConfigAuditParser.replacingValue(
            in: directive.line.text,
            with: endpointAliases.preferredAdapterHost
        ) else {
            return [makeFinding(
                category: .information,
                code: .unsupportedSyntax,
                line: directive.line,
                title: "ProxyJump formatting requires manual review",
                reasoning: "The target is equivalent, but the source line could not be rewritten without risking formatting loss.",
                context: block.kind.description
            )]
        }
        let conditional = block.kind.hasDynamicMatch
            ? " The Match exec result remains conditional and is not evaluated."
            : ""
        return [makeFinding(
            category: .safeReplacement,
            code: .equivalentProxyJump,
            line: directive.line,
            title: "Reuse the SSH AutoTunnel hop master",
            reasoning: "\(value) resolves to \(resolved.destination):\(resolved.port), the same endpoint as \(endpointAliases.preferredAdapterHost). Only the target changes; the original scope and conditions remain intact.\(conditional)\(managedPrerequisite)",
            context: block.kind.description,
            afterText: replacementLine,
            canApply: canApply(directive)
        )]
    }

    private var managedPrerequisite: String {
        managedIntegrationIsCurrent
            ? ""
            : " Install or update the managed OpenSSH include before applying this replacement."
    }

    private func canApply(_ directive: SSHConfigAuditDirective) -> Bool {
        managedIntegrationIsCurrent
            && snapshotsByPath[directive.line.location.path]?.canAutoFix == true
    }

    private func canonicalHostNameRecommendations(
        _ block: SSHConfigAuditBlock,
        evaluator: SSHConfigStaticEvaluator
    ) -> [SSHConfigAuditFinding] {
        guard case .host(let patterns) = block.kind, let header = block.header else { return [] }
        guard patterns.count == 2,
              patterns.allSatisfy({ !$0.hasPrefix("!") && !containsWildcard($0) }) else { return [] }
        let positive = patterns.filter { !$0.hasPrefix("!") && !containsWildcard($0) }
        let fqdn = positive.filter { $0.contains(".") }
        let short = positive.filter { !$0.contains(".") }
        guard fqdn.count == 1, !short.isEmpty else { return [] }
        let canonical = fqdn[0]
        let matchingShort = short.filter { canonical.lowercased().hasPrefix($0.lowercased() + ".") }
        guard matchingShort.count == 1 else { return [] }
        let alias = matchingShort[0]
        guard evaluator.settings(for: alias).hostName == nil else { return [] }
        let indentation = block.directives.first.map { String($0.line.text.prefix { $0.isWhitespace }) } ?? "  "
        return [makeFinding(
            category: .manualRecommendation,
            code: .missingCanonicalHostName,
            line: header,
            title: "Declare the canonical hostname for \(alias)",
            reasoning: "The same literal Host block lists \(alias) and \(canonical), but has no HostName. Adding the unambiguous canonical name lets later safe Match host conditions evaluate the FQDN. This is a routing addition and is not applied automatically.",
            context: block.kind.description,
            afterText: header.text + "\n\(indentation)HostName \(canonical)"
        )]
    }

    private func configuredDestinationRecommendations(
        _ block: SSHConfigAuditBlock,
        evaluator: SSHConfigStaticEvaluator
    ) -> [SSHConfigAuditFinding] {
        guard case .host(let patterns) = block.kind, let header = block.header else { return [] }
        let literalDestinations = patterns
            .filter { !$0.hasPrefix("!") && !containsWildcard($0) }
            .compactMap { pattern -> (String, ConfiguredSSHDestination)? in
                guard let destination = configuredDestinations[pattern.lowercased()] else { return nil }
                return (pattern, destination)
            }
        return literalDestinations.compactMap { destination, expected in
            let settings = evaluator.settings(for: destination)
            guard settings.proxyCommand == nil,
                  settings.proxyJump?.lowercased() != "none",
                  !settings.hasConditionalMatch else { return nil }
            if let proxyJump = settings.proxyJump {
                let managedEndpoint = endpoints.values.first {
                    $0.adapterHosts.contains { $0.caseInsensitiveCompare(proxyJump) == .orderedSame }
                }?.endpoint
                guard managedEndpoint != expected.endpoint,
                      resolveProxyJump(proxyJump, evaluator: evaluator) != expected.endpoint else { return nil }
                return makeFinding(
                    category: .manualRecommendation,
                    code: .configuredDestinationDifferentRoute,
                    line: header,
                    title: "Review the route for \(destination)",
                    reasoning: "This literal destination is configured in SSH AutoTunnel for \(expected.endpoint.destination), but its current ProxyJump resolves differently. Existing policy is not changed automatically.",
                    context: block.kind.description,
                    afterText: "ProxyJump \(expected.adapterHost)"
                )
            }
            return makeFinding(
                category: .manualRecommendation,
                code: .configuredDestinationMissingRoute,
                line: header,
                title: "Review missing routing for \(destination)",
                reasoning: "This literal destination is explicitly configured in SSH AutoTunnel to use \(expected.endpoint.destination). Adding routing can change access policy, so the audit only recommends manual review.",
                context: block.kind.description,
                afterText: "ProxyJump \(expected.adapterHost)"
            )
        }
    }

    private func resolveProxyJump(_ value: String, evaluator: SSHConfigStaticEvaluator) -> HopEndpointKey? {
        guard let components = resolvedJumpComponents(value, evaluator: evaluator),
              let user = components.user,
              !user.isEmpty else { return nil }
        return HopEndpointKey(user: user, host: components.host, port: components.port)
    }

    private func similarEndpoint(
        for value: String,
        evaluator: SSHConfigStaticEvaluator
    ) -> HopEndpointKey? {
        guard let components = resolvedJumpComponents(value, evaluator: evaluator) else { return nil }
        let matches = endpoints.keys.filter {
            $0.host == components.host && $0.port == components.port && $0.user != components.user
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolvedJumpComponents(
        _ value: String,
        evaluator: SSHConfigStaticEvaluator
    ) -> (user: String?, host: String, port: Int)? {
        guard let parsed = parseJumpTarget(value) else { return nil }
        let aliasSettings = evaluator.settings(for: parsed.host)
        let host = (aliasSettings.hostName ?? parsed.host).lowercased()
        guard !host.contains("%"), !host.isEmpty else { return nil }
        let user = parsed.user ?? aliasSettings.user
        let port = parsed.port ?? aliasSettings.port ?? 22
        guard (1...65_535).contains(port) else { return nil }
        return (user, host, port)
    }

    private func parseJumpTarget(_ value: String) -> (user: String?, host: String, port: Int?)? {
        var user: String?
        var hostPort = value
        if let at = value.lastIndex(of: "@") {
            user = String(value[..<at])
            hostPort = String(value[value.index(after: at)...])
        }
        if hostPort.hasPrefix("[") {
            guard let closing = hostPort.firstIndex(of: "]") else { return nil }
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closing])
            let suffix = String(hostPort[hostPort.index(after: closing)...])
            if suffix.isEmpty { return (user, host, nil) }
            guard suffix.hasPrefix(":"), let port = Int(suffix.dropFirst()) else { return nil }
            return (user, host, port)
        }
        if let colon = hostPort.lastIndex(of: ":"), hostPort[..<colon].contains(":") == false {
            let portText = hostPort[hostPort.index(after: colon)...]
            if let port = Int(portText) {
                return (user, String(hostPort[..<colon]), port)
            }
        }
        return (user, hostPort, nil)
    }

    private func containsWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
    }

    private func makeFinding(
        category: SSHConfigAuditCategory,
        code: SSHConfigAuditFindingCode,
        line: SSHConfigAuditLoadedLine,
        title: String,
        reasoning: String,
        context: String,
        afterText: String? = nil,
        canApply: Bool = false
    ) -> SSHConfigAuditFinding {
        let id = StableSSHHash.short(
            "\(category.rawValue)\u{0}\(code.rawValue)\u{0}\(line.location.path)\u{0}\(line.location.line)\u{0}\(afterText ?? "")",
            length: 32
        )
        return SSHConfigAuditFinding(
            id: id,
            category: category,
            code: code,
            location: line.location,
            title: title,
            reasoning: reasoning,
            context: context,
            beforeText: line.text,
            afterText: afterText,
            canApply: canApply
        )
    }

    private func deduplicated(_ findings: [SSHConfigAuditFinding]) -> [SSHConfigAuditFinding] {
        var seen: Set<String> = []
        return findings.filter { seen.insert($0.id).inserted }
    }
}

public enum SSHConfigAuditTextRenderer {
    public static func render(_ report: SSHConfigAuditReport) -> String {
        var lines = [
            "SSH config audit:",
            "- Managed integration: \(report.managedIntegration.status.rawValue) — \(report.managedIntegration.detail)",
            "- Files: \(report.files.count)",
            "- Safe replacements: \(report.safeReplacements.count)",
            "- Manual recommendations: \(report.manualRecommendations.count)",
            "- Information: \(report.information.count)",
            "- Warnings: \(report.warnings.count)"
        ]
        for category in SSHConfigAuditCategory.allCases {
            let findings = report.findings.filter { $0.category == category }
            guard !findings.isEmpty else { continue }
            lines.append("\(categoryLabel(category)):")
            for finding in findings {
                lines.append("- \(finding.location.path):\(finding.location.line) \(finding.title)")
                lines.append("  \(finding.reasoning)")
                if let after = finding.afterText {
                    lines.append("  before: \(finding.beforeText)")
                    lines.append("  after:  \(after.replacingOccurrences(of: "\n", with: "\\n"))")
                }
            }
        }
        if !report.warnings.isEmpty {
            lines.append("Warnings:")
            for warning in report.warnings {
                let location = warning.line.map { "\(warning.path):\($0)" } ?? warning.path
                lines.append("- \(location) \(warning.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func categoryLabel(_ category: SSHConfigAuditCategory) -> String {
        switch category {
        case .safeReplacement: "Safe replacements"
        case .manualRecommendation: "Manual review"
        case .information: "Information"
        }
    }
}
