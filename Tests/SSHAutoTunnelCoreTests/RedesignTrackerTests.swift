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

    func testRedesignTrackerDocumentsDirectMainWindowEditing() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Docs/RedesignTracker.md")
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(contents.contains("Profile detail pages are directly editable"))
        XCTAssertTrue(contents.contains("Main window sidebar owns profile add, delete, reorder"))
        XCTAssertTrue(contents.contains("PAC and network rule management moved into main-window pages"))
        XCTAssertTrue(contents.contains("Settings is app-level only"))
    }

    func testRedesignTrackerDocumentsPreMergeUICleanup() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Docs/RedesignTracker.md")
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(contents.contains("Pre-merge UI cleanup split the main window"))
        XCTAssertTrue(contents.contains("Profile detail editing now uses segmented sections"))
        XCTAssertTrue(contents.contains("Settings no longer uses a single-tab wrapper"))
        XCTAssertTrue(contents.contains("Interactive SSH terminal app selection lives on the Overview page instead of"))
    }
}
