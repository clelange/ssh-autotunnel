import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class TOTPGeneratorTests: XCTestCase {
    func testRFC6238SHA1Vectors() throws {
        let secret = Data("12345678901234567890".utf8)
        XCTAssertEqual(TOTPGenerator.generate(secret: secret, counter: 59 / 30, digits: 8), "94287082")
        XCTAssertEqual(TOTPGenerator.generate(secret: secret, counter: 1_111_111_109 / 30, digits: 8), "07081804")
        XCTAssertEqual(TOTPGenerator.generate(secret: secret, counter: 1_111_111_111 / 30, digits: 8), "14050471")
        XCTAssertEqual(TOTPGenerator.generate(secret: secret, counter: 1_234_567_890 / 30, digits: 8), "89005924")
    }

    func testBase32Decode() throws {
        let decoded = try TOTPGenerator.base32Decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(String(data: decoded, encoding: .utf8), "12345678901234567890")
    }
}
