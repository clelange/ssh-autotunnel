import Foundation
import XCTest

final class RedesignTrackerTests: XCTestCase {
    func testRedesignTrackerDocumentsDeferredItems() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Docs/RedesignTracker.md")
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(contents.contains("Automatic Sync Across Macs"))
        XCTAssertTrue(contents.contains("Trash/Recent-Deleted Profiles"))
        XCTAssertTrue(contents.contains("Full `ssh_config` Directive Browser"))
        XCTAssertTrue(contents.contains("Remote Port Forwarding And Reverse Dynamic Forwarding"))
        XCTAssertTrue(contents.contains("Migration/Compatibility"))
        XCTAssertTrue(contents.contains("Validation History"))
    }
}
