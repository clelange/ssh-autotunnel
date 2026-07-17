import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class SSHConfigAuditServiceTests: XCTestCase {
    func testPSIConfigFindsConditionalSafeReplacementAndCanonicalHostNameRecommendation() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileProtection.protectDirectory(configDirectory)
        try write("Include \"config.d/*.conf\"\n", to: sshDirectory.appendingPathComponent("config"))
        let psiURL = configDirectory.appendingPathComponent("psi.conf")
        try write("""
        Host hopx hopx.psi.ch psi-main-gateway
          HostName hopx.psi.ch
          User alice

        Host hepserver hepserver.psi.ch
          User alice

        Host gitea.psi.ch
          ProxyJump none

        Match host "*.psi.ch" !exec "nc -z %h %p"
          ProxyJump psi-main-gateway # keep fallback condition
        """ + "\n", to: psiURL)
        let profile = appProfile()
        try installManagedIntegration(in: sshDirectory, configuration: AppConfiguration(profiles: [profile]))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [profile])
        )

        let replacement = try XCTUnwrap(report.safeReplacements.first)
        XCTAssertEqual(replacement.location.path, psiURL.path)
        XCTAssertEqual(replacement.location.line, 12)
        XCTAssertEqual(replacement.context, "Match host *.psi.ch !exec nc -z %h %p")
        XCTAssertEqual(replacement.beforeText, "  ProxyJump psi-main-gateway # keep fallback condition")
        XCTAssertEqual(
            replacement.afterText,
            "  ProxyJump ssh-autotunnel-hop-psi-general # keep fallback condition"
        )
        XCTAssertTrue(replacement.canApply)
        XCTAssertTrue(replacement.reasoning.contains("Match exec result remains conditional"))

        let hostName = try XCTUnwrap(report.manualRecommendations.first { $0.code == .missingCanonicalHostName })
        XCTAssertEqual(hostName.location.line, 5)
        XCTAssertTrue(hostName.afterText?.contains("HostName hepserver.psi.ch") == true)
        XCTAssertFalse(hostName.canApply)
        XCTAssertTrue(report.information.contains { $0.code == .intentionalDirectRoute })
        XCTAssertTrue(report.information.contains { $0.code == .dynamicMatch })
    }

    func testRecursiveIncludesGlobsQuotedPathsAndCyclesPreserveSourceLocations() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        let nestedDirectory = configDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileProtection.protectDirectory(nestedDirectory)
        try write("Include config.d/*.conf\n", to: sshDirectory.appendingPathComponent("config"))
        try write("""
        Host gateway
          HostName hopx.psi.ch
          User alice
        Include "config.d/nested/with space.conf"
        """ + "\n", to: configDirectory.appendingPathComponent("a.conf"))
        try write("""
        Host gateway
          HostName unrelated.example.net
          User other
        Include config.d/cycle.conf
        """ + "\n", to: configDirectory.appendingPathComponent("b.conf"))
        try write("Include config.d/b.conf\n", to: configDirectory.appendingPathComponent("cycle.conf"))
        let nestedURL = nestedDirectory.appendingPathComponent("with space.conf")
        try write("""
        Match host "*.psi.ch"
          ProxyJump gateway
        """ + "\n", to: nestedURL)

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )

        XCTAssertEqual(report.safeReplacements.count, 1)
        XCTAssertEqual(report.safeReplacements.first?.location.path, nestedURL.path)
        XCTAssertEqual(report.safeReplacements.first?.location.line, 2)
        XCTAssertTrue(report.files.contains { $0.path == nestedURL.path })
        XCTAssertTrue(report.warnings.contains { $0.code == .includeCycle })
    }

    func testEquivalentProxyJumpRequiresCurrentManagedIncludeBeforeApplication() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configURL = sshDirectory.appendingPathComponent("config")
        try write("""
        Host gateway
          HostName hopx.psi.ch
          User alice

        Host internal-one
          ProxyJump gateway

        Match originalhost internal-two
          ProxyJump alice@hopx.psi.ch:22
        """ + "\n", to: configURL)

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )

        XCTAssertEqual(report.safeReplacements.count, 2)
        XCTAssertEqual(Set(report.safeReplacements.map(\.context)), Set(["Host internal-one", "Match originalhost internal-two"]))
        XCTAssertTrue(report.safeReplacements.allSatisfy { !$0.canApply })
        XCTAssertEqual(report.managedIntegration.status, .notInstalled)
        XCTAssertTrue(report.safeReplacements.allSatisfy {
            $0.reasoning.contains("Install or update the managed OpenSSH include")
        })
    }

    func testDirectMultiHopProxyCommandWildcardAndUnrelatedRoutesRemainInformation() throws {
        let sshDirectory = try temporarySSHDirectory()
        try write("""
        Host public.example.net
          ProxyJump none
        Host chain.internal
          ProxyJump first,second
        Host command.internal
          ProxyCommand ssh relay -W %h:%p
        Host *.psi.ch
          User alice
        Host unrelated.internal
          ProxyJump other-bastion
        """ + "\n", to: sshDirectory.appendingPathComponent("config"))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )

        XCTAssertTrue(report.safeReplacements.isEmpty)
        XCTAssertTrue(report.manualRecommendations.isEmpty)
        XCTAssertTrue(report.information.contains { $0.code == .intentionalDirectRoute })
        XCTAssertTrue(report.information.contains { $0.code == .multiHopUntouched })
        XCTAssertTrue(report.information.contains { $0.code == .proxyCommandUntouched })
        XCTAssertTrue(report.information.contains { $0.code == .wildcardScope })
        XCTAssertTrue(report.information.contains { $0.code == .unrelatedProxyJump })
    }

    func testNearMatchingHopWithoutConfiguredUserRequiresManualReview() throws {
        let sshDirectory = try temporarySSHDirectory()
        try write("""
        Host psi-main-gateway
          HostName hopx.psi.ch

        Match host *.psi.ch
          ProxyJump psi-main-gateway
        """ + "\n", to: sshDirectory.appendingPathComponent("config"))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )

        XCTAssertTrue(report.safeReplacements.isEmpty)
        let recommendation = try XCTUnwrap(
            report.manualRecommendations.first { $0.code == .similarProxyJumpEndpoint }
        )
        let adapterHost = HopAdapterNameResolver.adapterHostBase(profileName: appProfile().name)
        XCTAssertTrue(recommendation.reasoning.contains("no explicit username"))
        XCTAssertTrue(recommendation.afterText?.contains(adapterHost) == true)
        XCTAssertFalse(recommendation.canApply)
    }

    func testCanonicalHostNameRecommendationSkipsMixedLiteralAndWildcardScope() throws {
        let sshDirectory = try temporarySSHDirectory()
        try write("""
        Host cdct01 cdct01.psi.ch coldbox*
          User pi
        """ + "\n", to: sshDirectory.appendingPathComponent("config"))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )

        XCTAssertFalse(report.manualRecommendations.contains { $0.code == .missingCanonicalHostName })
        XCTAssertTrue(report.information.contains { $0.code == .wildcardScope })
    }

    func testConfiguredLiteralDestinationWithoutRouteIsManualOnly() throws {
        let sshDirectory = try temporarySSHDirectory()
        try write("""
        Host login.psi.ch
          User alice
        """ + "\n", to: sshDirectory.appendingPathComponent("config"))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )

        let recommendation = try XCTUnwrap(
            report.manualRecommendations.first { $0.code == .configuredDestinationMissingRoute }
        )
        XCTAssertTrue(recommendation.afterText?.hasPrefix("ProxyJump ssh-autotunnel-hop-") == true)
        XCTAssertFalse(recommendation.canApply)
    }

    func testExternalAndSymlinkIncludesAreAuditOnly() throws {
        let sshDirectory = try temporarySSHDirectory()
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-external-\(UUID().uuidString).conf")
        let linkURL = sshDirectory.appendingPathComponent("linked.conf")
        addTeardownBlock { try? FileManager.default.removeItem(at: externalURL) }
        try write("""
        Host external-gateway
          HostName hopx.psi.ch
          User alice
        Host external-destination
          ProxyJump external-gateway
        """ + "\n", to: externalURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalURL)
        try write("Include \(externalURL.path) linked.conf\n", to: sshDirectory.appendingPathComponent("config"))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )

        XCTAssertEqual(report.safeReplacements.count, 2)
        XCTAssertTrue(report.safeReplacements.allSatisfy { !$0.canApply })
        XCTAssertTrue(report.warnings.contains { $0.code == .unsafeMetadata && $0.path == externalURL.path })
        XCTAssertTrue(report.warnings.contains { $0.code == .unsafeMetadata && $0.path == linkURL.path })
    }

    func testMultipleProfilesSharingEndpointProduceOneAuditEndpoint() throws {
        var second = appProfile()
        second.id = UUID()
        second.name = "Second"
        second.host = "other.psi.ch"
        second.localSocksPort = 1183
        let sshDirectory = try temporarySSHDirectory()
        try write("", to: sshDirectory.appendingPathComponent("config"))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile(), second])
        )

        XCTAssertEqual(report.endpoints.count, 1)
        XCTAssertEqual(report.endpoints[0].preferredAdapterHost, "ssh-autotunnel-hop-psi-general")
        XCTAssertEqual(Set(report.endpoints[0].profileNames), ["PSI General", "Second"])
    }

    func testLegacyHashAdapterCanMigrateToReadableAliasWhenManagedIncludeIsCurrent() throws {
        let sshDirectory = try temporarySSHDirectory()
        let profile = appProfile()
        let endpoint = try HopEndpointKey(profile: profile)
        let configuration = AppConfiguration(profiles: [profile])
        try write("Host internal\n  ProxyJump \(endpoint.adapterHost)\n", to: sshDirectory.appendingPathComponent("config"))
        try installManagedIntegration(in: sshDirectory, configuration: configuration)

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(configuration: configuration)

        let replacement = try XCTUnwrap(report.safeReplacements.first { $0.code == .legacyManagedAdapter })
        XCTAssertEqual(replacement.afterText, "  ProxyJump ssh-autotunnel-hop-psi-general")
        XCTAssertTrue(replacement.canApply)
        XCTAssertEqual(report.managedIntegration.status, .current)
    }

    func testAuditReportsManagedIncludeUpdateAndReadableAliasConflicts() throws {
        let updateDirectory = try temporarySSHDirectory()
        let updateConfigDirectory = updateDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileProtection.protectDirectory(updateConfigDirectory)
        try write(
            "Include config.d/ssh-autotunnel.conf\n",
            to: updateDirectory.appendingPathComponent("config")
        )
        try write(
            "# SSH AutoTunnel managed SSH config v2\n",
            to: updateDirectory.appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath)
        )

        let updateReport = SSHConfigAuditService(sshDirectory: updateDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )
        XCTAssertEqual(updateReport.managedIntegration.status, .updateRequired)

        let conflictDirectory = try temporarySSHDirectory()
        let conflictURL = conflictDirectory.appendingPathComponent("config")
        try write(
            "Host ssh-autotunnel-hop-psi-general\n  HostName other.example.org\n",
            to: conflictURL
        )

        let conflictReport = SSHConfigAuditService(sshDirectory: conflictDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )
        XCTAssertEqual(conflictReport.managedIntegration.status, .conflict)
        XCTAssertTrue(conflictReport.managedIntegration.detail.contains("\(conflictURL.path):1"))
    }

    func testHistoricalReadableAliasMigratesAfterProfileRenameAndManagedUpdate() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileProtection.protectDirectory(configDirectory)
        let rootURL = sshDirectory.appendingPathComponent("config")
        try write(
            "Host internal\n  ProxyJump ssh-autotunnel-hop-old-name\nInclude config.d/ssh-autotunnel.conf\n",
            to: rootURL
        )
        var oldProfile = appProfile()
        oldProfile.name = "Old Name"
        let managedURL = sshDirectory.appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath)
        try write(
            try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [oldProfile])),
            to: managedURL
        )
        var renamedProfile = oldProfile
        renamedProfile.name = "New Name"
        let configuration = AppConfiguration(profiles: [renamedProfile])

        let staleReport = SSHConfigAuditService(sshDirectory: sshDirectory).check(configuration: configuration)
        XCTAssertEqual(staleReport.managedIntegration.status, .updateRequired)
        XCTAssertFalse(try XCTUnwrap(staleReport.safeReplacements.first).canApply)

        _ = try SSHConfigSetupService.installManagedConfig(
            for: configuration,
            sshDirectory: sshDirectory,
            now: Date(timeIntervalSince1970: 0)
        )
        let currentReport = SSHConfigAuditService(sshDirectory: sshDirectory).check(configuration: configuration)
        let replacement = try XCTUnwrap(currentReport.safeReplacements.first { $0.code == .legacyManagedAdapter })
        XCTAssertEqual(replacement.afterText, "  ProxyJump ssh-autotunnel-hop-new-name")
        XCTAssertTrue(replacement.canApply)
    }

    func testTextRendererIncludesStructuredFindingAndWarningDetails() throws {
        let sshDirectory = try temporarySSHDirectory()
        try write("""
        Include missing/*.conf
        Host login.psi.ch
          User alice
        """ + "\n", to: sshDirectory.appendingPathComponent("config"))

        let report = SSHConfigAuditService(sshDirectory: sshDirectory).check(
            configuration: AppConfiguration(profiles: [appProfile()])
        )
        let text = SSHConfigAuditTextRenderer.render(report)

        XCTAssertTrue(text.contains("SSH config audit:"))
        XCTAssertTrue(text.contains("Manual review:"))
        XCTAssertTrue(text.contains("Warnings:"))
        XCTAssertTrue(text.contains(sshDirectory.path))
    }

    func testLegacyAuditEndpointJSONDecodesWithAdditiveDefaults() throws {
        let data = Data(#"{"endpoint":{"user":"alice","host":"hopx.psi.ch","port":22},"adapterHost":"ssh-autotunnel-hop-legacyhash"}"#.utf8)

        let endpoint = try JSONDecoder().decode(SSHConfigAuditEndpoint.self, from: data)

        XCTAssertEqual(endpoint.preferredAdapterHost, "ssh-autotunnel-hop-legacyhash")
        XCTAssertEqual(endpoint.adapterHosts, ["ssh-autotunnel-hop-legacyhash"])
        XCTAssertEqual(endpoint.profileNames, [])
    }

    private func appProfile() -> TunnelProfile {
        TunnelProfile(
            name: "PSI General",
            host: "login.psi.ch",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch",
            authMode: .passwordAndTOTP,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "password-service",
                totpService: "totp-service"
            )
        )
    }

    private func temporarySSHDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileProtection.protectFile(url)
    }

    private func installManagedIntegration(
        in sshDirectory: URL,
        configuration: AppConfiguration
    ) throws {
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileProtection.protectDirectory(configDirectory)
        let managedURL = sshDirectory.appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath)
        try write(try SSHConfigSetupService.managedSnippet(for: configuration), to: managedURL)
        let rootURL = sshDirectory.appendingPathComponent("config")
        var root = (try? String(contentsOf: rootURL, encoding: .utf8)) ?? ""
        if !root.hasSuffix("\n") && !root.isEmpty { root.append("\n") }
        root.append("Include config.d/ssh-autotunnel.conf\n")
        try write(root, to: rootURL)
    }
}
