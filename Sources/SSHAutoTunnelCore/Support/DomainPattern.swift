import Foundation

public enum DomainPattern {
    public static func matches(host: String, pattern: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !normalizedHost.isEmpty, !normalizedPattern.isEmpty else { return false }

        if normalizedPattern == "*" { return true }
        if normalizedPattern.hasPrefix("*.") {
            let suffix = String(normalizedPattern.dropFirst(1))
            return normalizedHost.hasSuffix(suffix) && normalizedHost.count > suffix.count
        }
        if normalizedPattern.contains("*") {
            let regex = "^" + NSRegularExpression.escapedPattern(for: normalizedPattern)
                .replacingOccurrences(of: "\\*", with: ".*") + "$"
            return normalizedHost.range(of: regex, options: .regularExpression) != nil
        }
        return normalizedHost == normalizedPattern
    }

    public static func pacExpression(for pattern: String) -> String {
        "shExpMatch(host, \(JavaScriptStringLiteral.encode(pattern)))"
    }
}

enum JavaScriptStringLiteral {
    static func encode(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           var encoded = String(data: data, encoding: .utf8) {
            encoded = encoded
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            return encoded
        }
        return "\"\""
    }
}
