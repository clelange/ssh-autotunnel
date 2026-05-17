import XCTest
@testable import SSHAutoTunnelCore

final class DomainPatternTests: XCTestCase {
    func testWildcardSubdomain() {
        XCTAssertTrue(DomainPattern.matches(host: "service.cern.ch", pattern: "*.cern.ch"))
        XCTAssertFalse(DomainPattern.matches(host: "cern.ch", pattern: "*.cern.ch"))
        XCTAssertFalse(DomainPattern.matches(host: "example.org", pattern: "*.cern.ch"))
    }

    func testExactMatch() {
        XCTAssertTrue(DomainPattern.matches(host: "lxplus.cern.ch", pattern: "lxplus.cern.ch"))
        XCTAssertFalse(DomainPattern.matches(host: "foo.lxplus.cern.ch", pattern: "lxplus.cern.ch"))
    }
}
