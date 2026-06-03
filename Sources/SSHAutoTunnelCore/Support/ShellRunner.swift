import Foundation

public struct ShellResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

public enum ShellRunner {
    public static func run(_ executable: String, _ arguments: [String]) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let outputGroup = DispatchGroup()
        let stdout = ShellOutputCapture()
        let stderr = ShellOutputCapture()

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.set(output.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.set(error.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        process.waitUntilExit()
        outputGroup.wait()

        return ShellResult(exitCode: process.terminationStatus, stdout: stdout.text, stderr: stderr.text)
    }
}

private final class ShellOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }
}
