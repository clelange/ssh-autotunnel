import CryptoKit
import Darwin
import Foundation

public enum SSHConfigSafeFixError: LocalizedError, Equatable, Sendable {
    case findingNotFound(String)
    case findingNotSafe(String)
    case unsafeFile(String)
    case fileChanged(String)
    case invalidReplacement(String)
    case backupFailed(String)
    case writeFailed(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .findingNotFound(let id): "The selected SSH config finding no longer exists: \(id)"
        case .findingNotSafe(let id): "The selected finding is not an applicable safe replacement: \(id)"
        case .unsafeFile(let path): "SSH config is not a safe regular user-owned file under ~/.ssh: \(path)"
        case .fileChanged(let path): "SSH config changed after the audit. No changes were applied; rerun Check SSH Config: \(path)"
        case .invalidReplacement(let detail): "The proposed SSH config replacement is no longer valid: \(detail)"
        case .backupFailed(let detail): "Could not create a private SSH config backup: \(detail)"
        case .writeFailed(let detail): "Could not apply SSH config replacements; already-written files were restored: \(detail)"
        case .rollbackFailed(let detail): "Applying SSH config failed and automatic rollback was incomplete: \(detail)"
        }
    }
}

public struct SSHConfigFileFixPreview: Codable, Equatable, Sendable {
    public var path: String
    public var beforeText: String
    public var afterText: String
    public var unifiedDiff: String

    public init(path: String, beforeText: String, afterText: String, unifiedDiff: String) {
        self.path = path
        self.beforeText = beforeText
        self.afterText = afterText
        self.unifiedDiff = unifiedDiff
    }
}

public struct SSHConfigSafeFixResult: Codable, Equatable, Sendable {
    public var changedFiles: [String]
    public var backupPaths: [String]
    public var appliedFindingIDs: [String]

    public init(changedFiles: [String], backupPaths: [String], appliedFindingIDs: [String]) {
        self.changedFiles = changedFiles
        self.backupPaths = backupPaths
        self.appliedFindingIDs = appliedFindingIDs
    }
}

public struct SSHConfigSafeFixService {
    public typealias AtomicWriter = (Data, URL, UInt16, UInt32, UInt32) throws -> Void

    public var sshDirectory: URL
    public var now: () -> Date
    private let atomicWriter: AtomicWriter

    public init(
        sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true),
        now: @escaping () -> Date = Date.init
    ) {
        self.init(sshDirectory: sshDirectory, now: now, atomicWriter: Self.writeAtomically)
    }

    init(
        sshDirectory: URL,
        now: @escaping () -> Date = Date.init,
        atomicWriter: @escaping AtomicWriter
    ) {
        self.sshDirectory = sshDirectory.standardizedFileURL
        self.now = now
        self.atomicWriter = atomicWriter
    }

    public func preview(
        report: SSHConfigAuditReport,
        findingIDs: Set<String>
    ) throws -> [SSHConfigFileFixPreview] {
        try prepareChanges(report: report, findingIDs: findingIDs).map { change in
            let before = String(decoding: change.originalData, as: UTF8.self)
            let after = String(decoding: change.updatedData, as: UTF8.self)
            return SSHConfigFileFixPreview(
                path: change.snapshot.path,
                beforeText: before,
                afterText: after,
                unifiedDiff: completeDiff(path: change.snapshot.path, before: before, after: after)
            )
        }
    }

    public func apply(
        report: SSHConfigAuditReport,
        findingIDs: Set<String>
    ) throws -> SSHConfigSafeFixResult {
        let changes = try prepareChanges(report: report, findingIDs: findingIDs)
        guard !changes.isEmpty else {
            return SSHConfigSafeFixResult(changedFiles: [], backupPaths: [], appliedFindingIDs: [])
        }

        let fileManager = FileManager.default
        var backups: [String: URL] = [:]
        do {
            for change in changes {
                let source = URL(fileURLWithPath: change.snapshot.path)
                let backup = availableBackupURL(for: source, fileManager: fileManager)
                try fileManager.copyItem(at: source, to: backup)
                try FileProtection.protectFile(backup)
                backups[change.snapshot.path] = backup
            }
        } catch {
            throw SSHConfigSafeFixError.backupFailed(error.localizedDescription)
        }

        var written: [PreparedChange] = []
        do {
            for change in changes {
                try atomicWriter(
                    change.updatedData,
                    URL(fileURLWithPath: change.snapshot.path),
                    change.snapshot.permissions,
                    change.snapshot.ownerUID,
                    change.snapshot.groupGID
                )
                written.append(change)
            }
        } catch {
            do {
                for change in written.reversed() {
                    try atomicWriter(
                        change.originalData,
                        URL(fileURLWithPath: change.snapshot.path),
                        change.snapshot.permissions,
                        change.snapshot.ownerUID,
                        change.snapshot.groupGID
                    )
                }
            } catch let rollbackError {
                throw SSHConfigSafeFixError.rollbackFailed(
                    "write error: \(error.localizedDescription); rollback error: \(rollbackError.localizedDescription)"
                )
            }
            throw SSHConfigSafeFixError.writeFailed(error.localizedDescription)
        }

        return SSHConfigSafeFixResult(
            changedFiles: changes.map { $0.snapshot.path },
            backupPaths: changes.compactMap { backups[$0.snapshot.path]?.path },
            appliedFindingIDs: findingIDs.sorted()
        )
    }

    private func prepareChanges(
        report: SSHConfigAuditReport,
        findingIDs: Set<String>
    ) throws -> [PreparedChange] {
        let findingsByID = Dictionary(uniqueKeysWithValues: report.findings.map { ($0.id, $0) })
        let snapshotsByPath = Dictionary(uniqueKeysWithValues: report.files.map { ($0.path, $0) })
        var selected: [SSHConfigAuditFinding] = []
        for id in findingIDs.sorted() {
            guard let finding = findingsByID[id] else { throw SSHConfigSafeFixError.findingNotFound(id) }
            guard finding.category == .safeReplacement, finding.canApply, finding.afterText != nil else {
                throw SSHConfigSafeFixError.findingNotSafe(id)
            }
            selected.append(finding)
        }

        let grouped = Dictionary(grouping: selected, by: { $0.location.path })
        return try grouped.keys.sorted().map { path in
            guard let snapshot = snapshotsByPath[path] else { throw SSHConfigSafeFixError.fileChanged(path) }
            let data = try verifiedData(snapshot: snapshot)
            guard var text = String(data: data, encoding: .utf8) else {
                throw SSHConfigSafeFixError.invalidReplacement("\(path) is no longer valid UTF-8")
            }
            var lines = text.components(separatedBy: "\n")
            let changes = grouped[path]!.sorted { $0.location.line > $1.location.line }
            var changedLines: Set<Int> = []
            for finding in changes {
                let index = finding.location.line - 1
                guard lines.indices.contains(index), lines[index] == finding.beforeText else {
                    throw SSHConfigSafeFixError.fileChanged(path)
                }
                guard changedLines.insert(index).inserted,
                      let replacement = finding.afterText,
                      !replacement.contains("\n") else {
                    throw SSHConfigSafeFixError.invalidReplacement("conflicting edit at \(path):\(finding.location.line)")
                }
                lines[index] = replacement
            }
            text = lines.joined(separator: "\n")
            return PreparedChange(snapshot: snapshot, originalData: data, updatedData: Data(text.utf8))
        }
    }

    private func verifiedData(snapshot: SSHConfigFileSnapshot) throws -> Data {
        let path = snapshot.path
        let standardizedSSHDirectory = sshDirectory.standardizedFileURL.path
        guard path.hasPrefix(standardizedSSHDirectory + "/") else {
            throw SSHConfigSafeFixError.unsafeFile(path)
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o022) == 0 else {
            throw SSHConfigSafeFixError.unsafeFile(path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SSHConfigSafeFixError.fileChanged(path)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == snapshot.contentHash,
              UInt64(metadata.st_dev) == snapshot.device,
              UInt64(metadata.st_ino) == snapshot.inode,
              metadata.st_uid == snapshot.ownerUID,
              metadata.st_gid == snapshot.groupGID,
              UInt16(metadata.st_mode & 0o7777) == snapshot.permissions,
              UInt64(metadata.st_size) == snapshot.size,
              Int64(metadata.st_mtimespec.tv_sec) == snapshot.modifiedSeconds,
              Int64(metadata.st_mtimespec.tv_nsec) == snapshot.modifiedNanoseconds else {
            throw SSHConfigSafeFixError.fileChanged(path)
        }
        return data
    }

    private func availableBackupURL(for source: URL, fileManager: FileManager) -> URL {
        let timestamp = Self.timestamp(now())
        let base = "\(source.lastPathComponent).ssh-autotunnel-audit-backup-\(timestamp)"
        var suffix = 1
        var result = source.deletingLastPathComponent().appendingPathComponent("\(base).bak")
        while fileManager.fileExists(atPath: result.path) {
            suffix += 1
            result = source.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix).bak")
        }
        return result
    }

    private func completeDiff(path: String, before: String, after: String) -> String {
        let beforeLines = before.components(separatedBy: "\n")
        let afterLines = after.components(separatedBy: "\n")
        var lines = [
            "--- \(path)",
            "+++ \(path)",
            "@@ -1,\(beforeLines.count) +1,\(afterLines.count) @@"
        ]
        lines += beforeLines.map { "-\($0)" }
        lines += afterLines.map { "+\($0)" }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func writeAtomically(
        data: Data,
        destination: URL,
        permissions: UInt16,
        ownerUID: UInt32,
        groupGID: UInt32
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).ssh-autotunnel-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink { unlink(temporary.path) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        guard fchown(descriptor, uid_t(ownerUID), gid_t(groupGID)) == 0,
              fchmod(descriptor, mode_t(permissions)) == 0,
              fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldUnlink = false
        let directoryDescriptor = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }
}

private struct PreparedChange {
    var snapshot: SSHConfigFileSnapshot
    var originalData: Data
    var updatedData: Data
}
