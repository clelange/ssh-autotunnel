import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class AppConfigurationCodableTests: XCTestCase {
    func testDecodesLegacyConfigurationWithoutBlockingProxyPort() throws {
        let json = Data("""
        {
          "profiles": [],
          "pacRules": [],
          "networkRules": [],
          "pacHTTPPort": 18483,
          "apiHTTPPort": 18484,
          "apiToken": "token",
          "proxyApplyMode": "manual"
        }
        """.utf8)

        let config = try JSONDecoder().decode(AppConfiguration.self, from: json)

        XCTAssertEqual(config.accounts, [])
        XCTAssertEqual(config.blockingHTTPProxyPort, 18485)
        XCTAssertEqual(config.apiToken, "token")
        XCTAssertEqual(config.interactiveTerminal, InteractiveTerminalPreference())
    }

    func testEncodesBlockingProxyPort() throws {
        let config = AppConfiguration(blockingHTTPProxyPort: 19000)
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["blockingHTTPProxyPort"] as? Int, 19000)
    }

    func testDecodesLegacyConfigurationWithoutPACAppendSource() throws {
        let json = Data("""
        {
          "profiles": [],
          "pacRules": [],
          "networkRules": [],
          "pacHTTPPort": 18483,
          "blockingHTTPProxyPort": 18485,
          "apiHTTPPort": 18484,
          "apiToken": "token",
          "proxyApplyMode": "manual"
        }
        """.utf8)

        let config = try JSONDecoder().decode(AppConfiguration.self, from: json)

        XCTAssertEqual(config.pacAppendSource, PACAppendSource())
    }

    func testEncodesPACAppendSource() throws {
        let config = AppConfiguration(
            pacAppendSource: PACAppendSource(
                enabled: true,
                kind: .file,
                location: "/tmp/existing.pac"
            )
        )
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let appendSource = try XCTUnwrap(object["pacAppendSource"] as? [String: Any])

        XCTAssertEqual(appendSource["enabled"] as? Bool, true)
        XCTAssertEqual(appendSource["kind"] as? String, "file")
        XCTAssertEqual(appendSource["location"] as? String, "/tmp/existing.pac")
    }

    func testEncodesInteractiveTerminalPreference() throws {
        let config = AppConfiguration(
            interactiveTerminal: InteractiveTerminalPreference(
                app: .ghostty,
                customApplicationPath: "/Applications/Ghostty.app"
            )
        )
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let terminal = try XCTUnwrap(object["interactiveTerminal"] as? [String: Any])

        XCTAssertEqual(terminal["app"] as? String, "ghostty")
        XCTAssertEqual(terminal["customApplicationPath"] as? String, "/Applications/Ghostty.app")
    }

    func testEncodesAccounts() throws {
        let account = AccountConfiguration(
            id: .cernLxPlus,
            displayName: "CERN LxPlus",
            username: "clange",
            credentialHost: "lxplus.cern.ch",
            interactiveHost: "lxplus.cern.ch",
            tunnelEnabled: true,
            tunnelHost: "lxtunnel.cern.ch",
            localSocksPort: 1081,
            pacDomainPattern: "*.cern.ch",
            keychain: KeychainReference(account: "clange", passwordService: "cern-lxplus-password")
        )
        let config = AppConfiguration(accounts: [account])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.accounts, [account])
    }

    func testProfileOrderSurvivesEncodeDecode() throws {
        let first = TunnelProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "First",
            host: "first.example.org",
            localSocksPort: 1200
        )
        let second = TunnelProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Second",
            host: "second.example.org",
            localSocksPort: 1201
        )
        let config = AppConfiguration(profiles: [second, first])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertEqual(decoded.profiles.map(\.id), [second.id, first.id])
    }

    func testDecodesLegacyProfileWithoutHostKeyPolicy() throws {
        let json = Data("""
        {
          "name": "Legacy",
          "host": "ssh.example.org",
          "localSocksPort": 1080
        }
        """.utf8)

        let profile = try JSONDecoder().decode(TunnelProfile.self, from: json)

        XCTAssertEqual(profile.name, "Legacy")
        XCTAssertEqual(profile.sshPort, 22)
        XCTAssertEqual(profile.hostKeyPolicy, .acceptNew)
        XCTAssertNil(profile.interactiveHost)
        XCTAssertEqual(profile.tags, [])
        XCTAssertFalse(profile.connectOnLaunch)
        XCTAssertEqual(profile.notificationPolicy, .failuresAndRecoveries)
        XCTAssertEqual(profile.sshLogLevel, .info)
        XCTAssertFalse(profile.tunnelRequestsRemoteSession)
        XCTAssertEqual(profile.localPortForwardings, [])
        XCTAssertEqual(profile.curatedSSHOptions, CuratedSSHOptions())
    }

    func testEncodesProfileInteractiveHostAndHostKeyPolicy() throws {
        let profile = TunnelProfile(
            name: "Strict",
            host: "ssh.example.org",
            localSocksPort: 1080,
            interactiveHost: "login.example.org",
            hostKeyPolicy: .strict
        )
        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["hostKeyPolicy"] as? String, "strict")
        XCTAssertEqual(object["interactiveHost"] as? String, "login.example.org")
    }

    func testProfileRedesignFieldsRoundTrip() throws {
        let profile = TunnelProfile(
            name: "Redesign",
            host: "ssh.example.org",
            localSocksPort: 1080,
            tags: ["infrastructure", "production"],
            connectOnLaunch: true,
            notificationPolicy: .allStatusChanges,
            sshLogLevel: .debug1,
            tunnelRequestsRemoteSession: true,
            localPortForwardings: [
                LocalPortForward(bindAddress: "127.0.0.1", localPort: 10201, targetHost: "10.0.0.5", targetPort: 22)
            ],
            curatedSSHOptions: CuratedSSHOptions(
                bindAddress: "192.0.2.10",
                addressFamily: .ipv4,
                compression: .enabled,
                identityFiles: ["~/.ssh/id_ed25519"],
                certificateFiles: ["~/.ssh/id_ed25519-cert.pub"],
                forwardAgent: .disabled,
                proxyCommand: "ssh bastion -W %h:%p",
                maxReconnectAttempts: 3
            )
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.localPortForwardings[0].sshArgument, "127.0.0.1:10201:10.0.0.5:22")
    }

    func testProfileResolvedInteractiveHostFallsBackToTunnelHost() {
        let profile = TunnelProfile(
            name: "Default interactive",
            host: "ssh.example.org",
            localSocksPort: 1080,
            interactiveHost: " "
        )

        XCTAssertEqual(profile.resolvedInteractiveHost, "ssh.example.org")
    }

    func testDefaultConfigurationStartsWithoutAccountProfiles() throws {
        let config = AppConfiguration.defaultConfiguration()

        XCTAssertTrue(config.accounts.isEmpty)
        XCTAssertTrue(config.profiles.isEmpty)
        XCTAssertTrue(config.pacRules.isEmpty)
        XCTAssertEqual(config.proxyApplyMode, .manual)
    }
}
