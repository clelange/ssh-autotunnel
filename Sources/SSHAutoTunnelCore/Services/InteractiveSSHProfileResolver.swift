import Foundation

public enum InteractiveSSHProfileResolver {
    public static func resolve(profile: TunnelProfile, in configuration: AppConfiguration) -> TunnelProfile {
        if profile.resolvedInteractiveHost != profile.host {
            var interactiveProfile = profile
            interactiveProfile.host = profile.resolvedInteractiveHost
            return interactiveProfile
        }

        guard let account = configuration.accounts.first(where: { account in
            guard account.tunnelEnabled, account.tunnelHost == profile.host else { return false }
            return AccountSetupService.preset(for: account.id)?.profileName == profile.name
        }),
              let interactiveHost = account.interactiveHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !interactiveHost.isEmpty else {
            return profile
        }

        var interactiveProfile = profile
        interactiveProfile.host = interactiveHost
        interactiveProfile.jumpHost = account.jumpHost
        return interactiveProfile
    }
}

public enum InteractiveSSHJumpHostPolicy {
    public static func requiresPersistentJumpHostSession(_ profile: TunnelProfile) -> Bool {
        guard let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines), !jumpHost.isEmpty else {
            return false
        }
        return jumpHost.localizedCaseInsensitiveContains("t3hop")
            || jumpHost.localizedCaseInsensitiveContains("hopx.psi.ch")
    }
}
