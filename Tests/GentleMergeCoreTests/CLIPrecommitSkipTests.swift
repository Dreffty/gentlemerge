import XCTest
@testable import GentleMergeCore

/// The human escape hatch is handled inside the binary so every skip is
/// published — and the rejection text never teaches the variable to a model.
final class CLIPrecommitSkipTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var repo: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-skip-\(UUID())")
        home = root.appendingPathComponent("home")
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        _ = Shell.run("/usr/bin/env", ["git", "init", "-q", "-b", "main"], in: repo, timeout: 15)
        _ = Shell.run("/usr/bin/env", ["git", "config", "user.email", "t@example.invalid"], in: repo, timeout: 15)
        _ = Shell.run("/usr/bin/env", ["git", "config", "user.name", "Test"], in: repo, timeout: 15)
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("f.txt"))
        _ = Shell.run("/usr/bin/env", ["git", "add", "-A"], in: repo, timeout: 15)
        _ = Shell.run("/usr/bin/env", ["git", "commit", "-qm", "base"], in: repo, timeout: 15)
        _ = Shell.run(binary, ["project", "init", "--label", "codex", "--project", repo.path], in: repo,
            environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
        _ = Shell.run(binary, ["claim", "--paths", "Sources/**", "--project", repo.path], in: repo,
            environment: ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "hermes"], timeout: 60)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("Sources/a.swift"))
        _ = Shell.run("/usr/bin/env", ["git", "add", "-A"], in: repo, timeout: 15)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func enforce(extraEnv: [String: String] = [:]) -> Shell.Output {
        var env = ["GENTLEMERGE_HOME": home.path]
        for (key, value) in extraEnv { env[key] = value }
        return Shell.run(binary, ["precommit", "--enforce", "--staged", "--project", repo.path],
            in: repo, environment: env, timeout: 60)
    }

    func testBlockedRejectionNeverNamesTheEscapeHatch() throws {
        let output = enforce()
        XCTAssertEqual(output.status, 1)
        XCTAssertFalse(output.stdout.contains("GENTLEMERGE_SKIP"), output.stdout)
    }

    func testAHumanSkipGoesThroughAndIsPublished() throws {
        let output = enforce(extraEnv: ["GENTLEMERGE_SKIP": "1"])
        XCTAssertEqual(output.status, 0, output.stdout + output.stderr)
        let bus = AgentBus(paths: Paths(home: home)).messages()
        XCTAssertTrue(bus.contains { $0.text.contains("human override") && $0.text.contains("skipped") },
            bus.map(\.text).joined(separator: "\n"))
        let ledger = try String(contentsOf: Paths(home: home).ledger, encoding: .utf8)
        XCTAssertTrue(ledger.contains("precommit.skipped"), ledger)
    }

    func testAnEmptySkipIsNoSkip() throws {
        // The demo inherits GENTLEMERGE_SKIP="" down the process tree; empty
        // means unset, exactly like the old `[ -n ... ]` shell check.
        let output = enforce(extraEnv: ["GENTLEMERGE_SKIP": ""])
        XCTAssertEqual(output.status, 1)
    }
}
