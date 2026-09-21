import XCTest
@testable import GentleMergeCore

final class MCPServerTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var paths: Paths!
    private var server: MCPServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID().uuidString)")
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()
        server = MCPServer(paths: paths, cwd: project.path, identity: "a")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func rpc(_ method: String, _ params: JSONValue = .object([:])) throws -> JSONValue {
        let line = try JSONCoding.encoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params
        ]))
        return try JSONCoding.decoder().decode(JSONValue.self, from: Data(XCTUnwrap(server.handle(line: String(decoding: line, as: UTF8.self))).utf8))
    }
    func testBriefStatusAndToolCatalogue() throws {
        let names = try rpc("tools/list")["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertEqual(Set(names), Set(["brief", "status", "claim", "claim_check", "release", "say", "delegate", "request_show", "request_update", "task_add", "task_done", "precommit", "presence", "watch_add", "watch_list", "watch_rm", "tool_help"]))
        _ = ProjectRegistry.addTask("fixture task", to: project.path, by: "a")
        let brief = try call("brief")
        XCTAssertTrue(text(brief).contains("fixture task"))
        _ = try call("status")
        XCTAssertEqual(text(try call("status")), "(nothing new)")
    }
    private func call(_ name: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        try rpc("tools/call", .object(["name": .string(name), "arguments": .object(args)]))
    }
    private func text(_ response: JSONValue) -> String {
        response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }
    func testClaimCheckIsReadOnlyAdvice() throws {
        XCTAssertTrue(text(try call("claim_check", ["paths": .array([.string("lib/a.swift")])])).contains("ok lib/a.swift"))
        _ = try PathClaims(paths: paths).claim(pattern: "lib/**", label: "other", project: project.path, intent: "busy")
        let flagged = text(try call("claim_check", ["paths": .array([.string("lib/a.swift")])]))
        XCTAssertTrue(flagged.contains("other"), flagged)
        XCTAssertTrue(PathClaims(paths: paths).live(project: project.path).count == 1, "checking claims nothing")
    }
    func testCatalogueBlurbsStayShortAndHelpCarriesTheRest() throws {
        let tools = try rpc("tools/list")["result"]?["tools"]?.arrayValue ?? []
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            let description = tool["description"]?.stringValue ?? ""
            XCTAssertLessThanOrEqual(description.count, 120, "\(tool["name"]?.stringValue ?? "?") blurb too long for every-turn context")
        }
        let help = text(try call("tool_help", ["name": .string("claim")]))
        XCTAssertTrue(help.contains("paths"), help)
        XCTAssertTrue(help.contains("required"), help)
        XCTAssertTrue(help.contains("TTL"), help)
        let missing = text(try call("tool_help", ["name": .string("nope")]))
        XCTAssertTrue(missing.contains("Known:"), missing)
    }
    func testClaimReleaseAndPresence() throws {
        XCTAssertTrue(text(try call("claim", ["paths": .array([.string("assets/**")])])).contains("claimed"))
        XCTAssertEqual(PathClaims(paths: paths).live(project: project.path).count, 1)
        XCTAssertEqual(text(try call("release")), "released")
        XCTAssertTrue(PathClaims(paths: paths).live(project: project.path).isEmpty)
        XCTAssertEqual(text(try call("presence", ["capabilities": .array([.string("art")])])), "ok")
        XCTAssertEqual(Presence.labels(withCapability: "art", project: project.path, paths: paths), ["a"])
    }
    func testPrecommitToolAndBriefRedaction() throws {
        _ = ProjectRegistry.addTask("rotate key sk-abcdef1234567890", to: project.path, by: "a")
        let brief = text(try call("brief"))
        XCTAssertTrue(brief.contains("rotate key"), "brief should include the task")
        XCTAssertFalse(brief.contains("sk-abcdef1234567890"), "brief must redact secrets")
        let response = try call("precommit")
        XCTAssertFalse(text(response).isEmpty, "precommit tool must answer, not error")
        XCTAssertEqual(response["error"]?.objectValue, nil, "precommit must not be an unknown tool")
    }
    func testTaskAndRequestLifecycle() throws {
        XCTAssertEqual(text(try call("task_add", ["text": .string("a shared task")])), "added")
        let task = try XCTUnwrap(ProjectRegistry.handoff(for: project.path, refreshingCommits: false).tasks.first)
        XCTAssertEqual(text(try call("task_done", ["id": .string(task.id)])), "done")
        XCTAssertTrue(ProjectRegistry.handoff(for: project.path, refreshingCommits: false).tasks.first!.done)
        XCTAssertEqual(text(try call("say", ["to": .string("b"), "text": .string("hello")])), "sent")
        let created = try call("delegate", ["to": .string("a"), "title": .string("build icon"), "spec": .string("make a blue icon")])
        XCTAssertTrue(text(created).contains("created req-"))
        let request = try XCTUnwrap(Requests(paths: paths).mine(from: "a", project: project.path).first)
        XCTAssertTrue(text(try call("request_show", ["id": .string(request.id)])).contains("make a blue icon"))
        for action in ["accept", "done", "ack"] {
            let response = try call("request_update", ["id": .string(request.id), "action": .string(action), "result": .string("finished")])
            XCTAssertTrue(text(response).contains(request.id))
        }
        XCTAssertEqual(Requests(paths: paths).load(request.id)?.state, .acked)
    }
    func testSchemasAndArgumentValidation() throws {
        let tools = try XCTUnwrap(rpc("tools/list")["result"]?["tools"]?.arrayValue)
        let claim = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "claim" })
        XCTAssertEqual(claim["inputSchema"]?["properties"]?["paths"]?["type"]?.stringValue, "array")
        XCTAssertEqual(claim["inputSchema"]?["required"]?.arrayValue, [.string("paths")])
        for (name, args) in [("say", ["text": JSONValue.string("hello")]),
                             ("claim", ["paths": .array([.number(7)])]),
                             ("delegate", ["to": .string("a"), "title": .string("t"), "spec": .string("s"), "budget_minutes": .number(1e100)]),
                             ("release", ["paths": .string("assets/**")])] {
            XCTAssertEqual(try call(name, args)["error"]?["code"]?.intValue, -32602)
        }
        XCTAssertTrue(PathClaims(paths: paths).live(project: project.path).isEmpty)
        XCTAssertTrue(Requests(paths: paths).mine(from: "a", project: project.path).isEmpty)
    }
    func testUnknownMethodAndTool() throws {
        XCTAssertEqual(try call("missing")["error"]?["code"]?.intValue, -32601)
        XCTAssertEqual(try rpc("missing")["error"]?["code"]?.intValue, -32601)
    }

    /// The CLI's `watch` without a terminal: add by session and by task, list,
    /// call off, and every refusal the CLI gives.
    func testWatchRoundTrip() throws {
        XCTAssertEqual(text(try call("watch_list")), "nothing being watched")

        let idle = text(try call("watch_add", ["kind": .string("session-idle"), "target": .string("b"), "note": .string("then review")]))
        XCTAssertTrue(idle.contains("finishes a turn"), idle)
        XCTAssertTrue(idle.contains("→ a"), idle)

        _ = ProjectRegistry.addTask("migrate the schema", to: project.path, by: "a")
        let task = text(try call("watch_add", ["kind": .string("task-done"), "target": .string("migrate")]))
        XCTAssertTrue(task.contains("ticked off"), task)

        let listed = text(try call("watch_list"))
        XCTAssertTrue(listed.contains("session-idle"), listed)
        XCTAssertTrue(listed.contains("task-done"), listed)

        let missing = try call("watch_add", ["kind": .string("task-done"), "target": .string("no such task")])
        XCTAssertEqual(missing["result"]?["isError"]?.boolValue, true)
        XCTAssertTrue(text(missing).contains("no task matching"), text(missing))

        let shortID = String(Watches(paths: paths).pending().first?.shortID ?? "")
        XCTAssertFalse(shortID.isEmpty)
        let removed = text(try call("watch_rm", ["id": .string(shortID)]))
        XCTAssertTrue(removed.contains("called off"), removed)
        XCTAssertEqual(Watches(paths: paths).pending().count, 1)

        let badKind = try call("watch_add", ["kind": .string("tea-time"), "target": .string("b")])
        XCTAssertEqual(badKind["error"]?["code"]?.intValue, -32602)
    }
    func testStdioSmokeRequiresBinary() throws {
        let binary = ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ""
        try XCTSkipUnless(!binary.isEmpty, "Set GENTLEMERGE_BIN to the built CLI")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["mcp", "--label", "smoke", "--project", project.path]
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(["GENTLEMERGE_HOME": paths.home.path]) { _, new in new }
        let input = Pipe()
        let outputURL = root.appendingPathComponent("stdout")
        let errorURL = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let exited = expectation(description: "stdio exits on EOF")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_add","arguments":{"text":"stdio fixture"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"brief"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"say","arguments":{}}}"#
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        wait(for: [exited], timeout: 15)
        guard !process.isRunning else { return }
        let diagnostics = try String(contentsOf: errorURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
        guard process.terminationStatus == 0 else { return }
        let linesOut = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n")
        let responses = try linesOut.map { try JSONCoding.decoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(responses.compactMap { $0["id"]?.intValue }, [1, 2, 3, 4])
        XCTAssertNotNil(responses.first?["result"]?["serverInfo"]?["version"]?.stringValue)
        XCTAssertTrue(responses.contains { text($0).contains("stdio fixture") })
        XCTAssertEqual(responses.last?["error"]?["code"]?.intValue, -32602)
        XCTAssertTrue(ProjectRegistry.handoff(for: project.path, refreshingCommits: false).tasks.contains { $0.text.contains("stdio fixture") })
    }

    func testInitializeAndPing() throws {
        let response = try rpc("initialize")
        XCTAssertEqual(response["id"]?.intValue, 1)
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"]?.stringValue, "gentlemerge")
        XCTAssertEqual(response["result"]?["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertNotNil(try rpc("ping")["result"]?.objectValue)
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }
}
