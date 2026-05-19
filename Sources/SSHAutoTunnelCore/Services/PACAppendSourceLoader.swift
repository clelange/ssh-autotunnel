import Foundation

public enum PACAppendSourceLoadError: LocalizedError, Sendable {
    case disabled
    case missingLocation
    case invalidURL(String)
    case unsupportedURLScheme(String?)
    case httpStatus(Int)
    case invalidText

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Existing PAC appending is disabled."
        case .missingLocation:
            "Existing PAC source location is required."
        case .invalidURL(let value):
            "Existing PAC URL is invalid: \(value)."
        case .unsupportedURLScheme(let scheme):
            "Existing PAC URL scheme is unsupported: \(scheme ?? "missing")."
        case .httpStatus(let statusCode):
            "Existing PAC URL returned HTTP \(statusCode)."
        case .invalidText:
            "Existing PAC source is not valid UTF-8 text."
        }
    }
}

public enum PACAppendSourceLoader {
    public static func load(_ source: PACAppendSource, session: URLSession = .shared) async throws -> String {
        guard source.enabled else {
            throw PACAppendSourceLoadError.disabled
        }
        let location = source.trimmedLocation
        guard !location.isEmpty else {
            throw PACAppendSourceLoadError.missingLocation
        }

        let data: Data
        switch source.kind {
        case .file:
            data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: fileURL(from: location))
            }.value
        case .url:
            guard let url = URL(string: location) else {
                throw PACAppendSourceLoadError.invalidURL(location)
            }
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url)
                }.value
            } else {
                guard ["http", "https"].contains(url.scheme?.lowercased()) else {
                    throw PACAppendSourceLoadError.unsupportedURLScheme(url.scheme)
                }
                let (receivedData, response) = try await session.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw PACAppendSourceLoadError.httpStatus(httpResponse.statusCode)
                }
                data = receivedData
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw PACAppendSourceLoadError.invalidText
        }
        return text
    }

    private static func fileURL(from location: String) -> URL {
        if let url = URL(string: location), url.isFileURL {
            return url
        }
        let expanded = NSString(string: location).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}
