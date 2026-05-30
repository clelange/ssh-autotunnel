import Foundation

public enum SSHPromptAction: Equatable, Sendable {
    case confirmHostKey
    case sendPassword
    case sendTOTP
}

public enum SSHPromptResponder {
    public static func nextAction(for transcript: String) -> SSHPromptAction? {
        let text = transcript.lowercased()
        let tail = String(text.suffix(1000))
        return latestPromptMatch(in: tail)?.action
    }

    private static func latestPromptMatch(in text: String) -> PromptMatch? {
        let latest = promptPatterns
            .compactMap { pattern -> PromptMatch? in
                guard let range = text.range(of: pattern.text, options: pattern.options.union(.backwards)) else { return nil }
                return PromptMatch(action: pattern.action, range: range)
            }
            .max { lhs, rhs in lhs.range.lowerBound < rhs.range.lowerBound }
        guard let latest else { return nil }

        if let microsoftRange = text.range(of: "microsoft verification code", options: .backwards),
           latest.range.lowerBound >= microsoftRange.lowerBound,
           latest.range.lowerBound < microsoftRange.upperBound {
            return PromptMatch(action: nil, range: latest.range)
        }

        return latest
    }

    private static let promptPatterns: [PromptPattern] = [
        PromptPattern("are you sure you want to continue connecting", .confirmHostKey),
        PromptPattern("password:", .sendPassword),
        PromptPattern("password for ", .sendPassword),
        PromptPattern("'s password:", .sendPassword),
        PromptPattern("microsoft verification code", nil),
        PromptPattern("one-time code:", .sendTOTP),
        PromptPattern("one time code:", .sendTOTP),
        PromptPattern("verification code", .sendTOTP),
        PromptPattern("authentication code", .sendTOTP),
        PromptPattern("passcode:", .sendTOTP),
        PromptPattern("token code:", .sendTOTP),
        PromptPattern("otp code", .sendTOTP),
        PromptPattern("enter otp", .sendTOTP),
        PromptPattern("2nd factor", .sendTOTP),
        PromptPattern("second factor", .sendTOTP),
        PromptPattern("totp", .sendTOTP),
        PromptPattern("otp:", .sendTOTP)
    ]
}

private struct PromptPattern {
    var text: String
    var action: SSHPromptAction?
    var options: String.CompareOptions

    init(_ text: String, _ action: SSHPromptAction?, options: String.CompareOptions = []) {
        self.text = text
        self.action = action
        self.options = options
    }
}

private struct PromptMatch {
    var action: SSHPromptAction?
    var range: Range<String.Index>
}
