import Foundation

public enum SSHConnectionFailureDisposition: Equatable, Sendable {
    case retryable
    case terminal
}

public enum SSHConnectionFailureClassifier {
    private static let terminalPatterns = [
        "permission denied",
        "authentication failed",
        "too many authentication failures",
        "host key verification failed",
        "remote host identification has changed",
        "no matching host key type found",
        "no matching key exchange method found"
    ]

    public static func disposition(
        transcript: String,
        reachedHealthyState: Bool
    ) -> SSHConnectionFailureDisposition {
        guard !reachedHealthyState else { return .retryable }
        let normalized = transcript
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return terminalPatterns.contains(where: normalized.contains) ? .terminal : .retryable
    }
}
