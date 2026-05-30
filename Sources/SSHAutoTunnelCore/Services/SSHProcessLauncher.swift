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
        let argvStorage = ([command.executable] + command.arguments).map { strdup($0) }
        defer {
            if master >= 0 {
                close(master)
            }
            for pointer in argvStorage {
                free(pointer)
            }
        }
        guard argvStorage.allSatisfy({ $0 != nil }) else {
            throw Self.posixError(message: "Could not prepare SSH command arguments")
        }
        var argv = argvStorage.map { $0 }
        argv.append(nil)

        let pid = withCurrentWindowSize { windowSizePointer in
            forkpty(&master, nil, nil, windowSizePointer)
        }
        guard pid >= 0 else {
            throw Self.posixError(message: "Could not launch SSH pseudo-terminal")
        }
        if pid == 0 {
            _ = argv.withUnsafeMutableBufferPointer { buffer in
                execv(argvStorage[0], buffer.baseAddress)
            }
            _exit(127)
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        master = -1
        let session = PTYSSHProcessSession(pid: pid, master: masterHandle, onOutput: onOutput, onTermination: onTermination)
        session.startReadLoop()
        session.startWaitLoop()
        return session
    }

    private func withCurrentWindowSize<T>(_ body: (UnsafeMutablePointer<winsize>?) -> T) -> T {
        var windowSize = winsize()
        guard isatty(STDIN_FILENO) == 1,
              ioctl(STDIN_FILENO, TIOCGWINSZ, &windowSize) == 0 else {
            return body(nil)
        }
        return withUnsafeMutablePointer(to: &windowSize) { pointer in
            body(pointer)
        }
    }

    private static func posixError(message: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private final class PTYSSHProcessSession: SSHProcessSession {
    private let pid: Int32
    private let master: FileHandle
    private let onOutput: (Data) -> Void
    private let onTermination: (SSHProcessSession) -> Void
    private let stateLock = NSLock()
    private var didFinish = false
    private var status: Int32 = 1

    init(pid: Int32, master: FileHandle, onOutput: @escaping (Data) -> Void, onTermination: @escaping (SSHProcessSession) -> Void) {
        self.pid = pid
        self.master = master
        self.onOutput = onOutput
        self.onTermination = onTermination
    }

    var processIdentifier: Int32 {
        pid
    }

    var terminationStatus: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !didFinish
    }

    func write(_ data: Data) {
        master.write(data)
    }

    func terminate() {
        guard isRunning else { return }
        kill(pid, SIGTERM)
    }

    func forceKill() {
        guard isRunning else { return }
        kill(pid, SIGKILL)
    }

    func startReadLoop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while true {
                let data = self.master.availableData
                if data.isEmpty { break }
                self.onOutput(data)
            }
        }
    }

    func startWaitLoop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var waitStatus: Int32 = 0
            while waitpid(self.pid, &waitStatus, 0) < 0 {
                guard errno == EINTR else {
                    waitStatus = 1
                    break
                }
            }
            self.finish(status: Self.exitStatus(from: waitStatus))
        }
    }

    private func finish(status: Int32) {
        stateLock.lock()
        let shouldNotify = !didFinish
        didFinish = true
        self.status = status
        stateLock.unlock()

        if shouldNotify {
            onTermination(self)
        }
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        if waitStatus & 0x7f == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + (waitStatus & 0x7f)
    }
}
