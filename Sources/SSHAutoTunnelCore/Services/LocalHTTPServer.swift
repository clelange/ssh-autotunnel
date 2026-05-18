import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
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

public final class LocalHTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    public enum BindAddress: Sendable {
        case loopback
        case any
    }

    private let port: UInt16
    private let bindAddress: BindAddress
    private let handler: Handler
    private let queue: DispatchQueue
    private var listener: NWListener?

    public init(port: Int, label: String, bindAddress: BindAddress = .loopback, handler: @escaping Handler) {
        self.port = UInt16(port)
        self.bindAddress = bindAddress
        self.handler = handler
        self.queue = DispatchQueue(label: label)
    }

    public func start() throws {
        let port = NWEndpoint.Port(rawValue: port)!
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
        listener.start(queue: queue)
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

            if Self.isCompleteRequest(nextBuffer) || isComplete {
                let request = Self.parseRequest(nextBuffer)
                let response = request.map(handler) ?? HTTPResponse.error(400, "Bad Request", "Could not parse HTTP request")
                connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                self.receive(connection, buffer: nextBuffer)
            }
        }
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n"),
              let headerDataEnd = data.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? data.range(of: Data("\n\n".utf8))?.upperBound else {
            return nil
        }

        let headerText = String(raw[..<headerEnd.lowerBound])
        let body = Data(data[headerDataEnd...])
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

    private static func isCompleteRequest(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? data.range(of: Data("\n\n".utf8))?.upperBound else {
            return false
        }
        let headerData = data[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return false
        }
        let contentLength = headerText
            .components(separatedBy: .newlines)
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0
        return data.count >= headerEnd + contentLength
    }
}
