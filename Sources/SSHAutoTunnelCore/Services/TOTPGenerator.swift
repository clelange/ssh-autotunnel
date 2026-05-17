import CryptoKit
import Foundation

public enum TOTPError: Error, LocalizedError {
    case invalidBase32Character(Character)
    case emptySecret

    public var errorDescription: String? {
        switch self {
        case .invalidBase32Character(let character):
            "Invalid Base32 character: \(character)"
        case .emptySecret:
            "TOTP secret is empty"
        }
    }
}

public enum TOTPGenerator {
    private static let alphabet: [Character: UInt8] = {
        var result: [Character: UInt8] = [:]
        for (index, character) in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567").enumerated() {
            result[character] = UInt8(index)
        }
        return result
    }()

    public static func base32Decode(_ input: String) throws -> Data {
        let clean = input
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "=" }

        guard !clean.isEmpty else { throw TOTPError.emptySecret }

        var buffer: UInt32 = 0
        var bitsLeft = 0
        var bytes: [UInt8] = []

        for character in clean {
            guard let value = alphabet[character] else {
                throw TOTPError.invalidBase32Character(character)
            }

            buffer = (buffer << 5) | UInt32(value)
            bitsLeft += 5

            if bitsLeft >= 8 {
                bitsLeft -= 8
                bytes.append(UInt8((buffer >> UInt32(bitsLeft)) & 0xff))
            }
        }

        return Data(bytes)
    }

    public static func generate(
        secretBase32: String,
        time: Date = Date(),
        period: TimeInterval = 30,
        digits: Int = 6
    ) throws -> String {
        let secret = try base32Decode(secretBase32)
        return generate(secret: secret, counter: UInt64(time.timeIntervalSince1970 / period), digits: digits)
    }

    public static func generate(secret: Data, counter: UInt64, digits: Int = 6) -> String {
        var counterBigEndian = counter.bigEndian
        let counterData = Data(bytes: &counterBigEndian, count: MemoryLayout<UInt64>.size)
        let signature = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: SymmetricKey(data: secret))
        let hash = Array(signature)
        let offset = Int(hash[hash.count - 1] & 0x0f)
        let code = ((UInt32(hash[offset]) & 0x7f) << 24)
            | ((UInt32(hash[offset + 1]) & 0xff) << 16)
            | ((UInt32(hash[offset + 2]) & 0xff) << 8)
            | (UInt32(hash[offset + 3]) & 0xff)
        let modulo = UInt32(pow(10.0, Double(digits)))
        let value = code % modulo
        return String(format: "%0*u", digits, value)
    }
}
