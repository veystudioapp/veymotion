import Foundation
import Network

// MARK: - Streamable HTTP (localhost only)

/// Minimal MCP Streamable HTTP transport: POST /mcp with a JSON-RPC message, JSON response.
/// No SSE stream (GET returns 405), which the spec allows. Bound to 127.0.0.1 only.
public final class MCPHTTPServer {
    public let port: UInt16
    public var token: String?
    public var onStateChange: ((String) -> Void)?

    private let server: MCPServer
    private let queue = DispatchQueue(label: "veymotion.mcp.http")
    private var listener: NWListener?

    public init(server: MCPServer, port: UInt16 = 19790, token: String? = nil) {
        self.server = server
        self.port = port
        self.token = token
    }

    public var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onStateChange?("Listening on \(self.endpoint)")
            case let .failed(e): self.onStateChange?("Failed: \(e.localizedDescription)")
            case .cancelled: self.onStateChange?("Stopped")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case let .complete(req):
                // Tools like export_video can take a while; don't block other requests.
                DispatchQueue.global(qos: .userInitiated).async { self.respond(conn, req) }
            case .incomplete:
                if isComplete || error != nil { conn.cancel(); return }
                if buf.count > 64 << 20 { self.send(conn, 413, Data()); return }
                self.receive(conn, buffer: buf)
            case .invalid:
                self.send(conn, 400, Data())
            }
        }
    }

    private func respond(_ conn: NWConnection, _ req: HTTPRequest) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        guard path == "/mcp" else { return send(conn, 404, Data()) }

        // DNS-rebinding protection: browsers send Origin; only allow local origins.
        if let origin = req.headers["origin"], let host = URL(string: origin)?.host,
           !["localhost", "127.0.0.1", "::1"].contains(host) {
            return send(conn, 403, Data())
        }
        if let token, req.headers["authorization"] != "Bearer \(token)" {
            return send(conn, 401, Data())
        }
        guard req.method == "POST" else { return send(conn, 405, Data(), extra: ["Allow": "POST"]) }

        guard let obj = try? JSONSerialization.jsonObject(with: req.body) else {
            return sendJSON(conn, MCPServer.error(nil, code: -32700, "Parse error"))
        }
        if let msg = obj as? [String: Any] {
            if let resp = server.handle(msg) { sendJSON(conn, resp) } else { send(conn, 202, Data()) }
        } else if let batch = obj as? [[String: Any]] {
            let resps = batch.compactMap { server.handle($0) }
            if resps.isEmpty { send(conn, 202, Data()) } else { sendJSON(conn, resps) }
        } else {
            sendJSON(conn, MCPServer.error(nil, code: -32600, "Invalid request"))
        }
    }

    private func sendJSON(_ conn: NWConnection, _ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        send(conn, 200, data, extra: ["Content-Type": "application/json"])
    }

    private func send(_ conn: NWConnection, _ status: Int, _ body: Data, extra: [String: String] = [:]) {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                                     headers: headers, body: Data(body)))
    }
}

// MARK: - stdio

/// Newline-delimited JSON-RPC over stdin/stdout. Logs must go to stderr.
public enum MCPStdioTransport {
    public static func run(server: MCPServer) {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
                write(MCPServer.error(nil, code: -32700, "Parse error"))
                continue
            }
            if let msg = obj as? [String: Any] {
                if let resp = server.handle(msg) { write(resp) }
            } else if let batch = obj as? [[String: Any]] {
                let resps = batch.compactMap { server.handle($0) }
                if !resps.isEmpty { write(resps) }
            }
        }
    }

    static func write(_ obj: Any) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
