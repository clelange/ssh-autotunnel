import Foundation

struct SocksListener: Equatable, Sendable {
    var pid: Int32
    var processName: String
    var port: Int
    var endpoint: String
}

protocol SocksListenerInspecting {
    func listeners(onLoopbackPort port: Int) -> [SocksListener]
}

struct LsofSocksListenerInspector: SocksListenerInspecting {
    var commandRunner: (String, [String]) throws -> ShellResult = ShellRunner.run

    func listeners(onLoopbackPort port: Int) -> [SocksListener] {
        guard PortConfigurationValidator.validRange.contains(port),
              let result = try? commandRunner(
                "/usr/sbin/lsof",
                ["-nP", "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-Fpcn"]
              ),
              result.succeeded else {
            return []
        }

        var listeners: [SocksListener] = []
        var currentPID: Int32?
        var currentProcess = ""

        for line in result.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                currentPID = Int32(value)
                currentProcess = ""
            case "c":
                currentProcess = value
            case "n":
                guard let pid = currentPID, value == "127.0.0.1:\(port)" else { continue }
                listeners.append(SocksListener(pid: pid, processName: currentProcess, port: port, endpoint: value))
            default:
                continue
            }
        }

        return listeners
    }
}

struct SSHProcessMetadata: Equatable, Sendable {
    var pid: Int32
    var processGroupID: Int32
    var command: String
}

protocol SSHProcessControlling {
    func metadata(for pid: Int32) -> SSHProcessMetadata?
    func processIsRunning(_ pid: Int32) -> Bool
    @discardableResult func sendSignal(_ signal: Int32, toProcessGroup groupID: Int32) -> Bool
    @discardableResult func sendSignal(_ signal: Int32, toPID pid: Int32) -> Bool
}

struct DarwinSSHProcessController: SSHProcessControlling {
    var commandRunner: (String, [String]) throws -> ShellResult = ShellRunner.run

    func metadata(for pid: Int32) -> SSHProcessMetadata? {
        guard pid > 0,
              let result = try? commandRunner("/bin/ps", ["-o", "pid=", "-o", "pgid=", "-o", "command=", "-p", "\(pid)"]),
              result.succeeded else {
            return nil
        }

        let line = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3,
              let parsedPID = Int32(parts[0]),
              let parsedPGID = Int32(parts[1]) else {
            return nil
        }

        return SSHProcessMetadata(pid: parsedPID, processGroupID: parsedPGID, command: String(parts[2]))
    }

    func processIsRunning(_ pid: Int32) -> Bool {
        InteractiveSSHSessionRegistry.defaultProcessIsRunning(pid)
    }

    func sendSignal(_ signal: Int32, toProcessGroup groupID: Int32) -> Bool {
        guard groupID > 1 else { return false }
        if Darwin.kill(-groupID, signal) == 0 {
            return true
        }
        return errno == ESRCH
    }

    func sendSignal(_ signal: Int32, toPID pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, signal) == 0 {
            return true
        }
        return errno == ESRCH
    }
}
