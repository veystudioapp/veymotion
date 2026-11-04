import Darwin
import Foundation

/// Local control channel between the `vmotion` CLI and a running VeyMotion app.
/// Unix domain socket (no network port), one newline-terminated JSON-RPC message per connection,
/// handled by the same `MCPServer` tool layer the MCP transports use.
public enum ControlSocket {
    public static var defaultPath: String {
        if let p = ProcessInfo.processInfo.environment["VEYMOTION_SOCKET"], !p.isEmpty { return p }
        return supportDirectory.appendingPathComponent("control.sock").path
    }

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VeyMotion", isDirectory: true)
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) } // includes trailing NUL
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n
                p = p.advanced(by: n)
            }
            return true
        }
    }

    /// Reads until a newline or EOF.
    static func readLine(_ fd: Int32, limit: Int = 64 << 20) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < limit {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        if let nl = out.firstIndex(of: 0x0A) { out = out[out.startIndex..<nl] }
        return out
    }
}

public struct SocketError: LocalizedError {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class ControlSocketServer {
    public let path: String
    private let server: MCPServer
    private var fd: Int32 = -1

    public init(server: MCPServer, path: String = ControlSocket.defaultPath) {
        self.server = server
        self.path = path
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path) // stale socket from a previous run

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket(): \(String(cString: strerror(errno)))") }
        var addr = try ControlSocket.makeAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd); fd = -1
            throw SocketError("bind(\(path)): \(msg)")
        }
        chmod(path, 0o600) // current user only
        guard listen(fd, 16) == 0 else { throw SocketError("listen(): \(String(cString: strerror(errno)))") }

        let listenFD = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listenFD, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return // socket closed
                }
                ControlSocket.noSigPipe(c)
                DispatchQueue.global(qos: .userInitiated).async {
                    if let self { self.serve(c) } else { close(c) }
                }
            }
        }
    }

    public func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        let line = ControlSocket.readLine(c)
        let response: Any
        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            response = server.handle(obj) ?? [:]
        } else {
            response = MCPServer.error(nil, code: -32700, "Parse error")
        }
        guard var data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        _ = ControlSocket.writeAll(c, data)
    }
}

public enum ControlSocketClient {
    public static func send(_ message: [String: Any], path: String = ControlSocket.defaultPath) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket(): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        ControlSocket.noSigPipe(fd)
        var addr = try ControlSocket.makeAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw SocketError("connect(\(path)): \(String(cString: strerror(errno)))") }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        guard ControlSocket.writeAll(fd, data) else { throw SocketError("write failed") }
        let reply = ControlSocket.readLine(fd)
        guard let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw SocketError("invalid reply")
        }
        return obj
    }
}
