import Foundation
import SSHAutoTunnelCore

@MainActor
struct AppControlRequestDispatcher {
    let appState: AppState

    func response(for request: ControlRequest) -> ControlResponse {
        let profile = appState.resolveProfile(id: request.profileID, name: request.profileName)
        switch request.action {
        case .connect:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot()) }
            appState.connect(profile)
            return ControlResponse(ok: true, message: "Connecting \(profile.name)", status: appState.snapshot())
        case .disconnect:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot()) }
            appState.disconnect(profile)
            return ControlResponse(ok: true, message: "Disconnecting \(profile.name)", status: appState.snapshot())
        case .reconnect:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot()) }
            appState.reconnect(profile)
            return ControlResponse(ok: true, message: "Reconnecting \(profile.name)", status: appState.snapshot())
        case .connectHop:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot()) }
            guard appState.hasJumpHost(profile) else { return ControlResponse(ok: false, message: "Profile has no jump host", status: appState.snapshot()) }
            appState.connectHop(profile)
            return ControlResponse(ok: true, message: "Connecting hop for \(profile.name)", status: appState.snapshot())
        case .disconnectHop:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot()) }
            guard appState.hasJumpHost(profile) else { return ControlResponse(ok: false, message: "Profile has no jump host", status: appState.snapshot()) }
            appState.disconnectHop(profile)
            return ControlResponse(ok: true, message: "Disconnecting hop for \(profile.name); terminal sessions sharing this master may close", status: appState.snapshot())
        case .reconnectHop:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot()) }
            guard appState.hasJumpHost(profile) else { return ControlResponse(ok: false, message: "Profile has no jump host", status: appState.snapshot()) }
            appState.reconnectHop(profile)
            return ControlResponse(ok: true, message: "Reconnecting hop for \(profile.name); terminal sessions sharing this master may close", status: appState.snapshot())
        case .reloadPAC:
            appState.refreshPACAppendSource(force: true)
            appState.writePACCopy()
            return ControlResponse(ok: true, message: "PAC reloaded", status: appState.snapshot())
        case .pacURL:
            return ControlResponse(ok: true, message: appState.pacURL, status: appState.snapshot())
        case .status:
            return ControlResponse(ok: true, message: "OK", status: appState.snapshot())
        case .applySystemPAC:
            let ok = appState.applySystemPAC()
            return ControlResponse(ok: ok, message: appState.lastProxyMessage, status: appState.snapshot())
        case .restoreSystemPAC:
            let ok = appState.restoreSystemPAC()
            return ControlResponse(ok: ok, message: appState.lastProxyMessage, status: appState.snapshot())
        case .importSSHAuto2FA:
            let result = appState.importSSHAuto2FAPresets()
            return ControlResponse(
                ok: true,
                message: "Imported ssh-auto2fa presets: \(result.createdProfiles) created, \(result.updatedProfiles) updated, \(result.createdPACRules) PAC rules added",
                status: appState.snapshot()
            )
        case .checkSSHAuto2FA:
            appState.refreshSSHAuto2FAServiceStatuses()
            return ControlResponse(
                ok: true,
                message: "Checked \(appState.sshAuto2FAServiceStatuses.count) ssh-auto2fa Keychain services",
                status: appState.snapshot(),
                sshAuto2FAServiceStatuses: appState.sshAuto2FAServiceStatuses
            )
        case .importSSHConfig:
            do {
                let result = try appState.importSSHConfig()
                return ControlResponse(
                    ok: true,
                    message: "Imported SSH config: \(result.createdProfiles) created, \(result.updatedProfiles) updated, \(result.skippedHosts) skipped",
                    status: appState.snapshot()
                )
            } catch {
                return ControlResponse(ok: false, message: "Could not import SSH config: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .checkSSHConfig:
            let report = appState.checkSSHConfig()
            return ControlResponse(
                ok: true,
                message: "SSH config audit: \(report.safeReplacements.count) safe replacements, \(report.manualRecommendations.count) manual recommendations, \(report.warnings.count) warnings",
                sshConfigAudit: report
            )
        case .createProfile:
            guard let requestProfile = request.profile else {
                return ControlResponse(ok: false, message: ProfileConfigurationEditorError.missingProfilePayload.localizedDescription, status: appState.snapshot())
            }
            do {
                let updated = try ProfileConfigurationEditor.create(profile: requestProfile, in: appState.configuration)
                appState.configuration = updated
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Created profile \(requestProfile.name)", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create profile: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .updateProfile:
            guard let requestProfile = request.profile else {
                return ControlResponse(ok: false, message: ProfileConfigurationEditorError.missingProfilePayload.localizedDescription, status: appState.snapshot())
            }
            do {
                let updated = try ProfileConfigurationEditor.update(
                    profile: requestProfile,
                    matchingID: request.profileID,
                    matchingName: request.profileName,
                    in: appState.configuration
                )
                appState.configuration = updated
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Updated profile \(requestProfile.name)", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not update profile: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .deleteProfile:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot()) }
            do {
                let result = try appState.performProfileDeletion(
                    ids: [profile.id],
                    deleteKeychainItems: request.deleteKeychainItems == true
                )
                let message = appState.profileDeletionMessage(profileName: profile.name, result: result)
                return ControlResponse(
                    ok: result.keychainCleanupError == nil,
                    message: message,
                    status: appState.snapshot()
                )
            } catch {
                return ControlResponse(ok: false, message: "Could not delete profile: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .createPACRule:
            guard let requestRule = request.pacRule else {
                return ControlResponse(ok: false, message: PACRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: appState.snapshot())
            }
            do {
                appState.configuration = try PACRuleConfigurationEditor.create(rule: requestRule, in: appState.configuration)
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Created PAC rule \(requestRule.name)", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create PAC rule: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .updatePACRule:
            guard let requestRule = request.pacRule else {
                return ControlResponse(ok: false, message: PACRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: appState.snapshot())
            }
            do {
                appState.configuration = try PACRuleConfigurationEditor.update(
                    rule: requestRule,
                    matchingID: request.pacRuleID,
                    matchingName: request.pacRuleName,
                    in: appState.configuration
                )
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Updated PAC rule \(requestRule.name)", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not update PAC rule: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .deletePACRule:
            do {
                appState.configuration = try PACRuleConfigurationEditor.delete(
                    ruleID: request.pacRuleID,
                    ruleName: request.pacRuleName,
                    in: appState.configuration
                )
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Deleted PAC rule", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not delete PAC rule: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .createNetworkRule:
            guard let requestRule = request.networkRule else {
                return ControlResponse(ok: false, message: NetworkRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: appState.snapshot())
            }
            do {
                appState.configuration = try NetworkRuleConfigurationEditor.create(rule: requestRule, in: appState.configuration)
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Created network rule \(requestRule.name)", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create network rule: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .updateNetworkRule:
            guard let requestRule = request.networkRule else {
                return ControlResponse(ok: false, message: NetworkRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: appState.snapshot())
            }
            do {
                appState.configuration = try NetworkRuleConfigurationEditor.update(
                    rule: requestRule,
                    matchingID: request.networkRuleID,
                    matchingName: request.networkRuleName,
                    in: appState.configuration
                )
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Updated network rule \(requestRule.name)", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not update network rule: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .deleteNetworkRule:
            do {
                appState.configuration = try NetworkRuleConfigurationEditor.delete(
                    ruleID: request.networkRuleID,
                    ruleName: request.networkRuleName,
                    in: appState.configuration
                )
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Deleted network rule", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not delete network rule: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .createNetworkRuleFromCurrentNetwork:
            appState.refreshNetworkDecision()
            guard var rule = NetworkPolicyRule.disableProxyRule(from: appState.currentNetworkFingerprint) else {
                return ControlResponse(ok: false, message: "Current network does not expose enough fingerprint data for a rule", status: appState.snapshot())
            }
            if request.profileID != nil || request.profileName != nil {
                guard let profile else {
                    return ControlResponse(ok: false, message: "Profile not found", status: appState.snapshot())
                }
                rule.profileID = profile.id
            }
            do {
                appState.configuration = try NetworkRuleConfigurationEditor.create(rule: rule, in: appState.configuration)
                appState.saveConfiguration()
                return ControlResponse(ok: true, message: "Created network rule \(rule.name)", status: appState.snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create network rule: \(error.localizedDescription)", status: appState.snapshot())
            }
        case .diagnostics:
            return ControlResponse(
                ok: true,
                message: "Diagnostics",
                status: appState.snapshot(),
                diagnostics: appState.diagnosticsSnapshot()
            )
        case .exportConfiguration:
            return ControlResponse(
                ok: true,
                message: "Configuration export",
                status: appState.snapshot(),
                configurationExport: appState.configurationExport()
            )
        case .importConfiguration:
            guard let export = request.configurationExport else {
                return ControlResponse(ok: false, message: "A configuration export payload is required.", status: appState.snapshot())
            }
            return appState.importConfigurationExport(export)
        case .validateConfigurationExport:
            guard let export = request.configurationExport else {
                return ControlResponse(ok: false, message: "A configuration export payload is required.", status: appState.snapshot())
            }
            let report = appState.configurationValidationReport(for: export)
            return ControlResponse(
                ok: report.ok,
                message: report.message,
                status: appState.snapshot(),
                configurationValidation: report
            )
        case .supportBundle:
            let bundle = appState.supportBundle()
            return ControlResponse(
                ok: true,
                message: "Support bundle",
                status: appState.snapshot(),
                supportBundle: bundle
            )
        }
    }
}
