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

    public static func posixPermissions(of url: URL) throws -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    public static func octalPermissions(of url: URL) throws -> String? {
        try posixPermissions(of: url).map { String(format: "%03o", $0) }
    }
}
