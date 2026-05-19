import Foundation

public enum ProfileTemplate {
    public static let exampleProfileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    public static func example() -> TunnelProfile {
        TunnelProfile(
            id: exampleProfileID,
            name: "Example tunnel",
            host: "ssh.example.org",
            user: "alice",
            sshPort: 22,
            localSocksPort: 1083,
            jumpHost: "bastion.example.org",
            authMode: .passwordAndTOTP,
            hostKeyPolicy: .acceptNew,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "example-password",
                totpService: "example-totp-seed"
            ),
            autoReconnect: true,
            healthProbe: HealthProbe(host: "ssh.example.org", port: 22),
            extraSSHOptions: ["-o", "IdentitiesOnly=yes"]
        )
    }
}

public enum PACRuleTemplate {
    public static func example(profileID: UUID = ProfileTemplate.exampleProfileID) -> PACRule {
        PACRule(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            name: "Example routing",
            domainPattern: "*.example.org",
            profileID: profileID,
            enabled: true,
            failureMode: .failClosed
        )
    }
}
