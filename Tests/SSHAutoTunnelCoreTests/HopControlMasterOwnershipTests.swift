import Darwin
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class HopControlMasterOwnershipTests: XCTestCase {
    func testStableEndpointPathsAreSharedAcrossCompatibleProfiles() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let first = try JumpHostControlMasterFactory.make(for: profile(name: "First"), layout: layout)
        let second = try JumpHostControlMasterFactory.make(for: profile(name: "Second"), layout: layout)

        XCTAssertEqual(first.endpoint, second.endpoint)
        XCTAssertEqual(first.signature, second.signature)
        XCTAssertEqual(first.controlPath, second.controlPath)
        XCTAssertEqual(first.endpoint.adapterHost, second.endpoint.adapterHost)
        XCTAssertLessThanOrEqual(first.controlPath.utf8.count, HopControlPathLayout.maximumUnixSocketPathBytes)
    }

    func testStableEndpointPathsSupportNonPSIHopServers() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let generic = try JumpHostControlMasterFactory.make(
            for: profile(name: "Generic", jumpHost: "admin@bastion.example.net", port: 2201),
            layout: layout
        )
        let psi = try JumpHostControlMasterFactory.make(for: profile(name: "PSI"), layout: layout)

        XCTAssertEqual(generic.endpoint, HopEndpointKey(user: "admin", host: "bastion.example.net", port: 2201))
        XCTAssertNotEqual(generic.controlPath, psi.controlPath)
        XCTAssertTrue(generic.endpoint.adapterHost.hasPrefix("ssh-autotunnel-hop-"))
    }

    func testVerifiedMasterFromExitedAppIsAdopted() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let master = try JumpHostControlMasterFactory.make(for: profile(name: "Adopt"), layout: layout)
        let oldManager = FileHopControlMasterOwnershipManager(
            appPID: 101,
            processIsRunning: { $0 == 202 },
            controlCheck: { _ in 202 }
        )
        var oldPreparation: HopOwnershipPreparation? = try oldManager.prepare(master)
        try oldManager.recordLaunch(master, sessionPID: 202)
        let socket = try UnixTestSocket(path: master.controlPath)
        try oldManager.recordReady(master, sessionPID: 202)
        oldPreparation = nil
        XCTAssertNil(oldPreparation)

        let newManager = FileHopControlMasterOwnershipManager(
            appPID: 303,
            processIsRunning: { $0 == 202 },
            controlCheck: { _ in 202 }
        )
        var adopted: HopOwnershipPreparation? = try newManager.prepare(master)

        XCTAssertEqual(adopted?.adoptedPID, 202)
        XCTAssertEqual(adopted?.ownership, .adoptedAppOwned)
        let manifest = try JSONDecoder().decode(
            HopControlMasterManifest.self,
            from: Data(contentsOf: master.manifestURL)
        )
        XCTAssertEqual(manifest.appPID, 303)
        XCTAssertEqual(manifest.sshPID, 202)

        adopted = nil
        newManager.cleanup(master, sessionPID: 202)
        socket.closeWithoutUnlinking()
    }

    func testConcurrentAppInstanceCannotAcquireEndpointLease() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let master = try JumpHostControlMasterFactory.make(for: profile(name: "Concurrent"), layout: layout)
        let firstManager = FileHopControlMasterOwnershipManager(appPID: 111, processIsRunning: { _ in false }, controlCheck: { _ in nil })
        let secondManager = FileHopControlMasterOwnershipManager(appPID: 222, processIsRunning: { _ in false }, controlCheck: { _ in nil })
        var firstPreparation: HopOwnershipPreparation? = try firstManager.prepare(master)

        XCTAssertThrowsError(try secondManager.prepare(master)) { error in
            XCTAssertEqual(error as? HopControlMasterError, .anotherAppInstance(pid: 111))
        }

        firstPreparation = nil
        XCTAssertNil(firstPreparation)
    }

    func testUnverifiedStaleControlPathIsReportedAndLeftUntouched() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let master = try JumpHostControlMasterFactory.make(for: profile(name: "Stale"), layout: layout)
        let manager = FileHopControlMasterOwnershipManager(appPID: 111, processIsRunning: { _ in false }, controlCheck: { _ in nil })
        var preparation: HopOwnershipPreparation? = try manager.prepare(master)
        XCTAssertNotNil(preparation)
        preparation = nil
        XCTAssertTrue(FileManager.default.createFile(atPath: master.controlPath, contents: Data("foreign".utf8)))

        XCTAssertThrowsError(try manager.prepare(master)) { error in
            XCTAssertEqual(error as? HopControlMasterError, .staleUnownedSocket(path: master.controlPath))
        }
        XCTAssertEqual(try String(contentsOfFile: master.controlPath, encoding: .utf8), "foreign")
    }

    func testLiveForeignSocketIsReportedAndNeverRemoved() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let master = try JumpHostControlMasterFactory.make(for: profile(name: "Foreign"), layout: layout)
        let directoryManager = FileHopControlMasterOwnershipManager(appPID: 111, processIsRunning: { _ in false }, controlCheck: { _ in nil })
        var preparation: HopOwnershipPreparation? = try directoryManager.prepare(master)
        XCTAssertNotNil(preparation)
        preparation = nil
        let socket = try UnixTestSocket(path: master.controlPath)
        defer { socket.closeAndUnlink() }
        let manager = FileHopControlMasterOwnershipManager(
            appPID: 222,
            processIsRunning: { $0 == 444 },
            controlCheck: { _ in 444 }
        )

        XCTAssertThrowsError(try manager.prepare(master)) { error in
            XCTAssertEqual(error as? HopControlMasterError, .foreignControlSocket(path: master.controlPath))
        }
        XCTAssertTrue(isUnixSocket(master.controlPath))
    }

    func testVerifiedStaleAppSocketCanBeRemovedForRelaunch() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let master = try JumpHostControlMasterFactory.make(for: profile(name: "Verified stale"), layout: layout)
        let oldManager = FileHopControlMasterOwnershipManager(appPID: 101, processIsRunning: { _ in false }, controlCheck: { _ in nil })
        var oldPreparation: HopOwnershipPreparation? = try oldManager.prepare(master)
        XCTAssertNotNil(oldPreparation)
        try oldManager.recordLaunch(master, sessionPID: 202)
        let socket = try UnixTestSocket(path: master.controlPath)
        try oldManager.recordReady(master, sessionPID: 202)
        oldPreparation = nil

        let newManager = FileHopControlMasterOwnershipManager(appPID: 303, processIsRunning: { _ in false }, controlCheck: { _ in nil })
        let preparation = try newManager.prepare(master)

        XCTAssertNil(preparation.adoptedPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: master.controlPath))
        socket.closeWithoutUnlinking()
    }

    func testCleanupDoesNotRemoveSocketThatReplacedOwnedIdentity() throws {
        let layout = temporaryLayout()
        defer { try? FileManager.default.removeItem(at: layout.rootDirectory) }
        let master = try JumpHostControlMasterFactory.make(for: profile(name: "Replacement"), layout: layout)
        let manager = FileHopControlMasterOwnershipManager(appPID: 101, processIsRunning: { _ in false }, controlCheck: { _ in nil })
        var preparation: HopOwnershipPreparation? = try manager.prepare(master)
        try manager.recordLaunch(master, sessionPID: 202)
        let ownedSocket = try UnixTestSocket(path: master.controlPath)
        try manager.recordReady(master, sessionPID: 202)
        ownedSocket.closeAndUnlink()
        let replacementSocket = try UnixTestSocket(path: master.controlPath)
        defer { replacementSocket.closeAndUnlink() }

        manager.cleanup(master, sessionPID: 202)

        XCTAssertTrue(isUnixSocket(master.controlPath))
        preparation = nil
        XCTAssertNil(preparation)
    }

    private func profile(
        name: String,
        jumpHost: String = "alice@hopx.psi.ch",
        port: Int = 22
    ) -> TunnelProfile {
        TunnelProfile(
            name: name,
            host: "destination.example.net",
            user: "alice",
            sshPort: port,
            localSocksPort: 1080,
            jumpHost: jumpHost,
            authMode: .passwordAndTOTP,
            hostKeyPolicy: .strict,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "password-service",
                totpService: "totp-service"
            )
        )
    }

    private func temporaryLayout() -> HopControlPathLayout {
        HopControlPathLayout(
            rootDirectory: URL(fileURLWithPath: "/tmp/ssh-at-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        )
    }
}

private final class UnixTestSocket {
    private var descriptor: Int32
    private let path: String

    init(path: String) throws {
        self.path = path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < pathCapacity else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                _ = strlcpy($0, path, pathCapacity)
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            throw POSIXError(code)
        }
    }

    func closeAndUnlink() {
        closeWithoutUnlinking()
        unlink(path)
    }

    func closeWithoutUnlinking() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit {
        closeWithoutUnlinking()
    }
}

private func isUnixSocket(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
}
