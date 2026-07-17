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
        terminalFileDescriptor: Int32?,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession
}

final class PTYSSHProcessLauncher: SSHProcessLaunching {
    func launch(
        command: SSHCommand,
        terminalFileDescriptor: Int32?,
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

        let pid = withWindowSize(from: terminalFileDescriptor) { windowSizePointer in
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
        if let terminalFileDescriptor {
            session.startWindowResizeMonitoring(from: terminalFileDescriptor)
        }
        session.startReadLoop()
        session.startWaitLoop()
        return session
    }

    private func withWindowSize<T>(
        from fileDescriptor: Int32?,
        _ body: (UnsafeMutablePointer<winsize>?) -> T
    ) -> T {
        guard let fileDescriptor,
              var windowSize = TerminalWindowSize.read(from: fileDescriptor)?.systemValue else {
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

struct TerminalWindowSize: Equatable, Sendable {
    var rows: UInt16
    var columns: UInt16
    var xPixels: UInt16
    var yPixels: UInt16

    init(rows: UInt16, columns: UInt16, xPixels: UInt16 = 0, yPixels: UInt16 = 0) {
        self.rows = rows
        self.columns = columns
        self.xPixels = xPixels
        self.yPixels = yPixels
    }

    init(systemValue: winsize) {
        self.init(
            rows: systemValue.ws_row,
            columns: systemValue.ws_col,
            xPixels: systemValue.ws_xpixel,
            yPixels: systemValue.ws_ypixel
        )
    }

    var systemValue: winsize {
        var value = winsize()
        value.ws_row = rows
        value.ws_col = columns
        value.ws_xpixel = xPixels
        value.ws_ypixel = yPixels
        return value
    }

    static func read(from fileDescriptor: Int32) -> TerminalWindowSize? {
        guard isatty(fileDescriptor) == 1 else { return nil }
        var value = winsize()
        guard ioctl(fileDescriptor, TIOCGWINSZ, &value) == 0,
              value.ws_row > 0,
              value.ws_col > 0 else {
            return nil
        }
        return TerminalWindowSize(systemValue: value)
    }
}

final class TerminalWindowResizeMonitor {
    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let onResize: (TerminalWindowSize) -> Void
    private let stateLock = NSLock()
    private var signalSource: DispatchSourceSignal?
    private var previousSignalHandler: sig_t?
    private var isStarted = false

    init(
        fileDescriptor: Int32,
        queue: DispatchQueue = DispatchQueue(label: "dev.clange.ssh-autotunnel.terminal-resize"),
        onResize: @escaping (TerminalWindowSize) -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.queue = queue
        self.onResize = onResize
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard TerminalWindowSize.read(from: fileDescriptor) != nil else { return false }

        stateLock.lock()
        guard !isStarted else {
            stateLock.unlock()
            return true
        }

        previousSignalHandler = Darwin.signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
        source.setEventHandler { [weak self] in
            self?.deliverCurrentSize()
        }
        signalSource = source
        isStarted = true
        stateLock.unlock()

        source.resume()
        deliverCurrentSize()
        return true
    }

    func stop() {
        stateLock.lock()
        guard isStarted else {
            stateLock.unlock()
            return
        }
        let source = signalSource
        let previousSignalHandler = previousSignalHandler
        signalSource = nil
        self.previousSignalHandler = nil
        isStarted = false
        stateLock.unlock()

        source?.cancel()
        _ = Darwin.signal(SIGWINCH, previousSignalHandler)
    }

    private func deliverCurrentSize() {
        guard let windowSize = TerminalWindowSize.read(from: fileDescriptor) else { return }
        stateLock.lock()
        guard isStarted else {
            stateLock.unlock()
            return
        }
        onResize(windowSize)
        stateLock.unlock()
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
    private var windowResizeMonitor: TerminalWindowResizeMonitor?

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
        signalProcessGroup(SIGTERM)
    }

    func forceKill() {
        guard isRunning else { return }
        signalProcessGroup(SIGKILL)
    }

    func startWindowResizeMonitoring(from fileDescriptor: Int32) {
        let monitor = TerminalWindowResizeMonitor(fileDescriptor: fileDescriptor) { [weak self] windowSize in
            self?.applyWindowSize(windowSize)
        }
        guard monitor.start() else { return }
        windowResizeMonitor = monitor
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
            windowResizeMonitor?.stop()
            windowResizeMonitor = nil
            onTermination(self)
        }
    }

    private func applyWindowSize(_ windowSize: TerminalWindowSize) {
        guard isRunning else { return }
        var value = windowSize.systemValue
        guard ioctl(master.fileDescriptor, TIOCSWINSZ, &value) == 0 else { return }
        signalProcessGroup(SIGWINCH)
    }

    private func signalProcessGroup(_ signal: Int32) {
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        if waitStatus & 0x7f == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + (waitStatus & 0x7f)
    }
}
