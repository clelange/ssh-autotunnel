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

final class SSHTranscriptRedactor {
    private var secrets: [String]
    private var pending = ""

    init(secrets: [String] = []) {
        self.secrets = []
        secrets.forEach(addSecret)
    }

    func addSecret(_ secret: String) {
        guard !secret.isEmpty, !secrets.contains(secret) else { return }
        secrets.append(secret)
    }

    func redact(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        pending += text

        let tailCount = bufferedTailCharacterCount
        guard pending.count > tailCount else { return "" }

        let emitEnd = pending.index(pending.endIndex, offsetBy: -tailCount)
        let emit = String(pending[..<emitEnd])
        pending = String(pending[emitEnd...])
        return SSHTranscriptLog.redact(emit, secrets: secrets)
    }

    func flush() -> String {
        defer { pending = "" }
        return SSHTranscriptLog.redact(pending, secrets: secrets)
    }

    private var bufferedTailCharacterCount: Int {
        max((secrets.map(\.count).max() ?? 0) - 1, 0)
    }
}
