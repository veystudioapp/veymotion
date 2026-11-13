import Foundation
import Testing
@testable import VeyMotionCore
@testable import VeyMotionMCP

@Suite struct MCPServerTests {
    private func makeServer() throws -> (MCPServer, URL) {
        // $TMPDIR rather than the system temp folder: sandboxed runs may only write there.
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("veymotion-test-\(UUID().uuidString).json")
        let host = try FileSceneHost(url: url, activatesLibrary: false)
        return (MCPServer(host: host), url)
    }

    private func call(_ server: MCPServer, _ tool: String, _ args: [String: Any] = [:]) -> (text: String, isError: Bool) {
        let reply = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": tool, "arguments": args]])
        let result = reply?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    @Test func toolListMatchesTheSchemas() throws {
        let (server, url) = try makeServer()
        defer { try? FileManager.default.removeItem(at: url) }
        let reply = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        #expect(names.isSuperset(of: ["get_scene", "set_scene", "add_layer", "update_layer", "apply_preset", "transition", "render_frame"]))
        #expect(names.count == Docs.tools.count)
    }

    @Test func editsGoToTheFileAndBack() throws {
        let (server, url) = try makeServer()
        defer { try? FileManager.default.removeItem(at: url) }
        let added = call(server, "add_layer", ["layer": ["id": "title", "type": "text", "text": "Hi", "x": 100, "y": 100]])
        #expect(!added.isError, Comment(rawValue: added.text))
        let patched = call(server, "update_layer", ["id": "title", "changes": ["fontSize": 72, "x": NSNull()]])
        #expect(!patched.isError, Comment(rawValue: patched.text))
        let saved = try SceneJSON.decode(MotionScene.self, from: Data(contentsOf: url))
        let title = try saved.layer("title")
        #expect(title.fontSize == 72)
        // null resets a field to its default: for x, the center of the scene.
        #expect(title.x.value(at: 0) == Double(saved.width) / 2)
    }

    @Test func toolFailuresAreErrorContentNotProtocolErrors() throws {
        let (server, url) = try makeServer()
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = call(server, "update_layer", ["id": "nope", "changes": ["x": 1]])
        #expect(missing.isError)
        #expect(missing.text.contains("nope"))
        let reply = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "update_layer", "arguments": ["id": "nope", "changes": [:]]]])
        #expect(reply?["error"] == nil)
    }
}
