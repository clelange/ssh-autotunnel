import Foundation

public protocol GenericPasswordReading {
    func readGenericPassword(service: String, account: String) throws -> String
}

extension KeychainService: GenericPasswordReading {}

public enum SSHAuto2FAPresets {
    public static let cernLxplusTOTPService = "cern-lxplus-otp-secret"
    public static let psiTier3PasswordService = "psit3-password"
    public static let psiTier3TOTPService = "psit3-otp-secret"
}

public enum KeychainSecretKind: String, Codable, Equatable, Sendable {
    case password
    case totpSeed

    public var displayName: String {
        switch self {
        case .password: "Password"
        case .totpSeed: "TOTP seed"
        }
    }
}

public enum KeychainCredentialState: Codable, Equatable, Sendable {
    case available
    case missing
    case unreadable(String)
}

public struct SSHAuto2FAServiceRequirement: Codable, Identifiable, Equatable, Sendable {
    public var profileName: String
    public var kind: KeychainSecretKind
    public var service: String
    public var account: String

    public var id: String {
        "\(profileName)|\(kind.rawValue)|\(service)|\(account)"
    }

    public init(profileName: String, kind: KeychainSecretKind, service: String, account: String) {
        self.profileName = profileName
        self.kind = kind
        self.service = service
        self.account = account
    }
}

public struct SSHAuto2FAServiceStatus: Codable, Identifiable, Equatable, Sendable {
    public var requirement: SSHAuto2FAServiceRequirement
    public var state: KeychainCredentialState

    public var id: String { requirement.id }

    public init(requirement: SSHAuto2FAServiceRequirement, state: KeychainCredentialState) {
        self.requirement = requirement
        self.state = state
    }
}

public enum SSHAuto2FAKeychainInspector {
    public static func defaultRequirements(account: String = NSUserName()) -> [SSHAuto2FAServiceRequirement] {
        [
            SSHAuto2FAServiceRequirement(
                profileName: "CERN lxplus",
                kind: .totpSeed,
                service: SSHAuto2FAPresets.cernLxplusTOTPService,
                account: account
            ),
            SSHAuto2FAServiceRequirement(
                profileName: "PSI Tier-3",
                kind: .password,
                service: SSHAuto2FAPresets.psiTier3PasswordService,
                account: account
            ),
            SSHAuto2FAServiceRequirement(
                profileName: "PSI Tier-3",
                kind: .totpSeed,
                service: SSHAuto2FAPresets.psiTier3TOTPService,
                account: account
            )
        ]
    }

    public static func inspect(
        requirements: [SSHAuto2FAServiceRequirement],
        reader: GenericPasswordReading
    ) -> [SSHAuto2FAServiceStatus] {
        requirements.map { requirement in
            do {
                _ = try reader.readGenericPassword(service: requirement.service, account: requirement.account)
                return SSHAuto2FAServiceStatus(requirement: requirement, state: .available)
            } catch KeychainServiceError.itemNotFound {
                return SSHAuto2FAServiceStatus(requirement: requirement, state: .missing)
            } catch {
                return SSHAuto2FAServiceStatus(requirement: requirement, state: .unreadable(error.localizedDescription))
            }
        }
    }

    public static func inspect(account: String = NSUserName(), reader: GenericPasswordReading) -> [SSHAuto2FAServiceStatus] {
        inspect(requirements: defaultRequirements(account: account), reader: reader)
    }
}
