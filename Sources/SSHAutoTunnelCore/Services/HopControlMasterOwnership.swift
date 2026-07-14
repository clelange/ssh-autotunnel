import CryptoKit
import Darwin
import Foundation

public struct HopEndpointKey: Codable, Equatable, Hashable, Sendable {
    public var user: String
    public var host: String
    public var port: Int

    public init(user: String, host: String, port: Int) {
        self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
    }

    public init(profile: TunnelProfile) throws {
        let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !jumpHost.isEmpty else {
            throw HopControlMasterError.invalidJumpHost("Jump host is not configured")
        }

        let parts = jumpHost.split(separator: "@", maxSplits: 1).map(String.init)
        let host: String
        let user: String
        if parts.count == 2 {
            user = parts[0]
            host = parts[1]
        } else {
            user = profile.user?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? profile.keychain.account.trimmingCharacters(in: .whitespacesAndNewlines)
            host = jumpHost
        }

        guard !user.isEmpty, !host.isEmpty else {
            throw HopControlMasterError.invalidJumpHost("Jump host must resolve to a username and hostname")
        }
        guard (1...65_535).contains(profile.sshPort) else {
            throw HopControlMasterError.invalidJumpHost("Jump host port must be between 1 and 65535")
        }
        self.init(user: user, host: host, port: profile.sshPort)
    }

    public var destination: String {
        "\(user)@\(host)"
    }

    public var stableHash: String {
        StableSSHHash.short("\(user)\u{0}\(host)\u{0}\(port)")
    }

    public var adapterHost: String {
        "ssh-autotunnel-hop-\(stableHash)"
    }
}

public struct HopSessionSignature: Codable, Equatable, Hashable, Sendable {
    public var authMode: TunnelAuthMode
    public var hostKeyPolicy: SSHHostKeyPolicy
    public var keychain: KeychainReference
    public var readinessPatterns: [String]

    public init(
        authMode: TunnelAuthMode,
        hostKeyPolicy: SSHHostKeyPolicy,
        keychain: KeychainReference,
        readinessPatterns: [String]
    ) {
        self.authMode = authMode
        self.hostKeyPolicy = hostKeyPolicy
        self.keychain = keychain
        self.readinessPatterns = readinessPatterns
    }

    public init(profile: TunnelProfile, endpoint: HopEndpointKey) {
        self.init(
            authMode: profile.authMode,
            hostKeyPolicy: profile.hostKeyPolicy,
            keychain: profile.keychain,
            readinessPatterns: JumpHostControlMasterFactory.readyPatterns(for: endpoint.host)
        )
    }

    public var stableHash: String {
        let fields = [
            authMode.rawValue,
            hostKeyPolicy.rawValue,
            keychain.account,
            keychain.passwordService ?? "",
            keychain.totpService ?? "",
            readinessPatterns.joined(separator: "\u{0}")
        ]
        return StableSSHHash.short(fields.joined(separator: "\u{1}"))
    }
}

public enum HopConnectionIssueCode: String, Codable, Equatable, Sendable {
    case foreignControlSocket = "foreign_control_socket"
    case staleUnownedSocket = "stale_unowned_socket"
    case anotherAppInstance = "another_app_instance"
    case incompatibleHopConfiguration = "incompatible_hop_configuration"
    case serverExistingSession = "server_existing_session"
    case possibleExternalSessionTimeout = "possible_external_session_timeout"
    case appMasterInterrupted = "app_master_interrupted"
    case invalidRuntimeDirectory = "invalid_runtime_directory"
}

public struct HopConnectionIssue: Codable, Equatable, Sendable {
    public var code: HopConnectionIssueCode
    public var summary: String
    public var detail: String
    public var recoverySuggestion: String
    public var retryable: Bool

    public init(
        code: HopConnectionIssueCode,
        summary: String,
        detail: String,
        recoverySuggestion: String,
        retryable: Bool
    ) {
        self.code = code
        self.summary = summary
        self.detail = detail
        self.recoverySuggestion = recoverySuggestion
        self.retryable = retryable
    }
}

public enum HopMasterOwnership: String, Codable, Equatable, Sendable {
    case appOwned = "app_owned"
    case adoptedAppOwned = "adopted_app_owned"
}

public enum HopControlMasterError: LocalizedError, Equatable, Sendable {
    case invalidJumpHost(String)
    case invalidRuntimeDirectory(String)
    case anotherAppInstance(pid: Int32)
    case foreignControlSocket(path: String)
    case staleUnownedSocket(path: String)
    case incompatibleConfiguration(endpoint: HopEndpointKey)

    public var errorDescription: String? {
        switch self {
        case .invalidJumpHost(let message), .invalidRuntimeDirectory(let message):
            message
        case .anotherAppInstance(let pid):
            "Another SSH AutoTunnel instance owns this hop connection (pid \(pid))"
        case .foreignControlSocket(let path):
            "A control socket not owned by SSH AutoTunnel already exists at \(path). It was left untouched."
        case .staleUnownedSocket(let path):
            "An unverified control socket or file exists at \(path). It may be stale, but was left untouched."
        case .incompatibleConfiguration(let endpoint):
            "Profiles using \(endpoint.destination):\(endpoint.port) have incompatible hop authentication or host-key settings"
        }
    }

    public var issue: HopConnectionIssue {
        switch self {
        case .invalidJumpHost(let message):
            HopConnectionIssue(
                code: .invalidRuntimeDirectory,
                summary: "Invalid jump host configuration",
                detail: message,
                recoverySuggestion: "Review the jump host username, hostname, and port.",
                retryable: false
            )
        case .invalidRuntimeDirectory(let message):
            HopConnectionIssue(
                code: .invalidRuntimeDirectory,
                summary: "Unsafe SSH AutoTunnel runtime directory",
                detail: message,
                recoverySuggestion: "Remove or rename the conflicting path after verifying that it is not in use.",
                retryable: false
            )
        case .anotherAppInstance(let pid):
            HopConnectionIssue(
                code: .anotherAppInstance,
                summary: "Another SSH AutoTunnel instance owns this hop",
                detail: "The ownership lock is held by app process \(pid).",
                recoverySuggestion: "Use the running app instance or close it before retrying.",
                retryable: true
            )
        case .foreignControlSocket(let path):
            HopConnectionIssue(
                code: .foreignControlSocket,
                summary: "Foreign SSH control socket conflict",
                detail: "The socket at \(path) could not be verified as SSH AutoTunnel-owned and was not modified.",
                recoverySuggestion: "Close the external master or move its ControlPath, then reconnect the hop.",
                retryable: true
            )
        case .staleUnownedSocket(let path):
            HopConnectionIssue(
                code: .staleUnownedSocket,
                summary: "Unverified SSH control path conflict",
                detail: "The path at \(path) is not backed by a verifiable SSH AutoTunnel ownership record and was not modified.",
                recoverySuggestion: "Verify that no SSH master uses this path, remove the stale path manually, and reconnect the hop.",
                retryable: true
            )
        case .incompatibleConfiguration(let endpoint):
            HopConnectionIssue(
                code: .incompatibleHopConfiguration,
                summary: "Incompatible shared-hop configuration",
                detail: "More than one profile targets \(endpoint.destination):\(endpoint.port) with different connection policies.",
                recoverySuggestion: "Make the profiles use the same authentication, Keychain references, and host-key policy.",
                retryable: false
            )
        }
    }
}

public struct HopControlPathLayout: Equatable, Sendable {
    public static let maximumUnixSocketPathBytes = 103

    public var rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func `default`() throws -> HopControlPathLayout {
        let configurationPath = try AppPaths.configurationURL().path
        let namespace = StableSSHHash.short(configurationPath, length: 10)
        return HopControlPathLayout(
            rootDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("ssh-at-\(getuid())-\(namespace)", isDirectory: true)
        )
    }

    public func paths(for endpoint: HopEndpointKey) throws -> HopControlMasterPaths {
        let directory = rootDirectory.appendingPathComponent("h-\(endpoint.stableHash)", isDirectory: true)
        let controlPath = directory.appendingPathComponent("c").path
        guard controlPath.utf8.count <= Self.maximumUnixSocketPathBytes else {
            throw HopControlMasterError.invalidRuntimeDirectory(
                "SSH control socket path is too long (\(controlPath.utf8.count) bytes): \(controlPath)"
            )
        }
        return HopControlMasterPaths(
            directory: directory,
            controlPath: controlPath,
            readyURL: directory.appendingPathComponent("ready"),
            manifestURL: directory.appendingPathComponent("owner.json"),
            lockURL: directory.appendingPathComponent("lock")
        )
    }
}

public struct HopControlMasterPaths: Equatable, Sendable {
    public var directory: URL
    public var controlPath: String
    public var readyURL: URL
    public var manifestURL: URL
    public var lockURL: URL
}

struct HopControlMasterManifest: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var endpoint: HopEndpointKey
    var signatureHash: String
    var appPID: Int32
    var sshPID: Int32
    var commandHash: String
    var socketDevice: UInt64?
    var socketInode: UInt64?
    var startedAt: Date
}

final class HopControlMasterLease {
    let fileDescriptor: Int32
    let lockURL: URL

    init(fileDescriptor: Int32, lockURL: URL) {
        self.fileDescriptor = fileDescriptor
        self.lockURL = lockURL
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

struct HopOwnershipPreparation {
    var lease: HopControlMasterLease?
    var adoptedPID: Int32?
    var ownership: HopMasterOwnership

    static let launchWithoutOwnership = HopOwnershipPreparation(lease: nil, adoptedPID: nil, ownership: .appOwned)
}

protocol HopControlMasterOwnershipManaging: AnyObject {
    func prepare(_ controlMaster: JumpHostControlMaster) throws -> HopOwnershipPreparation
    func recordLaunch(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) throws
    func recordReady(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) throws
    func cleanup(_ controlMaster: JumpHostControlMaster, sessionPID: Int32)
}

final class NoopHopControlMasterOwnershipManager: HopControlMasterOwnershipManaging {
    func prepare(_ controlMaster: JumpHostControlMaster) throws -> HopOwnershipPreparation {
        try FileManager.default.createDirectory(
            at: controlMaster.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return .launchWithoutOwnership
    }
    func recordLaunch(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) throws {}
    func recordReady(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) throws {}
    func cleanup(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) {}
}

final class FileHopControlMasterOwnershipManager: HopControlMasterOwnershipManaging {
    private let fileManager: FileManager
    private let appPID: Int32
    private let processIsRunning: (Int32) -> Bool
    private let controlCheck: (JumpHostControlMaster) -> Int32?
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileManager: FileManager = .default,
        appPID: Int32 = getpid(),
        processIsRunning: @escaping (Int32) -> Bool = InteractiveSSHSessionRegistry.defaultProcessIsRunning,
        controlCheck: @escaping (JumpHostControlMaster) -> Int32? = FileHopControlMasterOwnershipManager.defaultControlCheck,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.appPID = appPID
        self.processIsRunning = processIsRunning
        self.controlCheck = controlCheck
        self.now = now
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func prepare(_ controlMaster: JumpHostControlMaster) throws -> HopOwnershipPreparation {
        try prepareSecureDirectory(controlMaster.directory.deletingLastPathComponent())
        try prepareSecureDirectory(controlMaster.directory)
        let lease = try acquireLease(controlMaster.lockURL)
        let controlPathExists = pathExists(atPath: controlMaster.controlPath)
        let socketExists = isSocket(atPath: controlMaster.controlPath)
        let manifest = loadManifest(controlMaster.manifestURL)

        guard controlPathExists else {
            if let manifest {
                if manifestMatches(manifest, controlMaster: controlMaster), !processIsRunning(manifest.appPID) {
                    removeOwnedArtifacts(controlMaster, includingSocket: false)
                } else if processIsRunning(manifest.appPID), manifest.appPID != appPID {
                    throw HopControlMasterError.anotherAppInstance(pid: manifest.appPID)
                } else if !manifestMatches(manifest, controlMaster: controlMaster) {
                    throw HopControlMasterError.staleUnownedSocket(path: controlMaster.controlPath)
                }
            }
            return HopOwnershipPreparation(lease: lease, adoptedPID: nil, ownership: .appOwned)
        }

        guard socketExists else {
            throw HopControlMasterError.staleUnownedSocket(path: controlMaster.controlPath)
        }
        guard let manifest, manifestMatches(manifest, controlMaster: controlMaster) else {
            if let pid = controlCheck(controlMaster), processIsRunning(pid) {
                throw HopControlMasterError.foreignControlSocket(path: controlMaster.controlPath)
            }
            throw HopControlMasterError.staleUnownedSocket(path: controlMaster.controlPath)
        }
        if processIsRunning(manifest.appPID), manifest.appPID != appPID {
            throw HopControlMasterError.anotherAppInstance(pid: manifest.appPID)
        }
        guard socketIdentityMatches(manifest, path: controlMaster.controlPath) else {
            throw HopControlMasterError.staleUnownedSocket(path: controlMaster.controlPath)
        }

        if let checkedPID = controlCheck(controlMaster), checkedPID == manifest.sshPID, processIsRunning(checkedPID) {
            var adoptedManifest = manifest
            adoptedManifest.appPID = appPID
            try writeManifest(adoptedManifest, to: controlMaster.manifestURL)
            return HopOwnershipPreparation(lease: lease, adoptedPID: checkedPID, ownership: .adoptedAppOwned)
        }

        guard !processIsRunning(manifest.appPID), !processIsRunning(manifest.sshPID) else {
            throw HopControlMasterError.foreignControlSocket(path: controlMaster.controlPath)
        }
        removeOwnedArtifacts(controlMaster, includingSocket: true)
        try prepareSecureDirectory(controlMaster.directory)
        return HopOwnershipPreparation(lease: lease, adoptedPID: nil, ownership: .appOwned)
    }

    func recordLaunch(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) throws {
        let manifest = HopControlMasterManifest(
            version: HopControlMasterManifest.currentVersion,
            endpoint: controlMaster.endpoint,
            signatureHash: controlMaster.signature.stableHash,
            appPID: appPID,
            sshPID: sessionPID,
            commandHash: StableSSHHash.short(controlMaster.command.shellCommand, length: 32),
            socketDevice: nil,
            socketInode: nil,
            startedAt: now()
        )
        try writeManifest(manifest, to: controlMaster.manifestURL)
    }

    func recordReady(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) throws {
        guard var manifest = loadManifest(controlMaster.manifestURL),
              manifestMatches(manifest, controlMaster: controlMaster),
              manifest.sshPID == sessionPID else {
            throw HopControlMasterError.foreignControlSocket(path: controlMaster.controlPath)
        }
        guard let identity = socketIdentity(atPath: controlMaster.controlPath) else {
            throw HopControlMasterError.foreignControlSocket(path: controlMaster.controlPath)
        }
        manifest.socketDevice = identity.device
        manifest.socketInode = identity.inode
        manifest.appPID = appPID
        try writeManifest(manifest, to: controlMaster.manifestURL)
    }

    func cleanup(_ controlMaster: JumpHostControlMaster, sessionPID: Int32) {
        guard let manifest = loadManifest(controlMaster.manifestURL),
              manifestMatches(manifest, controlMaster: controlMaster),
              manifest.sshPID == sessionPID else {
            return
        }
        removeOwnedArtifacts(
            controlMaster,
            includingSocket: socketIdentityMatches(manifest, path: controlMaster.controlPath)
        )
    }

    private func acquireLease(_ url: URL) throws -> HopControlMasterLease {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw HopControlMasterError.invalidRuntimeDirectory("Could not open ownership lock at \(url.path): \(String(cString: strerror(errno)))")
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw HopControlMasterError.invalidRuntimeDirectory("Could not protect ownership lock at \(url.path): \(message)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let ownerPID = readLockPID(descriptor) ?? 0
            close(descriptor)
            throw HopControlMasterError.anotherAppInstance(pid: ownerPID)
        }
        _ = ftruncate(descriptor, 0)
        let value = "\(appPID)\n"
        _ = value.withCString { pointer in write(descriptor, pointer, strlen(pointer)) }
        _ = fsync(descriptor)
        return HopControlMasterLease(fileDescriptor: descriptor, lockURL: url)
    }

    private func readLockPID(_ descriptor: Int32) -> Int32? {
        _ = lseek(descriptor, 0, SEEK_SET)
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Int32(String(decoding: buffer.prefix(Int(count)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func prepareSecureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(),
                  (info.st_mode & 0o077) == 0 else {
                throw HopControlMasterError.invalidRuntimeDirectory(
                    "Runtime path must be a user-owned private directory and not a symlink: \(url.path)"
                )
            }
            return
        }
        guard errno == ENOENT else {
            throw HopControlMasterError.invalidRuntimeDirectory("Could not inspect runtime path \(url.path): \(String(cString: strerror(errno)))")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func manifestMatches(_ manifest: HopControlMasterManifest, controlMaster: JumpHostControlMaster) -> Bool {
        manifest.version == HopControlMasterManifest.currentVersion
            && manifest.endpoint == controlMaster.endpoint
            && manifest.signatureHash == controlMaster.signature.stableHash
    }

    private func loadManifest(_ url: URL) -> HopControlMasterManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(HopControlMasterManifest.self, from: data)
    }

    private func writeManifest(_ manifest: HopControlMasterManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
        try FileProtection.protectFile(url)
    }

    private func socketIdentityMatches(_ manifest: HopControlMasterManifest, path: String) -> Bool {
        guard let expectedDevice = manifest.socketDevice, let expectedInode = manifest.socketInode else { return false }
        guard let actual = socketIdentity(atPath: path) else { return false }
        return expectedDevice == actual.device && expectedInode == actual.inode
    }

    private func isSocket(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func pathExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func socketIdentity(atPath path: String) -> (device: UInt64, inode: UInt64)? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private func removeOwnedArtifacts(_ controlMaster: JumpHostControlMaster, includingSocket: Bool) {
        if includingSocket {
            try? fileManager.removeItem(atPath: controlMaster.controlPath)
        }
        try? fileManager.removeItem(at: controlMaster.readyPath)
        try? fileManager.removeItem(at: controlMaster.manifestURL)
    }

    private static func defaultControlCheck(_ controlMaster: JumpHostControlMaster) -> Int32? {
        guard let result = try? ShellRunner.run(
            "/usr/bin/ssh",
            ["-F", "none", "-S", controlMaster.controlPath, "-O", "check", controlMaster.endpoint.destination]
        ), result.exitCode == 0 else {
            return nil
        }
        let expression = try? NSRegularExpression(pattern: #"pid=(\d+)"#)
        let output = result.stdout + result.stderr
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression?.firstMatch(in: output, range: range),
              let pidRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Int32(output[pidRange])
    }
}

final class AdoptedSSHProcessSession: SSHProcessSession {
    let processIdentifier: Int32
    private let controlMaster: JumpHostControlMaster
    private let processIsRunning: (Int32) -> Bool

    init(
        pid: Int32,
        controlMaster: JumpHostControlMaster,
        processIsRunning: @escaping (Int32) -> Bool = InteractiveSSHSessionRegistry.defaultProcessIsRunning
    ) {
        processIdentifier = pid
        self.controlMaster = controlMaster
        self.processIsRunning = processIsRunning
    }

    var terminationStatus: Int32 { isRunning ? 0 : 255 }
    var isRunning: Bool { processIsRunning(processIdentifier) }
    func write(_ data: Data) {}

    func terminate() {
        _ = try? ShellRunner.run(
            "/usr/bin/ssh",
            ["-F", "none", "-S", controlMaster.controlPath, "-O", "exit", controlMaster.endpoint.destination]
        )
    }

    func forceKill() {
        guard isRunning else { return }
        _ = kill(processIdentifier, SIGKILL)
    }
}

enum StableSSHHash {
    static func short(_ value: String, length: Int = 20) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(length).description
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
