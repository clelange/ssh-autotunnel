import Foundation

public enum ProfileTemplate {
    public static func example() -> TunnelProfile {
        TunnelProfile(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
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
