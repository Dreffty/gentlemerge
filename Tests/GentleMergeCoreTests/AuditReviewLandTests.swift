import XCTest
@testable import GentleMergeCore

/// Review, the session baseline and landing: what the 2026-10-26 audit found wrong
/// with them, each against a real repository.
final class ReviewRealRepositoryTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("review-audit-\(UUID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"]); try git(["config", "user.name", "t"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: repo, timeout: 30)
        guard out.succeeded else { throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr]) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, _ name: String) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Paths with spaces and accents were shown quoted (`"\303\261and\303\272.txt"`), a
    /// rename as `"old" => new`, and untracked files with `+0` lines.
    func testPathsWithSpacesAccentsAndRenamesAreReportedAsTheyAre() throws {
        try write((1...5).map(String.init).joined(separator: "\n") + "\n", "ñandú.txt")
        try write("keep\n", "keep.txt")
        try git(["add", "-A"]); try git(["commit", "-qm", "base"])
        let base = try git(["rev-parse", "HEAD"])

        try git(["mv", "ñandú.txt", "emu.txt"])
        try write("a\nb\nc\nd\ne\nextra\n", "emu.txt")
        try write((1...10).map(String.init).joined(separator: "\n") + "\n", "new file.txt")
        try write("x\ny\nz\n", "ñu nuevo.txt")

        let work = WorkInspector.summarize(projectPath: repo.path, baseline: base)
        let byPath = Dictionary(uniqueKeysWithValues: work.changes.map { ($0.path, $0) })

        XCTAssertNil(work.problem)
        XCTAssertEqual(byPath["new file.txt"]?.added, 10, "an untracked file with a space reported \(String(describing: byPath["new file.txt"]?.added)) lines")
        XCTAssertEqual(byPath["ñu nuevo.txt"]?.added, 3, "trailing newline must not count as a line")
        XCTAssertNotNil(byPath["emu.txt"], "the rename's new name, as a plain path: \(work.changes.map(\.path))")
        XCTAssertFalse(work.changes.contains { $0.path.contains("=>") || $0.path.contains("\"") || $0.path.contains("\\303") })
        XCTAssertTrue(byPath["emu.txt"]?.status.hasPrefix("R") == true, "a rename, not a plain modification")
        XCTAssertNil(byPath["keep.txt"])
    }

    func testABaselineThatIsNotACommitIsSaidNotSilentlyIgnored() throws {
        try write("a\n", "a.txt"); try git(["add", "-A"]); try git(["commit", "-qm", "base"])
        try write("b\n", "b.txt"); try git(["add", "-A"]); try git(["commit", "-qm", "two"])
        XCTAssertFalse(WorkInspector.isCommit("deadbeefdeadbeef", in: repo))
        XCTAssertTrue(WorkInspector.isCommit("HEAD", in: repo))

        let work = WorkInspector.summarize(projectPath: repo.path, baseline: "deadbeefdeadbeef")
        XCTAssertNotNil(work.problem)
        let questions = WorkInspector.openQuestions(for: work, checks: [])
        XCTAssertTrue(questions.contains { $0.contains("deadbeefdeadbeef") }, "\(questions)")
    }

    func testOnlyRealTestFilesCountAsTests() {
        for test in ["Tests/FooTests.swift", "src/foo.test.ts", "src/foo.spec.js", "pkg/foo_test.go",
                     "tests/test_foo.py", "FooTests/Bar.swift", "app/__tests__/x.js", "spec/models/user_spec.rb"] {
            XCTAssertTrue(WorkInspector.isTestPath(test), test)
        }
        for notTest in ["Sources/Inspector.swift", "Sources/Respect.swift", "Sources/Spectrum.swift",
                        "lib/latest.dart", "src/contest.py", "docs/specification.md", "Sources/Testimony.swift"] {
            XCTAssertFalse(WorkInspector.isTestPath(notTest), notTest)
        }
    }

    func testThreeSourceFilesWithoutATestStillRaiseTheWarning() {
        let work = WorkSummary(projectPath: "/p", isRepository: true, baseline: "x", baselineIsHead: true, changes: [
            FileChange(path: "Sources/Inspector.swift", status: "M", added: 1, removed: 0),
            FileChange(path: "Sources/Respect.swift", status: "M", added: 1, removed: 0),
            FileChange(path: "Sources/Spectrum.swift", status: "M", added: 1, removed: 0),
        ])
        XCTAssertTrue(WorkInspector.openQuestions(for: work, checks: []).contains { $0.contains("no test file") })
    }

    func testCountingLinesTheWayAnEditorDoes() throws {
        try write("one\ntwo\n", "two.txt"); try write("one\ntwo", "two-no-newline.txt"); try write("", "empty.txt")
        XCTAssertEqual(WorkInspector.countLines(at: repo.appendingPathComponent("two.txt")), 2)
        XCTAssertEqual(WorkInspector.countLines(at: repo.appendingPathComponent("two-no-newline.txt")), 2)
        XCTAssertEqual(WorkInspector.countLines(at: repo.appendingPathComponent("empty.txt")), 0)
    }

    func testTheNpmInitPlaceholderTestScriptIsNotACheck() throws {
        try write(#"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1","build":"echo built"}}"#, "package.json")
        let names = ProjectChecks.checks(for: repo).map(\.name)
        XCTAssertTrue(names.contains("npm run build"))
        XCTAssertFalse(names.contains("npm test"), "\(names)")
        try write(#"{"scripts":{"test":"jest"}}"#, "package.json")
        XCTAssertTrue(ProjectChecks.checks(for: repo).map(\.name).contains("npm test"))
    }
}

final class SessionBaselineTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID())")
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"]); try git(["config", "user.name", "t"])
        try commit("a.txt", "one")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: repo, timeout: 30)
        guard out.succeeded else { throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr]) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func commit(_ name: String, _ text: String) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "c \(name) \(text)"])
    }

    /// The hook knows where the project stood at SessionStart; the drain that ingests the
    /// event runs later and used to take HEAD *then*, dropping every commit in between.
    func testTheBaselineIsWhereTheProjectStoodWhenTheSessionBegan() throws {
        let url = root.appendingPathComponent("sessions.json")
        let atStart = try git(["rev-parse", "HEAD"])

        var hook = SessionRegistry(url: url)
        hook.recordBaseline(id: "s1", provider: .claudeCode, projectPath: repo.path, at: Date(), label: "claude")

        try commit("b.txt", "another agent's commit")           // lands before the drain
        var drain = SessionRegistry(url: url)
        drain.started(id: "s1", provider: .claudeCode, projectPath: repo.path, at: Date())

        XCTAssertEqual(SessionRegistry(url: url)["s1"]?.baselineCommit, atStart)
        XCTAssertEqual(SessionRegistry(url: url)["s1"]?.label, "claude")
    }

    func testWithoutTheHookTheDrainStillRecordsSomething() throws {
        let url = root.appendingPathComponent("sessions.json")
        var drain = SessionRegistry(url: url)
        drain.started(id: "s2", provider: .claudeCode, projectPath: repo.path, at: Date())
        XCTAssertNotNil(SessionRegistry(url: url)["s2"]?.baselineCommit)
    }

    func testARecordedBaselineIsNeverOverwrittenByASecondCall() throws {
        let url = root.appendingPathComponent("sessions.json")
        let first = try git(["rev-parse", "HEAD"])
        var registry = SessionRegistry(url: url)
        registry.recordBaseline(id: "s3", provider: .claudeCode, projectPath: repo.path, at: Date())
        try commit("c.txt", "later")
        registry.recordBaseline(id: "s3", provider: .claudeCode, projectPath: repo.path, at: Date())
        XCTAssertEqual(SessionRegistry(url: url)["s3"]?.baselineCommit, first)
    }

    /// Two Claude sessions in one project: "the one live session of this provider" is
    /// ambiguous, but the session's own exported id is not.
    func testTheSessionNamesItselfThroughItsEnvironment() throws {
        let paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        var registry = SessionRegistry(url: paths.sessions)
        registry.recordBaseline(id: "mine-123", provider: .claudeCode, projectPath: repo.path, at: Date())
        let previous = getenv(Presence.sessionEnvironmentKey).map { String(cString: $0) }
        setenv(Presence.sessionEnvironmentKey, "mine-123", 1)
        defer {
            if let previous { setenv(Presence.sessionEnvironmentKey, previous, 1) } else { unsetenv(Presence.sessionEnvironmentKey) }
        }
        XCTAssertEqual(TaskClaims(paths: paths).currentSessionID(for: "claude", in: repo.path), "mine-123")
    }
}

final class LandingTargetCheckoutTests: XCTestCase {
    private var root: URL!
    private var main: URL!
    private var worktree: URL!
    private var paths: Paths { Paths(home: root.appendingPathComponent("home")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("land-target-\(UUID())")
        main = root.appendingPathComponent("main-checkout")
        worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: main)
        try git(["config", "user.email", "t@example.com"], in: main); try git(["config", "user.name", "t"], in: main)
        try write("base\n", "shared.txt", in: main); try write("other\n", "other.txt", in: main)
        try git(["add", "-A"], in: main); try git(["commit", "-qm", "base"], in: main)
        try git(["worktree", "add", "-q", worktree.path, "-b", "agent/x"], in: main)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: dir, timeout: 30)
        guard out.succeeded else { throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr]) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func land() throws -> Landing.Report {
        try Landing.land(branch: nil, into: nil, repo: worktree, label: "x", verified: true, paths: paths,
                         skipChecks: true, dryRun: false, fast: false, progress: { _ in })
    }

    /// The tool keeps rewriting a tracked file (HANDOFF.md) in the checkout that has `main`
    /// open; a branch that also changed it could not fast-forward, and found out only after
    /// the rebase had already rewritten the branch.
    func testALandingThatCannotFastForwardIsRefusedBeforeTheRebase() throws {
        try write("agent change\n", "shared.txt", in: worktree)
        try git(["add", "-A"], in: worktree); try git(["commit", "-qm", "agent"], in: worktree)
        // main moves on, so a rebase WOULD rewrite the branch
        try write("main moved\n", "other.txt", in: main)
        try git(["add", "-A"], in: main); try git(["commit", "-qm", "main moved"], in: main)
        // …and the main checkout is dirty in the file the branch changes
        try write("uncommitted regeneration\n", "shared.txt", in: main)
        let before = try git(["rev-parse", "agent/x"], in: worktree)

        do {
            _ = try land()
            XCTFail("should have been refused")
        } catch let failure as Landing.Failure {
            guard case .targetCheckoutDirty(_, _, let files) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(files, ["shared.txt"])
            XCTAssertTrue(failure.description.contains("Nothing was rebased"))
        }
        XCTAssertEqual(try git(["rev-parse", "agent/x"], in: worktree), before, "the branch must not have been rebased")
    }

    func testADirtyMainCheckoutInAnotherFileDoesNotStopTheLanding() throws {
        try write("agent change\n", "shared.txt", in: worktree)
        try git(["add", "-A"], in: worktree); try git(["commit", "-qm", "agent"], in: worktree)
        try write("scratch edit\n", "other.txt", in: main)       // dirty, but not a file the branch touches
        let report = try land()
        XCTAssertEqual(report.files, ["shared.txt"])
        XCTAssertEqual(try git(["show", "main:shared.txt"], in: main), "agent change")
    }
}
