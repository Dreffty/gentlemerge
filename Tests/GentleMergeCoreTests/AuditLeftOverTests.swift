import XCTest
@testable import GentleMergeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What the 2026-11-01 audit had left as it was, settled (audit 2026-11-03).

final class SnapshotPruningTests: XCTestCase {
    private var repository: URL!

    override func setUpWithError() throws {
        repository = FileManager.default.temporaryDirectory.appendingPathComponent("snap-prune-\(UUID())")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        git(["init", "-q"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        try Data("hello\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        git(["add", "-A"])
        git(["commit", "-q", "-m", "first"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repository) }

    @discardableResult
    private func git(_ arguments: [String], environment: [String: String]? = nil) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repository, environment: environment, timeout: 30)
    }

    /// A restore point dated `n` seconds into 2020, so the order is certain.
    private func oldSnapshot(_ n: Int) -> String {
        let date = "\(1_580_000_000 + n) +0000"
        let commit = git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "gentlemerge snapshot: old \(n)"],
                         environment: ["GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "old-\(n)"
        git(["update-ref", "refs/gentlemerge/snapshots/\(id)", commit])
        return id
    }

    func testTakingASnapshotKeepsOnlyTheNewestThirty() throws {
        let ids = (0..<30).map(oldSnapshot)
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let new = try snapshot.create(label: "new")

        let listed = Set(snapshot.list().map(\.id))
        XCTAssertEqual(listed.count, 30)
        XCTAssertTrue(listed.contains(new.id))
        XCTAssertFalse(listed.contains(ids[0]), "the oldest goes")
        XCTAssertTrue(listed.contains(ids[1]))
    }

    func testARestoreNeverPrunesTheSnapshotItRestores() throws {
        let ids = (0..<30).map(oldSnapshot)
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let oldest = try XCTUnwrap(snapshot.list().first { $0.id == ids[0] })

        _ = try snapshot.restore(oldest)

        let listed = snapshot.list()
        XCTAssertTrue(listed.contains { $0.id == oldest.id }, "the restored point vanished during its own restore")
        XCTAssertTrue(listed.contains { $0.label.hasPrefix("before restoring") })
    }
}

final class GluedPasswordTests: XCTestCase {
    private func gone(_ text: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = Redactor.scrub(text)
        XCTAssertFalse(result.text.contains(needle), "survived: \(result.text)", file: file, line: line)
    }

    private func kept(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = Redactor.scrub(text)
        XCTAssertEqual(result.text, text, file: file, line: line)
    }

    func testAPasswordGluedToMinusPIsRedactedOnTheProgramsThatMeanIt() {
        gone("mysql -u root -phunter2hunter2 -h db", "hunter2hunter2")
        gone("mysqldump -uroot -p'hunter2 two' app > dump.sql", "hunter2 two")
        gone("mariadb -h db -p\"hunter2hunter2\" app", "hunter2hunter2")
        gone("sshpass -p hunter2hunter2 ssh deploy@host", "hunter2hunter2")
        gone("sshpass -phunter2hunter2 rsync -a . host:", "hunter2hunter2")
    }

    func testMinusPEverywhereElseIsLeftAlone() {
        kept("mkdir -p build/out")
        kept("ssh -p 2222 deploy@host")
        kept("git add -p && mysql -u root")
        kept("mysql -u root -p")
        kept("mysql -u root -p -h db")
        kept("mysql -h db -P3306 -u app")
        kept("mysql -u root -p\"$MYSQL_PASSWORD\" app")
        kept("mysql -e 'select 1'; mkdir -p out")
        kept("sshpass -f ~/.pw ssh host")
    }
}

final class CaseFoldedClaimTests: XCTestCase {
    func testAClaimCoversAPathSpelledInAnotherCaseOnAMac() {
        #if os(macOS)
        XCTAssertTrue(Glob.matches("Sources/Bus/**", "sources/bus/x.swift"))
        XCTAssertTrue(Glob.matches("README.md", "readme.md"))
        XCTAssertTrue(Glob.matches("/Users/dev/App/Lib/**", "lib/store.swift"))
        XCTAssertTrue(Glob.mayOverlap("Lib/**", "lib/store/*"))
        #else
        XCTAssertFalse(Glob.matches("README.md", "readme.md"), "Linux keeps case")
        #endif
        XCTAssertFalse(Glob.matches("Sources/Bus/**", "Sources/Busy/x.swift"))
    }

    func testTheGateSeesAClaimInAnotherCase() throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("case-claims-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        let claims = PathClaims(paths: paths)
        try claims.claim(pattern: "Sources/Bus/**", label: "claude", project: "/p", intent: nil)
        XCTAssertEqual(claims.conflicts(path: "sources/bus/Redactor.swift", label: "codex", project: "/p").count, 1)
        XCTAssertThrowsError(try claims.claim(pattern: "sources/bus/*", label: "codex", project: "/p", intent: nil))
        #endif
    }
}

final class SettingsFileKeptTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var installer: HookInstaller!

    /// Four-space indent, keys out of order, a compact object: nothing Foundation
    /// would ever write.
    private let original = """
    {
        "model": "opus",
        "permissions": {"allow": ["Bash(ls)", "Read(/a/b)"]},
        "env": { "A" : "1" }
    }

    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-kept-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = Paths(home: root.appendingPathComponent("home"),
                      claudeSettings: root.appendingPathComponent("settings.json"),
                      codexConfig: root.appendingPathComponent("config.toml"))
        installer = HookInstaller(paths: paths)
        try Data(original.utf8).write(to: paths.claudeSettings)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func text() throws -> String { try String(contentsOf: paths.claudeSettings, encoding: .utf8) }
    private func backups() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path)) ?? []).count }

    func testInstallTouchesOnlyHooksAndUninstallGivesTheFileBack() throws {
        XCTAssertTrue(try installer.installClaudeCode(plan: .init()).changed)
        let installed = try text()
        let untouched = String(original.dropLast("\n}\n".count))
        XCTAssertTrue(installed.hasPrefix(untouched), installed)
        XCTAssertTrue(installed.contains(",\n    \"hooks\": {\n        \""), "the file's own indent: \(installed)")
        XCTAssertFalse(installed.dropFirst(untouched.count).contains("\" : "), "Claude Code's spacing, not Foundation's")
        XCTAssertNotNil(try installer.readJSONObject(at: paths.claudeSettings)["hooks"])

        XCTAssertTrue(try installer.uninstallClaudeCode().changed)
        XCTAssertEqual(try text(), original)
    }

    func testInstallingTwiceWritesNothingTheSecondTime() throws {
        try installer.installClaudeCode(plan: .init())
        let first = try text(), backupsAfterFirst = backups()

        let again = try installer.installClaudeCode(plan: .init())
        XCTAssertFalse(again.changed)
        XCTAssertNil(again.backup)
        XCTAssertEqual(try text(), first)
        XCTAssertEqual(backups(), backupsAfterFirst)
    }

    func testANewFileIsWrittenInClaudeCodesStyle() throws {
        try FileManager.default.removeItem(at: paths.claudeSettings)
        try installer.installClaudeCode(plan: .init())
        let written = try text()
        XCTAssertTrue(written.hasPrefix("{\n  \"hooks\": {\n    \""), written)
        XCTAssertFalse(written.contains("\" : "))
    }

    func testTheSpliceRefusesWhatItCannotReadForCertain() {
        XCTAssertNil(JSONSplice.setting("hooks", to: [:], in: "[1, 2]"))
        XCTAssertNil(JSONSplice.setting("hooks", to: [:], in: #"{"hooks": 1, "hooks": 2}"#))
        XCTAssertNil(JSONSplice.setting("hooks", to: [:], in: #"{"a": 1} trailing"#))
        XCTAssertNil(JSONSplice.setting("hooks", to: [:], in: #"{"a": "unterminated}"#))
    }

    func testTheSpliceRemovesAKeyWhereverItSits() {
        XCTAssertEqual(JSONSplice.setting("b", to: nil, in: "{\n  \"a\": 1,\n  \"b\": [2, {\"c\": \"}\"}],\n  \"d\": 3\n}"),
                       "{\n  \"a\": 1,\n  \"d\": 3\n}")
        XCTAssertEqual(JSONSplice.setting("b", to: nil, in: "{\n  \"a\": 1,\n  \"b\": 2\n}"), "{\n  \"a\": 1\n}")
        XCTAssertEqual(JSONSplice.setting("b", to: nil, in: "{\n  \"b\": 2\n}\n"), "{}\n")
        XCTAssertEqual(JSONSplice.setting("b", to: nil, in: "{\"a\": 1}"), "{\"a\": 1}")
        XCTAssertEqual(JSONSplice.setting("b", to: 5, in: "{}"), "{\n  \"b\": 5\n}")
        XCTAssertEqual(JSONSplice.setting("say \"hi\"", to: true, in: "{\"say \\\"hi\\\"\": false}"), "{\"say \\\"hi\\\"\": true}")
    }
}

final class WindowsLineEndingTests: XCTestCase {
    private let sample = """
    # p — agent handoff

    ## Open tasks

    - [ ] uno · added 2026-11-03 · by claude
    - [ ] dos · added 2026-11-03 · by codex

    ## Notes

    Una nota.
    """

    func testAHandoffSavedWithCRLFReadsLikeTheSameFileWithLF() {
        let lf = HandoffMarkdown.parse(sample, projectPath: "/p")
        let crlf = HandoffMarkdown.parse(sample.replacingOccurrences(of: "\n", with: "\r\n"), projectPath: "/p")
        XCTAssertEqual(crlf.tasks.map(\.text), ["uno", "dos"])
        XCTAssertEqual(crlf, lf)
        XCTAssertFalse(HandoffMarkdown.render(crlf).contains("\r"))
    }

    func testThePointerKeepsTheInstructionFilesLineEndings() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("crlf-pointer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Reglas\r\nlinea dos\r\n".utf8).write(to: project.appendingPathComponent("CLAUDE.md"))
        try Data("plain\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))

        try ProjectRegistry.initialize(projectPath: project.path)

        let claude = try Data(contentsOf: project.appendingPathComponent("CLAUDE.md"))
        let bare = zip(claude, [UInt8(0)] + claude).filter { $0.0 == 0x0A && $0.1 != 0x0D }.count
        XCTAssertEqual(bare, 0, "a bare \\n in a CRLF file")
        XCTAssertTrue(String(decoding: claude, as: UTF8.self).hasPrefix("Reglas\r\nlinea dos\r\n\r\n"))
        let agents = try Data(contentsOf: project.appendingPathComponent("AGENTS.md"))
        XCTAssertFalse(agents.contains(0x0D), "an LF file stays LF")
    }
}

final class PidAfterRestartTests: XCTestCase {
    private let me = Int(getpid())

    func testOurOwnStartIsKnownAndInThePast() throws {
        let started = try XCTUnwrap(Liveness.startTime(of: getpid()))
        XCTAssertLessThanOrEqual(started.timeIntervalSinceNow, 1)
        XCTAssertGreaterThan(started.timeIntervalSinceNow, -24 * 3600)
    }

    func testAPidSeenBeforeItsProcessStartedBelongsToSomebodyElse() throws {
        let started = try XCTUnwrap(Liveness.startTime(of: getpid()))
        XCTAssertEqual(Liveness.isProcessAlive(me), true)
        XCTAssertEqual(Liveness.isProcessAlive(me, seenAt: Date()), true)
        XCTAssertEqual(Liveness.isProcessAlive(me, seenAt: started), true)
        XCTAssertEqual(Liveness.isProcessAlive(me, seenAt: started.addingTimeInterval(-3600)), false,
                       "a mark written an hour before this process existed is a dead session's")
    }

    func testADeadSessionsClaimIsReapedEvenWhenItsPidCameBack() throws {
        let started = try XCTUnwrap(Liveness.startTime(of: getpid()))
        let now = Date()
        let claim = PathClaim(label: "claude", projectPath: "/p", pattern: "lib/**", intent: nil,
                              since: now, expires: now.addingTimeInterval(600), implicit: false)
        // Written before the restart, and the restart gave its pid to this test.
        let mark = Presence.PresenceMark(label: "claude", projectPath: "/p", branch: nil,
                                         updatedAt: started.addingTimeInterval(-3600),
                                         pid: me, task: nil, capabilities: [])
        let (live, reaped) = PathClaims.reap([claim], presence: [mark],
                                             isPIDAlive: { Liveness.isProcessAlive($0, seenAt: $1) }, now: now)
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(reaped.count, 1)
    }
}

/// The per-turn briefing without the app (Linux, or the app quit).
final class SessionContextDrainTests: XCTestCase {
    func testATurnSeesWhatTheOthersStartedWithNoAppRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-drain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "init", "-q", "-b", "main"], in: repo).status, 0)
        let paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()

        let payload: JSONValue = .object([
            "session_id": .string("cl-1"), "cwd": .string(repo.path),
            "hook_event_name": .string("UserPromptSubmit"), "prompt": .string("escribiendo los tests del radar"),
        ])
        try SpoolStore(paths: paths).enqueue(SpoolEnvelope(
            id: UUID().uuidString, provider: .claudeCode, receivedAt: Date(), cwd: repo.path,
            pid: Int(getpid()), payload: payload))

        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let out = Shell.run(binary, ["session-context", "--provider", "codex", "--mode", "full", "--project", repo.path],
                            in: repo, environment: ["GENTLEMERGE_HOME": paths.home.path, "GENTLEMERGE_LABEL": "codex"],
                            timeout: 60)
        XCTAssertEqual(SpoolStore(paths: paths).pendingCount(), 0, "the spool was not drained")
        XCTAssertTrue(out.stdout.contains("escribiendo los tests del radar"), out.stdout + out.stderr)
    }
}
