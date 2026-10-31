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

/// Each agent gets its own ports, whichever way it says who it is.
final class EnvPortsPerLabelTests: XCTestCase {
    private var root: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("env-ports-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "init", "-q", "-b", "main"], in: root).status, 0)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func base(label: String?) -> String {
        var environment = ["GENTLEMERGE_HOME": root.appendingPathComponent("home").path]
        if let label { environment["GENTLEMERGE_LABEL"] = label }
        let out = Shell.run(binary, ["env"], in: root, environment: environment, timeout: 60)
        return out.stdout.split(separator: "\n").first { $0.hasPrefix("export PORT=") }.map(String.init) ?? out.stdout
    }

    func testTwoAgentsToldApartByTheEnvironmentGetDifferentPorts() {
        let claude = base(label: "claude"), codex = base(label: "codex"), hermes = base(label: "hermes")
        XCTAssertNotEqual(claude, codex)
        XCTAssertNotEqual(claude, hermes)
        XCTAssertNotEqual(codex, hermes)
    }

    func testTheLabelInTheFileIsTheOneAskedFor() {
        let out = Shell.run(binary, ["env"], in: root,
                            environment: ["GENTLEMERGE_HOME": root.appendingPathComponent("home").path,
                                          "GENTLEMERGE_LABEL": "codex"], timeout: 60)
        XCTAssertTrue(out.stdout.contains("export GENTLEMERGE_LABEL='codex'"), out.stdout)
    }
}

/// `who` without the app: the answer must come from the events already spooled.
final class WhoWithoutTheAppTests: XCTestCase {
    func testWhoSeesAnAgentWhoseEventsAreStillInTheSpool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("who-spool-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "init", "-q", "-b", "main"], in: repo).status, 0)
        let paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()

        let payload: JSONValue = .object([
            "session_id": .string("cl-1"), "cwd": .string(repo.path),
            "hook_event_name": .string("UserPromptSubmit"), "prompt": .string("escribiendo los tests del radar"),
        ])
        let envelope = SpoolEnvelope(
            id: UUID().uuidString, provider: .claudeCode, receivedAt: Date(), cwd: repo.path,
            pid: Int(ProcessInfo.processInfo.processIdentifier), payload: payload)
        try SpoolStore(paths: paths).enqueue(envelope)

        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let out = Shell.run(binary, ["who", "--all"], in: repo,
                            environment: ["GENTLEMERGE_HOME": paths.home.path, "GENTLEMERGE_LABEL": "hermes"], timeout: 60)
        XCTAssertTrue(out.stdout.contains("escribiendo los tests del radar"), out.stdout)
    }
}

/// One app per home, and a stale pid file is not a running app (audit 2026-11-01).
final class SingleAppInstanceTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("one-app-\(UUID())")
        paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func status() -> String {
        Shell.run(binary, ["status"], in: root, environment: ["GENTLEMERGE_HOME": paths.home.path,
            "GENTLEMERGE_CLAUDE_SETTINGS": root.appendingPathComponent("cs.json").path,
            "GENTLEMERGE_CODEX_CONFIG": root.appendingPathComponent("cc.toml").path], timeout: 30).stdout
    }

    func testAPidThatBelongsToAnotherProgramIsNotARunningApp() throws {
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: paths.appPID)
        XCTAssertTrue(status().contains("app:             not running"), status())
    }

    func testALiveGentlemergeIsTheRunningAppAndASecondOneDoesNotStart() throws {
        // A gentlemerge process that stays up: the MCP server waits on stdin.
        let stand = Process()
        stand.executableURL = URL(fileURLWithPath: binary)
        stand.arguments = ["mcp"]
        stand.environment = ["GENTLEMERGE_HOME": paths.home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        stand.standardInput = input
        stand.standardOutput = FileHandle.nullDevice
        try stand.run()
        defer { stand.terminate(); stand.waitUntilExit() }
        try Data(String(stand.processIdentifier).utf8).write(to: paths.appPID)

        XCTAssertTrue(status().contains("running (pid \(stand.processIdentifier))"), status())

        let second = Shell.run(binary, [], in: root, environment: ["GENTLEMERGE_HOME": paths.home.path], timeout: 15)
        XCTAssertFalse(second.timedOut, "a second app started instead of stepping aside")
        XCTAssertEqual(second.status, 0)
        XCTAssertTrue(second.stderr.contains("already running"), second.stderr)
    }
}

final class DoctorStalePidTests: XCTestCase {
    func testDoctorDoesNotCallAnotherProgramTheApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-pid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        // This test runner is alive and is not a gentlemerge.
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: paths.appPID)
        XCTAssertTrue(Doctor.app(paths: paths).detail.hasPrefix("not running"), Doctor.app(paths: paths).detail)
    }
}
