import XCTest
@testable import SSHAutoTunnelCore

final class SSHNetworkLaunchPolicyTests: XCTestCase {
    func testOnlySatisfiedPathPermitsSSHLaunch() {
        XCTAssertFalse(SSHNetworkLaunchPolicy.permitsLaunch(for: .unknown))
        XCTAssertFalse(SSHNetworkLaunchPolicy.permitsLaunch(for: .unsatisfied))
        XCTAssertFalse(SSHNetworkLaunchPolicy.permitsLaunch(for: .requiresConnection))
        XCTAssertTrue(SSHNetworkLaunchPolicy.permitsLaunch(for: .satisfied))
    }

    func testNetworkPathStabilizesForFiveSeconds() {
        XCTAssertEqual(SSHNetworkLaunchPolicy.stabilizationInterval, 5)
    }
}
