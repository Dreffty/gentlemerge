import XCTest
@testable import GentleMergeCore

/// What gets past the gate cannot be stopped, but it can be counted.
///
/// `pre-commit` and `pre-merge-commit` only run for a plain commit and a true merge.
/// `git commit --no-verify`, `cherry-pick`, `merge --ff-only` and `rebase` put a file
/// somebody else holds into the branch and nobody heard about it. Real repository,
/// real hooks, real git.
final class GateBypassTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var repo: URL!
    private var binary: String!
    private var paths: Paths { Paths(home: home) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-bypass-\(UUID())")
        home = root.appendingPathComponent("home")
        repo = root.appendingPathComponent("repo")
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)

        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"],
                          ["config", "user.name", "t"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(git(arguments).status, 0)
        }
        try write("README.md")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "base"]).status, 0)

        // A branch with work on the path hermes is about to claim, made before the
        // claim and before the gate: what it carries is somebody's earlier work.
        XCTAssertEqual(git(["checkout", "-qb", "side"]).status, 0)
        try write("src/claimed.txt", "side\n")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "side touches src"]).status, 0)
        XCTAssertEqual(git(["checkout", "-q", "main"]).status, 0)

        let installed = try GitHookInstaller(paths: paths).install(repo: repo)
        XCTAssertTrue(installed.hasPrefix("installed"), installed)

        let claim = Shell.run(binary, ["claim", "--paths", "src/**", "--project", repo.path], in: repo,
                              environment: ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "hermes"])
        XCTAssertEqual(claim.status, 0, claim.text)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: [String], label: String = "codex", extra: [String: String] = [:],
                     in directory: URL? = nil) -> Shell.Output {
        var environment = ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_BIN": binary!, "GENTLEMERGE_LABEL": label,
                           "GENTLEMERGE_SKIP": "", "GIT_EDITOR": "true"]
        for (key, value) in extra { environment[key] = value }
        return Shell.run("/usr/bin/env", ["git"] + arguments, in: directory ?? repo, environment: environment, timeout: 60)
    }

    private func write(_ path: String, _ contents: String = "x\n") throws {
        let file = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    /// `main` moves on, so what comes in afterwards is not a fast-forward.
    private func advanceMain() throws {
        try write("other.txt")
        XCTAssertEqual(git(["add", "other.txt"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "main moves on"]).status, 0)
    }

    private var told: [AgentMessage] {
        AgentBus(paths: paths).messages().filter { $0.effectiveKind == .urgent }
    }

    private func ledgerCount(_ title: String) -> Int {
        Ledger(url: paths.ledger).recent(limit: 200).filter { $0.title == title }.count
    }

    private func assertToldOnce(mentioning how: String, file: StaticString = #filePath, line: UInt = #line) {
        let notes = told
        XCTAssertEqual(notes.count, 1, "wanted one urgent note, got: \(notes.map(\.text))", file: file, line: line)
        guard let note = notes.first else { return }
        XCTAssertTrue(note.text.contains("src/claimed.txt"), note.text, file: file, line: line)
        XCTAssertTrue(note.text.contains("hermes"), "it should name who holds it: \(note.text)", file: file, line: line)
        XCTAssertTrue(note.text.contains(how), "it should say how it got in (\(how)): \(note.text)", file: file, line: line)
        XCTAssertEqual(note.from, "codex", file: file, line: line)
        XCTAssertEqual(ledgerCount("gate.bypassed"), 1, file: file, line: line)
    }

    // MARK: - Each way round

    func testCommitNoVerifyIsCounted() throws {
        try write("src/claimed.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)

        XCTAssertNotEqual(git(["commit", "-qm", "blocked"]).status, 0, "the plain commit is still the gate's to stop")
        XCTAssertEqual(told.count, 0)

        let commit = git(["commit", "--no-verify", "-qm", "round the gate"])
        XCTAssertEqual(commit.status, 0, commit.text)
        assertToldOnce(mentioning: "--no-verify")
        XCTAssertTrue(commit.stderr.contains("src/claimed.txt"), "whoever did it should hear it too: \(commit.text)")
    }

    func testCherryPickIsCounted() throws {
        let pick = git(["cherry-pick", "side"])
        XCTAssertEqual(pick.status, 0, pick.text)
        assertToldOnce(mentioning: "cherry-pick")
    }

    func testFastForwardIsCounted() throws {
        let merge = git(["merge", "--ff-only", "side"])
        XCTAssertEqual(merge.status, 0, merge.text)
        assertToldOnce(mentioning: "merge")
    }

    func testRebaseIsCounted() throws {
        try advanceMain()
        XCTAssertEqual(git(["checkout", "-q", "side"]).status, 0)
        let rebase = git(["rebase", "main"])
        XCTAssertEqual(rebase.status, 0, rebase.text)
        assertToldOnce(mentioning: "rebase")
    }

    func testMergeNoVerifyIsCounted() throws {
        try advanceMain()
        XCTAssertNotEqual(git(["merge", "--no-ff", "side", "-m", "blocked"]).status, 0, "still the gate's to stop")
        XCTAssertEqual(git(["merge", "--abort"]).status, 0)
        XCTAssertEqual(told.count, 0)

        let merge = git(["merge", "--no-ff", "--no-verify", "side", "-m", "round the gate"])
        XCTAssertEqual(merge.status, 0, merge.text)
        assertToldOnce(mentioning: "merge")
    }

    func testRevertIsCounted() throws {
        XCTAssertEqual(git(["merge", "--ff-only", "side"]).status, 0)
        let before = told.count
        let revert = git(["revert", "--no-edit", "HEAD"])
        XCTAssertEqual(revert.status, 0, revert.text)
        XCTAssertEqual(told.count, before + 1, told.map(\.text).joined(separator: "\n"))
    }

    // MARK: - And what must stay quiet

    func testAnOrdinaryCommitSaysNothing() throws {
        try write("elsewhere.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "nothing to do with src"]).status, 0)
        XCTAssertEqual(told.count, 0)
        XCTAssertEqual(ledgerCount("gate.bypassed"), 0)
    }

    func testAnUnclaimedCommitWithNoVerifySaysNothing() throws {
        try write("elsewhere.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "--no-verify", "-qm", "harmless"]).status, 0)
        XCTAssertEqual(told.count, 0)
    }

    func testYourOwnClaimIsNotAnInvasion() throws {
        try write("src/claimed.txt")
        XCTAssertEqual(git(["add", "-A"], label: "hermes").status, 0)
        XCTAssertEqual(git(["commit", "--no-verify", "-qm", "mine"], label: "hermes").status, 0)
        XCTAssertEqual(told.count, 0)
    }

    /// An amend runs post-commit and post-rewrite, and only what it changed entered.
    func testAnAmendIsCountedOnceAndOnlyForWhatItChanged() throws {
        try write("src/claimed.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "--no-verify", "-qm", "first"]).status, 0)
        XCTAssertEqual(told.count, 1)

        XCTAssertEqual(git(["commit", "--amend", "--no-verify", "-qm", "only the message"]).status, 0)
        XCTAssertEqual(told.count, 1, "an amend that touched no file put nothing new in: \(told.map(\.text))")

        try write("src/second.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "--amend", "--no-verify", "-qm", "and a file"]).status, 0)
        XCTAssertEqual(told.count, 2)
        XCTAssertTrue(told.contains { $0.text.contains("src/second.txt") && !$0.text.contains("src/claimed.txt") },
                      "the second note should name only what the amend added: \(told.map(\.text))")
    }

    /// The human way out was already published by the gate. Twice would be noise.
    func testAHumanSkipIsNotToldTwice() throws {
        try write("src/claimed.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        let commit = git(["commit", "-qm", "with the hatch"], extra: ["GENTLEMERGE_SKIP": "1"])
        XCTAssertEqual(commit.status, 0, commit.text)
        XCTAssertEqual(AgentBus(paths: paths).messages().filter { $0.text.contains("human override") }.count, 1)
        XCTAssertEqual(ledgerCount("gate.bypassed"), 0)
    }

    /// But the hatch does not silence a path the gate never saw.
    func testAHumanSkipOnACherryPickIsStillPublished() throws {
        let pick = git(["cherry-pick", "side"], extra: ["GENTLEMERGE_SKIP": "1"])
        XCTAssertEqual(pick.status, 0, pick.text)
        XCTAssertEqual(ledgerCount("gate.bypassed"), 1)
    }

    /// A squash has not entered yet: it becomes a commit, and that commit meets the gate.
    func testASquashWaitsForItsCommit() throws {
        XCTAssertEqual(git(["merge", "--squash", "side"]).status, 0)
        XCTAssertEqual(told.count, 0)
        XCTAssertNotEqual(git(["commit", "-qm", "squashed"]).status, 0)
    }

    /// Bookkeeping can never get in the way of the commit it is counting.
    func testABrokenHomeNeverStopsAnything() throws {
        try write("src/claimed.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        let brokenHome = root.appendingPathComponent("a-file-not-a-home")
        try Data("x".utf8).write(to: brokenHome)
        let commit = git(["commit", "--no-verify", "-qm", "still lands"], extra: ["GENTLEMERGE_HOME": brokenHome.path])
        XCTAssertEqual(commit.status, 0, commit.text)
    }

    func testALinkedWorktreeIsJudgedByItsOwnHead() throws {
        let worktree = root.appendingPathComponent("wt")
        XCTAssertEqual(git(["worktree", "add", "-q", "-b", "agent/codex", worktree.path]).status, 0)
        try Data("x\n".utf8).write(to: worktree.appendingPathComponent("src-free.txt"))
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: worktree.appendingPathComponent("src/claimed.txt"))
        XCTAssertEqual(git(["add", "-A"], in: worktree).status, 0)

        let commit = git(["commit", "--no-verify", "-qm", "from the worktree"], in: worktree)
        XCTAssertEqual(commit.status, 0, commit.text)
        assertToldOnce(mentioning: "--no-verify")
    }

    // MARK: - The hooks themselves

    func testTheHooksChainWhatWasThereAndGiveItsInputBack() throws {
        let hooks = repo.appendingPathComponent(".git/hooks")
        try GitHookInstaller(paths: paths).uninstall(repo: repo).isEmpty ? XCTFail("uninstall said nothing") : ()
        let seen = root.appendingPathComponent("seen.txt")
        for name in ["post-merge", "post-rewrite"] {
            let script = "#!/bin/sh\necho \"\(name) [$*] $(cat)\" >> '\(seen.path)'\n"
            try Data(script.utf8).write(to: hooks.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appendingPathComponent(name).path)
        }
        _ = try GitHookInstaller(paths: paths).install(repo: repo)

        XCTAssertEqual(git(["merge", "--ff-only", "side"]).status, 0)
        XCTAssertEqual(git(["checkout", "-q", "-b", "other", "main~1"]).status, 0)
        try write("other.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "other"]).status, 0)
        let old = git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(git(["rebase", "main"]).status, 0)

        let log = try String(contentsOf: seen, encoding: .utf8)
        XCTAssertTrue(log.contains("post-merge [0]"), log)
        XCTAssertTrue(log.contains("post-rewrite [rebase] \(old) "), "the chained hook lost its stdin: \(log)")

        XCTAssertEqual(try GitHookInstaller(paths: paths).uninstall(repo: repo), "removed")
        for name in ["post-merge", "post-rewrite"] {
            let restored = try String(contentsOf: hooks.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(restored.contains(seen.path), "uninstall did not put \(name) back")
        }
    }

    func testUninstallTakesEveryHookWithIt() throws {
        XCTAssertEqual(try GitHookInstaller(paths: paths).uninstall(repo: repo), "removed")
        let hooks = repo.appendingPathComponent(".git/hooks")
        for name in ["pre-commit", "pre-merge-commit", "post-commit", "post-merge", "post-rewrite"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.appendingPathComponent(name).path), name)
        }
    }

    func testDoctorNoticesAnOldInstallThatCountsNothing() throws {
        let hooks = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.removeItem(at: hooks.appendingPathComponent("post-rewrite"))
        let check = Doctor.gitHooks(paths: paths, repo: repo)
        XCTAssertEqual(check.level, .warn, check.detail)
        XCTAssertTrue(check.detail.contains("post-rewrite"), check.detail)
    }

    func testStatsCountsWhatGotPast() throws {
        try write("src/claimed.txt")
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "--no-verify", "-qm", "round"]).status, 0)
        XCTAssertTrue(Stats.valueLine(paths: paths).contains("1 commit(s) went round the gate"), Stats.valueLine(paths: paths))
    }
}
