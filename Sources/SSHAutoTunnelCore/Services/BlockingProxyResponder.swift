import Foundation

public enum BlockingProxyResponder {
    public static func response(for request: HTTPRequest, statusURL: String) -> HTTPResponse {
        if request.method.uppercased() == "CONNECT" {
            return HTTPResponse(
                statusCode: 502,
                reason: "Bad Gateway",
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data(connectFailureMessage(for: request, statusURL: statusURL).utf8)
            )
        }

        return HTTPResponse(
            statusCode: 200,
            reason: "OK",
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
            ],
            body: Data(statusPage(for: request, statusURL: statusURL).utf8)
        )
    }

    private static func connectFailureMessage(for request: HTTPRequest, statusURL: String) -> String {
        """
        SSH AutoTunnel cannot proxy \(request.path) because the selected tunnel is unavailable.
        Open \(statusURL) for tunnel status.
        """
    }

    private static func statusPage(for request: HTTPRequest, statusURL: String) -> String {
        let target = escape(request.path)
        let host = escape(request.headers["host"] ?? "")
        let statusURL = escape(statusURL)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>SSH AutoTunnel tunnel unavailable</title>
          <style>
            body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;margin:32px;line-height:1.45;max-width:760px}
            code{background:#eee;padding:2px 5px;border-radius:4px}
            .status{display:inline-block;padding:2px 8px;border-radius:999px;background:#f8d7da;color:#7f1d1d;font-size:13px}
          </style>
        </head>
        <body>
          <p class="status">Tunnel unavailable</p>
          <h1>SSH AutoTunnel cannot proxy this request</h1>
          <p>The PAC file routed this request through SSH AutoTunnel, but the selected SSH tunnel is not currently healthy.</p>
          <p>Target: <code>\(target)</code></p>
          <p>Host: <code>\(host)</code></p>
          <p>Open <a href="\(statusURL)">SSH AutoTunnel status</a> for current tunnel state.</p>
        </body>
        </html>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
