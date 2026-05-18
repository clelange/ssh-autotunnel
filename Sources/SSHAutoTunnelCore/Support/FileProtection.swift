import Foundation

public enum FileProtection {
    public static let privateDirectoryPermissions = 0o700
    public static let privateFilePermissions = 0o600

    public static func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: privateDirectoryPermissions)],
            ofItemAtPath: url.path
        )
    }

    public static func protectFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: privateFilePermissions)],
            ofItemAtPath: url.path
        )
    }
}
