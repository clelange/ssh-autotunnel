import Foundation

public enum SSHPromptAction: Equatable, Sendable {
    case confirmHostKey
    case sendPassword
    case sendTOTP
}

public enum SSHPromptResponder {
    public static func nextAction(for transcript: String) -> SSHPromptAction? {
        let text = transcript.lowercased()

        if text.contains("are you sure you want to continue connecting") {
            return .confirmHostKey
        }

        if containsRecentPasswordPrompt(text) {
            return .sendPassword
        }

        if containsRecentTOTPPrompt(text) {
            return .sendTOTP
        }

        return nil
    }

    private static func containsRecentPasswordPrompt(_ text: String) -> Bool {
        let tail = text.suffix(500)
        return tail.contains("password:")
            || tail.contains("password for ")
            || tail.contains("'s password:")
    }

    private static func containsRecentTOTPPrompt(_ text: String) -> Bool {
        let tail = text.suffix(500)
        return tail.contains("one-time code:")
            || tail.contains("one time code:")
            || tail.contains("verification code")
            || tail.contains("2nd factor")
            || tail.contains("second factor")
            || tail.contains("totp")
            || tail.contains("otp:")
    }
}
