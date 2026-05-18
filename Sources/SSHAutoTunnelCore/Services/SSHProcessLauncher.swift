import Darwin
import Foundation

protocol SSHProcessSession: AnyObject {
    var processIdentifier: Int32 { get }
    var terminationStatus: Int32 { get }
    var isRunning: Bool { get }

    func write(_ data: Data)
    func terminate()
    func forceKill()
}

protocol SSHProcessLaunching {
    func launch(
        command: SSHCommand,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession
}

final class PTYSSHProcessLauncher: SSHProcessLaunching {
    func launch(
        command: SSHCommand,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not allocate pseudo-terminal"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        process.standardOutput = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        process.standardError = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        close(slave)

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let session = PTYSSHProcessSession(process: process, master: masterHandle, onOutput: onOutput, onTermination: onTermination)
        process.terminationHandler = { [weak session] _ in
            session?.notifyTermination()
        }

        do {
            try process.run()
        } catch {
            close(master)
            throw error
        }
        session.startReadLoop()
        return session
    }
}

private final class PTYSSHProcessSession: SSHProcessSession {
    private let process: Process
    private let master: FileHandle
    private let onOutput: (Data) -> Void
    private let onTermination: (SSHProcessSession) -> Void

    init(process: Process, master: FileHandle, onOutput: @escaping (Data) -> Void, onTermination: @escaping (SSHProcessSession) -> Void) {
        self.process = process
        self.master = master
        self.onOutput = onOutput
        self.onTermination = onTermination
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    var isRunning: Bool {
        process.isRunning
    }

    func write(_ data: Data) {
        master.write(data)
    }

    func terminate() {
        process.terminate()
    }

    func forceKill() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func startReadLoop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.process.isRunning {
                let data = self.master.availableData
                if data.isEmpty { break }
                self.onOutput(data)
            }
        }
    }

    func notifyTermination() {
        onTermination(self)
    }
}
