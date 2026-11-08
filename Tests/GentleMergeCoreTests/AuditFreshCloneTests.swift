import XCTest
@testable import GentleMergeCore

/// What a clean clone, followed by the README, turned up (audit 2026-11-06).

final class HelpNeverRunsTheCommandTests: XCTestCase {
    private var root: URL!
    private var settings: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("help-\(UUID())")
        settings = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func run(_ args: [String]) -> Shell.Output {
        Shell.run(binary, args, in: root, environment: [
            "GENTLEMERGE_HOME": root.appendingPathComponent("home").path,
            "GENTLEMERGE_CLAUDE_SETTINGS": settings.path,
            "GENTLEMERGE_CODEX_CONFIG": root.appendingPathComponent("config.toml").path,
        ], timeout: 30)
    }

    func testAskingAboutUninstallLeavesTheHooksInstalled() throws {
        XCTAssertEqual(run(["install"]).status, 0)
        let before = try Data(contentsOf: settings)
        for spelling in ["--help", "-h"] {
            let out = run(["uninstall", spelling])
            XCTAssertEqual(out.status, 0, out.text)
            XCTAssertTrue(out.stdout.contains("gentlemerge uninstall"), out.stdout)
            XCTAssertFalse(out.stdout.contains("removed from"), out.stdout)
            XCTAssertEqual(try Data(contentsOf: settings), before, "\(spelling) uninstalled the hooks")
        }
    }

    func testAskingAboutInstallInstallsNothing() {
        XCTAssertEqual(run(["install", "--help"]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }

    func testEveryCommandThatActsOnlyAnswers() {
        for command in ["land", "compact", "demo", "mcp", "say", "claim", "release", "task", "test-event", "radar"] {
            let out = run([command, "--help"])
            XCTAssertFalse(out.timedOut, "\(command) --help started working")
            XCTAssertEqual(out.status, 0, "\(command): \(out.text)")
            XCTAssertTrue(out.stdout.contains("gentlemerge"), "\(command): \(out.stdout)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("home/messages.jsonl").path), "something was said")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("home/spool").path))?.count ?? 0, 0, "an event was queued")
    }

    func testHelpNamesTheCommandAskedAbout() {
        let out = run(["help", "say"])
        XCTAssertTrue(out.stdout.contains("gentlemerge say"), out.stdout)
        XCTAssertFalse(out.stdout.contains("gentlemerge doctor"), "the whole usage instead of one command")
        XCTAssertTrue(run(["help"]).stdout.contains("USAGE"))
        XCTAssertTrue(run(["--help"]).stdout.contains("USAGE"))
    }

    func testTheQuestionCountsWhereverItIsUpToADoubleDash() {
        XCTAssertTrue(run(["land", "x", "-h"]).stdout.hasPrefix("  gentlemerge land"))
        XCTAssertTrue(run(["land", "--into", "main", "--help"]).stdout.hasPrefix("  gentlemerge land"))
        XCTAssertFalse(run(["say", "a note", "--global", "--", "--help"]).stdout.hasPrefix("  gentlemerge say"))
    }
}

final class ScrubbingTwiceTests: XCTestCase {
    /// A note is scrubbed when it is written and again when it is read.
    func testAScrubbedTextStaysAsItIs() {
        let samples = [
            "mysql -u root -phunter2hunter2 -h db",
            "mysqldump -uroot -p'hunter2 two' app",
            "mariadb -h db -p\"hunter2hunter2\" app",
            "sshpass -p hunter2hunter2 ssh deploy@host",
            "sshpass -phunter2hunter2 rsync -a . host:",
            "curl -u admin:s3cr3tpass x.com",
            "mysql --password hunter2hunter2 -h db",
            "gh --token=abcdef123456 pr list",
            "password: hunter2hunter2",
            "API_KEY=abcdef1234567890",
            "SECRET_KEY = 'q9x8w7e6r5t4y3u2i1o0pLKJHG'",
            "Authorization: Bearer abcdef1234567890",
            "postgres://user:hunter2hunter2@db.example.com/app",
            "escribe a alguien@example.com",
            "tarjeta 4111 1111 1111 1111",
            "sigue: 1234567890123",
        ]
        for sample in samples {
            let once = Redactor.scrub(sample).text
            XCTAssertNotEqual(once, sample, "not redacted at all: \(sample)")
            XCTAssertEqual(Redactor.scrub(once).text, once, sample)
        }
    }

    func testAPasswordThatStartsWithAColonIsStillAPassword() {
        XCTAssertFalse(Redactor.scrub("mysql -u root -p:hunter2hunter2").text.contains("hunter2hunter2"))
    }
}

/// One agent, one line: its session, and the note it left from the CLI.
final class OneAgentOneRowTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var bus: AgentBus!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("one-row-\(UUID())")
        paths = try Paths(home: root).createDirectories()
        bus = AgentBus(paths: paths)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session(_ id: String, _ provider: AgentProvider, label: String? = nil,
                         project: String = "/p", state: AgentActivity.State = .working) -> AgentActivity {
        var row = AgentActivity(id: id, provider: provider, projectPath: project, startedAt: Date(), updatedAt: Date(),
                                currentTask: "migrando el schema", state: state, label: label)
        row.label = label
        return row
    }

    private func labels() -> [String] {
        bus.activities().filter(\.isLive).map { $0.label ?? AgentBus.label(for: $0.provider) }.sorted()
    }

    func testACLICallFromAnAgentWithALiveSessionAddsNoRow() {
        bus.save([session("cx-1", .codex)])
        Presence.record(label: "codex", project: "/p", branch: "main", paths: paths, environment: [:])
        XCTAssertEqual(labels(), ["codex"])
        XCTAssertEqual(bus.activities().first?.currentTask, "migrando el schema", "the session says more than the mark")
    }

    func testTheLabelOfTheSessionCountsOverItsProvider() {
        bus.save([session("cl-1", .claudeCode, label: "front")])
        Presence.record(label: "front", project: "/p", branch: "main", paths: paths, environment: [:])
        XCTAssertEqual(labels(), ["front"])
    }

    func testAnotherAgentOrAnotherProjectIsStillListed() {
        bus.save([session("cx-1", .codex)])
        Presence.record(label: "hermes", project: "/p", branch: "main", paths: paths, environment: [:])
        Presence.record(label: "codex", project: "/other", branch: "main", paths: paths, environment: [:])
        XCTAssertEqual(labels(), ["codex", "codex", "hermes"])
    }

    func testTwoBranchesAreStillOneAgent() {
        let now = Date()
        Presence.record(label: "codex", project: "/p", branch: nil, paths: paths, environment: [:],
                        now: now.addingTimeInterval(-5))
        Presence.record(label: "codex", project: "/p", branch: "agent/codex", paths: paths, environment: [:], now: now)
        XCTAssertEqual(labels(), ["codex"])
        XCTAssertEqual(bus.activities().first?.branch, "agent/codex", "the newest one speaks")
    }

    func testTheMarkSpeaksAgainWhenTheSessionIsOver() {
        bus.save([session("cx-1", .codex, state: .ended)])
        Presence.record(label: "codex", project: "/p", branch: "main", paths: paths, environment: [:])
        XCTAssertEqual(labels(), ["codex"])
        XCTAssertEqual(bus.activities().first { $0.isLive }?.branch, "main")
    }
}
