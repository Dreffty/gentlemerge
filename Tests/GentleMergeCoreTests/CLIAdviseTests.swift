import XCTest
@testable import GentleMergeCore

/// The `advise` answer through the real binary: warn JSON by default, deny
/// JSON under policy deny, and silence under GENTLEMERGE_SKIP.
final class CLIAdviseTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-advise-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        // hermes holds Sources/**; the advice below runs as codex.
        _ = Shell.run(binary, ["claim", "--paths", "Sources/**", "--project", root.path], in: root,
            environment: ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "hermes"])
        let payload = #"{"tool_input": {"file_path": "Sources/App.swift"}}"#
        try Data(payload.utf8).write(to: root.appendingPathComponent("payload.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func advise(extraEnv: [String: String] = [:]) -> Shell.Output {
        var env = ["GENTLEMERGE_HOME": home.path]
        for (key, value) in extraEnv { env[key] = value }
        return Shell.run(binary,
            ["advise", "--payload", root.appendingPathComponent("payload.json").path,
             "--provider", "codex", "--project", root.path],
            in: root, environment: env)
    }

    func testAWarnIsAllowWithContext() throws {
        let output = advise()
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.contains("\"permissionDecision\""), output.stdout)
        XCTAssertTrue(output.stdout.contains("allow"), output.stdout)
        XCTAssertTrue(output.stdout.contains("hermes"), output.stdout)
    }

    func testSkipMeansSilence() throws {
        let output = advise(extraEnv: ["GENTLEMERGE_SKIP": "1"])
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, output.stdout)
    }

    func testDenyPolicyRefusesAClaimedPath() throws {
        let paths = Paths(home: home)
        try paths.createDirectories()
        var config = AppConfig()
        config.claimsPolicy = "deny"
        config.save(to: paths.config)
        let output = advise()
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.contains("deny"), output.stdout)
        XCTAssertTrue(output.stdout.contains("permissionDecisionReason"), output.stdout)
    }

    func testAnUnclaimedPathIsSilent() throws {
        let payload = #"{"tool_input": {"file_path": "Docs/notes.md"}}"#
        try Data(payload.utf8).write(to: root.appendingPathComponent("payload.json"))
        let output = advise()
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, output.stdout)
    }
}
