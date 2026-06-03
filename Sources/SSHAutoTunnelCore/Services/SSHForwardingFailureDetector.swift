import Foundation

struct SSHForwardingFailure: Equatable, Sendable {
    var port: Int?
    var addressAlreadyInUse: Bool

    var statusDetail: String {
        let sourceHint = "check SSH config LocalForward/DynamicForward entries or another process using the port"
        if addressAlreadyInUse, let port {
            return "Local forwarding failed: port \(port) is already in use (\(sourceHint))"
        }
        if addressAlreadyInUse {
            return "Local forwarding failed: port is already in use (\(sourceHint))"
        }
        if let port {
            return "Local forwarding failed on port \(port) (\(sourceHint))"
        }
        return "Local forwarding failed (\(sourceHint))"
    }
}

enum SSHForwardingFailureDetector {
    static func detect(in transcript: String) -> SSHForwardingFailure? {
        let normalized = transcript.replacingOccurrences(of: "\r", with: "\n")
        let lowercased = normalized.lowercased()
        let hasForwardingFailure = lowercased.contains("could not request local forwarding")
            || lowercased.contains("channel_setup_fwd_listener_tcpip")

        guard hasForwardingFailure else { return nil }

        return SSHForwardingFailure(
            port: firstPort(in: normalized),
            addressAlreadyInUse: lowercased.contains("address already in use")
        )
    }

    private static func firstPort(in text: String) -> Int? {
        for pattern in [
            #"bind \[[^\]]+\]:(\d+): Address already in use"#,
            #"cannot listen to port: (\d+)"#
        ] {
            if let port = firstCapture(in: text, pattern: pattern).flatMap(Int.init) {
                return port
            }
        }
        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}
