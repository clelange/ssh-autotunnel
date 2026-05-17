import Foundation

public final class ControlAPIClient {
    private let baseURL: URL
    private let token: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    public convenience init(configuration: AppConfiguration) {
        self.init(baseURL: URL(string: "http://127.0.0.1:\(configuration.apiHTTPPort)")!, token: configuration.apiToken)
    }

    public func send(_ controlRequest: ControlRequest) async throws -> ControlResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(controlRequest)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw NSError(domain: "ControlAPIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try decoder.decode(ControlResponse.self, from: data)
    }
}
