import XCTest
@testable import SSHAutoTunnelCore

final class ShellRunnerTests: XCTestCase {
    func testRunDrainsStdoutAndStderrWhileProcessRuns() throws {
        let script = """
        i=0
        while [ "$i" -lt 5000 ]; do
          printf 'stdout line %05d abcdefghijklmnopqrstuvwxyz\\n' "$i"
          printf 'stderr line %05d abcdefghijklmnopqrstuvwxyz\\n' "$i" >&2
          i=$((i + 1))
        done
        """

        let result = try ShellRunner.run("/bin/sh", ["-c", script])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("stdout line 04999"))
        XCTAssertTrue(result.stderr.contains("stderr line 04999"))
    }
}
