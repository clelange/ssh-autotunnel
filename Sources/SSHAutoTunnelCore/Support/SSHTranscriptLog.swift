import Foundation

enum SSHTranscriptLog {
    static func event(kind: String, message: String, at date: Date = Date()) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date)
        return "\n[\(timestamp)] [\(kind)] \(message)\n"
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        var redacted = text
        for secret in secrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return redacted
    }
}
