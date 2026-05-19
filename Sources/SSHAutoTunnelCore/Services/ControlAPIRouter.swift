import Foundation

public struct ControlAPIRouter {
    public typealias TokenProvider = () -> String
    public typealias StatusProvider = () -> ControlResponse
    public typealias ControlHandler = (ControlRequest) -> ControlResponse

    private let tokenProvider: TokenProvider
    private let statusProvider: StatusProvider
    private let controlHandler: ControlHandler
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        tokenProvider: @escaping TokenProvider,
        statusProvider: @escaping StatusProvider,
        controlHandler: @escaping ControlHandler,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.tokenProvider = tokenProvider
        self.statusProvider = statusProvider
        self.controlHandler = controlHandler
        self.encoder = encoder
        self.decoder = decoder
    }

    public func response(for request: HTTPRequest) -> HTTPResponse {
        guard request.headers["authorization"] == "Bearer \(tokenProvider())" else {
            return .error(401, "Unauthorized", "Missing or invalid API token")
        }

        if request.method == "GET", request.path.hasPrefix("/status") {
            return .json(statusProvider(), encoder: encoder)
        }

        guard request.method == "POST", request.path.hasPrefix("/api") else {
            return .error(404, "Not Found", "Unknown API route")
        }

        do {
            let controlRequest = try decoder.decode(ControlRequest.self, from: request.body)
            return .json(controlHandler(controlRequest), encoder: encoder)
        } catch {
            var response = statusProvider()
            response.ok = false
            response.message = error.localizedDescription
            return .json(response, encoder: encoder)
        }
    }
}
