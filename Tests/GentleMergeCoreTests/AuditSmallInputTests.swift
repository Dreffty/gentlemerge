import XCTest
@testable import GentleMergeCore

/// Inputs that were accepted and quietly meant something else (audit 2026-11-01).
final class JSONRPCInvalidRequestTests: XCTestCase {
    private var root: URL!
    private var server: MCPServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-invalid-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()
        server = MCPServer(paths: paths, cwd: project.path, identity: "a")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func reply(_ line: String) throws -> JSONValue? {
        try server.handle(line: line).map { try JSONCoding.decoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    func testAnObjectWithNoMethodAndNoIdIsAnInvalidRequestNotSilence() throws {
        for line in ["{}", #"{"jsonrpc":"2.0"}"#, #"{"jsonrpc":"2.0","params":{}}"#, #"{"jsonrpc":"2.0","method":5}"#] {
            let answer = try XCTUnwrap(reply(line), "\(line) got no reply")
            XCTAssertEqual(answer["error"]?["code"], .number(-32600), line)
            XCTAssertEqual(answer["id"], .null)
        }
    }

    func testARealNotificationStillGetsNoReply() throws {
        XCTAssertNil(try reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(try reply(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#))
    }
}

final class SmallInputCLITests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("small-input-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func run(_ args: [String]) -> Shell.Output {
        Shell.run(binary, args, in: root, environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
    }

    func testHistoryRefusesALimitThatIsNotAPositiveNumber() {
        for limit in ["abc", "0", "-3", "1.5", ""] {
            let out = run(["history", "-n", limit])
            XCTAssertEqual(out.status, 64, "-n \(limit) was accepted: \(out.stdout)")
        }
        XCTAssertEqual(run(["history", "-n"]).status, 64)
        XCTAssertEqual(run(["history", "-n", "5"]).status, 0)
        XCTAssertEqual(run(["history"]).status, 0)
    }

    func testAnUrgentNoteThatIsAlsoFyiIsRefused() {
        let out = run(["say", "hola", "--urgent", "--fyi", "--global"])
        XCTAssertEqual(out.status, 64, out.stdout)
        XCTAssertTrue(out.stderr.contains("contradict"), out.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("messages.jsonl").path))
        XCTAssertEqual(run(["say", "hola", "--urgent", "--global"]).status, 0)
        XCTAssertEqual(run(["say", "hola", "--fyi", "--global"]).status, 0)
    }
}
