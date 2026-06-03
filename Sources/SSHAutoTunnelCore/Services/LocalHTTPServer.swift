import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public var routePath: String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int = 200, reason: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func text(_ text: String, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(headers: ["Content-Type": contentType], body: Data(text.utf8))
    }

    public static func json<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) -> HTTPResponse {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func error(_ statusCode: Int, _ reason: String, _ message: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, reason: reason, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }

    fileprivate func serialized() -> Data {
        var headerLines = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(key): \(value)")
        }
        headerLines.append("")
        headerLines.append("")
        var data = Data(headerLines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }
}

public struct LocalHTTPServerLimits: Equatable, Sendable {
    public var maxHeaderBytes: Int
    public var maxBodyBytes: Int

    public static let standard = LocalHTTPServerLimits(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1024 * 1024)

    public init(maxHeaderBytes: Int, maxBodyBytes: Int) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }
}

public enum LocalHTTPServerError: LocalizedError, Equatable, Sendable {
    case invalidPort(Int)
    case startupFailed(String)
    case startupTimedOut(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid local HTTP server port \(port). Expected a value between 1 and 65535."
        case .startupFailed(let message):
            "Local HTTP server failed to start: \(message)"
        case .startupTimedOut(let port):
            "Local HTTP server on port \(port) did not become ready in time."
        }
    }
}

public final class LocalHTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    public enum BindAddress: Sendable {
        case loopback
        case any
    }

    private let port: UInt16
    private let bindAddress: BindAddress
    private let limits: LocalHTTPServerLimits
    private let handler: Handler
    private let queue: DispatchQueue
    private var listener: NWListener?

    public init(
        port: Int,
        label: String,
        bindAddress: BindAddress = .loopback,
        limits: LocalHTTPServerLimits = .standard,
        handler: @escaping Handler
    ) throws {
        guard (1...65_535).contains(port), let validatedPort = UInt16(exactly: port) else {
            throw LocalHTTPServerError.invalidPort(port)
        }
        self.port = validatedPort
        self.bindAddress = bindAddress
        self.limits = limits
        self.handler = handler
        self.queue = DispatchQueue(label: label)
    }

    public func start() throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw LocalHTTPServerError.invalidPort(Int(self.port))
        }
        let startup = StartupState()
        let ready = DispatchSemaphore(value: 0)
        let parameters = NWParameters.tcp
        let listener: NWListener
        switch bindAddress {
        case .loopback:
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: port)
            listener = try NWListener(using: parameters)
        case .any:
            listener = try NWListener(using: parameters, on: port)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startup.fail(error.localizedDescription)
                ready.signal()
            case .cancelled:
                startup.fail("listener cancelled before becoming ready")
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw LocalHTTPServerError.startupTimedOut(Int(self.port))
        }
        if let message = startup.failureMessage {
            listener.cancel()
            throw LocalHTTPServerError.startupFailed(message)
        }
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            switch Self.bufferedRequest(nextBuffer, limits: limits, isComplete: isComplete) {
            case .ready(let request):
                let response = handler(request)
                connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .error(let response):
                connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .incomplete:
                self.receive(connection, buffer: nextBuffer)
            }
        }
    }

    private enum BufferedRequest {
        case incomplete
        case ready(HTTPRequest)
        case error(HTTPResponse)
    }

    private struct HeaderDelimiter {
        var lowerBound: Data.Index
        var upperBound: Data.Index
    }

    private static func bufferedRequest(_ data: Data, limits: LocalHTTPServerLimits, isComplete: Bool) -> BufferedRequest {
        let delimiter = headerDelimiter(in: data)
        guard let delimiter else {
            if data.count > limits.maxHeaderBytes {
                return .error(.error(431, "Request Header Fields Too Large", "HTTP request headers are too large"))
            }
            return isComplete
                ? .error(.error(400, "Bad Request", "Could not parse HTTP request"))
                : .incomplete
        }

        guard delimiter.upperBound <= limits.maxHeaderBytes else {
            return .error(.error(431, "Request Header Fields Too Large", "HTTP request headers are too large"))
        }

        let headerData = data[..<delimiter.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .error(.error(400, "Bad Request", "Could not parse HTTP request headers"))
        }

        guard let contentLength = parsedContentLength(from: headerText) else {
            return .error(.error(400, "Bad Request", "Invalid Content-Length header"))
        }

        guard contentLength <= limits.maxBodyBytes else {
            return .error(.error(413, "Payload Too Large", "HTTP request body is too large"))
        }

        let totalLength = delimiter.upperBound + contentLength
        guard totalLength >= delimiter.upperBound else {
            return .error(.error(413, "Payload Too Large", "HTTP request body is too large"))
        }

        guard data.count >= totalLength else {
            return isComplete
                ? .error(.error(400, "Bad Request", "Incomplete HTTP request body"))
                : .incomplete
        }

        guard let request = parseRequest(data, delimiter: delimiter, contentLength: contentLength) else {
            return .error(.error(400, "Bad Request", "Could not parse HTTP request"))
        }
        return .ready(request)
    }

    private static func parseRequest(_ data: Data, delimiter: HeaderDelimiter, contentLength: Int) -> HTTPRequest? {
        let headerData = data[..<delimiter.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let bodyStart = delimiter.upperBound
        let bodyEnd = bodyStart + contentLength
        guard bodyEnd <= data.endIndex else { return nil }
        let body = Data(data[bodyStart..<bodyEnd])
        let lines = headerText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        return HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    private static func headerDelimiter(in data: Data) -> HeaderDelimiter? {
        let crlf = data.range(of: Data("\r\n\r\n".utf8))
        let lf = data.range(of: Data("\n\n".utf8))
        let selected: Range<Data.Index>?
        switch (crlf, lf) {
        case (.some(let crlf), .some(let lf)):
            selected = crlf.lowerBound <= lf.lowerBound ? crlf : lf
        case (.some(let crlf), .none):
            selected = crlf
        case (.none, .some(let lf)):
            selected = lf
        case (.none, .none):
            selected = nil
        }
        guard let selected else { return nil }
        return HeaderDelimiter(lowerBound: selected.lowerBound, upperBound: selected.upperBound)
    }

    private static func parsedContentLength(from headerText: String) -> Int? {
        let contentLengthValues = headerText
            .components(separatedBy: .newlines)
            .dropFirst()
            .compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        guard contentLengthValues.count <= 1 else {
            return nil
        }
        guard let value = contentLengthValues.first else {
            return 0
        }
        guard let contentLength = Int(value), contentLength >= 0 else {
            return nil
        }
        return contentLength
    }
}

private final class StartupState: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    var failureMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }

    func fail(_ message: String) {
        lock.lock()
        if self.message == nil {
            self.message = message
        }
        lock.unlock()
    }
}
