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
            interactiveHost: "login.example.org",
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
            tags: ["example"],
            connectOnLaunch: false,
            notificationPolicy: .failuresAndRecoveries,
            sshLogLevel: .info,
            tunnelRequestsRemoteSession: false,
            localPortForwardings: [
                LocalPortForward(
                    localPort: 15432,
                    targetHost: "database.internal.example.org",
                    targetPort: 5432
                )
            ],
            curatedSSHOptions: CuratedSSHOptions(
                identityFiles: ["~/.ssh/id_example"],
                forwardAgent: .disabled,
                maxReconnectAttempts: nil
            ),
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
            failureMode: .directFallback
        )
    }
}

public enum NetworkRuleTemplate {
    public static func example(profileID: UUID? = nil) -> NetworkPolicyRule {
        NetworkPolicyRule(
            id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            name: "Example direct network",
            match: NetworkMatch(searchDomainSuffix: "example.org"),
            action: .directAccess,
            profileID: profileID
        )
    }
}
