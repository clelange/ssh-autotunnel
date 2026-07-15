import XCTest
@testable import SSHAutoTunnelCore

final class SSHConnectionAttemptLedgerTests: XCTestCase {
    func testAutomaticAttemptLimitUsesRollingEndpointWindow() throws {
        let ledger = SSHConnectionAttemptLedger(limit: 3, window: 600)
        let endpoint = SSHConnectionEndpoint(host: "SSH.EXAMPLE.ORG", port: 22)
        let start = Date(timeIntervalSince1970: 1_000)

        ledger.recordUserInitiatedAttempt(to: endpoint, at: start)
        ledger.recordUserInitiatedAttempt(to: endpoint, at: start.addingTimeInterval(1))
        XCTAssertNotNil(ledger.reserveAutomaticAttempt(to: endpoint, at: start.addingTimeInterval(2)))
        XCTAssertNil(ledger.reserveAutomaticAttempt(to: endpoint, at: start.addingTimeInterval(3)))

        XCTAssertNotNil(ledger.reserveAutomaticAttempt(to: endpoint, at: start.addingTimeInterval(601)))
    }

    func testCancelledReservationDoesNotConsumeBudget() throws {
        let ledger = SSHConnectionAttemptLedger(limit: 1, window: 600)
        let endpoint = SSHConnectionEndpoint(host: "ssh.example.org", port: 22)
        let reservation = try XCTUnwrap(ledger.reserveAutomaticAttempt(to: endpoint))

        ledger.cancel(reservation)

        XCTAssertNotNil(ledger.reserveAutomaticAttempt(to: endpoint))
    }
}
