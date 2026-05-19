import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class PACAppendSourceLoaderTests: XCTestCase {
    func testLoadsLocalPACFile() async throws {
        let (directory, url, pac) = try makePACFile()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let loaded = try await PACAppendSourceLoader.load(
            PACAppendSource(enabled: true, kind: .file, location: url.path)
        )

        XCTAssertEqual(loaded, pac)
    }

    func testLoadsFileURLPACSource() async throws {
        let (directory, url, pac) = try makePACFile()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let loaded = try await PACAppendSourceLoader.load(
            PACAppendSource(enabled: true, kind: .url, location: url.absoluteString)
        )

        XCTAssertEqual(loaded, pac)
    }

    private func makePACFile() throws -> (URL, URL, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("existing.pac")
        let pac = "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
        try pac.write(to: url, atomically: true, encoding: .utf8)
        return (directory, url, pac)
    }

    func testRejectsMissingLocation() async {
        do {
            _ = try await PACAppendSourceLoader.load(PACAppendSource(enabled: true, kind: .url, location: " "))
            XCTFail("Expected load to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, PACAppendSourceLoadError.missingLocation.localizedDescription)
        }
    }

    func testRejectsUnsupportedURLScheme() async {
        do {
            _ = try await PACAppendSourceLoader.load(PACAppendSource(enabled: true, kind: .url, location: "ftp://example.test/proxy.pac"))
            XCTFail("Expected load to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, PACAppendSourceLoadError.unsupportedURLScheme("ftp").localizedDescription)
        }
    }
}
