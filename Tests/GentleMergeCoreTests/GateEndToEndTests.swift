import XCTest
@testable import GentleMergeCore

/// The gate as a real install gets it: the hook the standard home writes, run
/// by a real `git commit`, with nothing overriding where it looks.
///
/// Every hook test before these set `GENTLEMERGE_BIN`, which the hook consults
/// before its own default — so the default never had to find anything, and a
/// default that could not went unnoticed. It single-quoted `$HOME`, looked for
/// a directory literally named `$HOME`, printed "gate binary not found … this
/// commit is NOT checked" and exited 0: every commit in every repository
/// installed with the standard home passed unchecked, and `doctor` reported the
/// gate live (audit 2026-10-26).
final class GateEndToEndTests: XCTestCase {
    private var root: URL!
    /// What `$HOME` is for the person committing.
    private var userHome: URL!
    /// `GENTLEMERGE_HOME`, laid out where the standard home keeps it.
    private var stateHome: URL!
    private var repo: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-e2e-\(UUID())")
        userHome = root.appendingPathComponent("user")
        stateHome = userHome.appendingPathComponent(".gentlemerge")
        repo = root.appendingPathComponent("repo")
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path

        // The gate binary exactly where `$HOME/.gentlemerge/bin/gentlemerge` points.
        let bin = stateHome.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("gentlemerge"), withDestinationURL: URL(fileURLWithPath: binary))

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"],
                     ["config", "user.name", "Test"]] {
            XCTAssertTrue(git(args).status == 0)
        }
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "base"]).status, 0)

        // Somebody else holds a live claim on what is about to be committed.
        let claim = Shell.run(binary, ["claim", "--paths", "src/**", "--project", repo.path], in: repo,
            environment: ["GENTLEMERGE_HOME": stateHome.path, "GENTLEMERGE_LABEL": "claude"], timeout: 60)
        XCTAssertTrue(claim.succeeded, claim.stderr)

        // The hook exactly as the standard home writes it.
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try GitHookInstaller.script().write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A process environment for a commit nobody configured: the committer's
    /// own home, and `GENTLEMERGE_BIN` and the escape hatch truly absent — not
    /// set to empty, which would only prove the `:-` expansion.
    /// `label: nil` leaves the committer with no `GENTLEMERGE_LABEL` at all.
    private func environment(home: String? = nil, label: String? = "hermes",
                             extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["GENTLEMERGE_BIN", "GENTLEMERGE_SKIP", "GENTLEMERGE_LABEL", "GENTLEMERGE_NAME"] {
            env.removeValue(forKey: key)
        }
        env["HOME"] = home ?? userHome.path
        env["GENTLEMERGE_HOME"] = stateHome.path
        if let label { env["GENTLEMERGE_LABEL"] = label }
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// `Shell.run` merges into the inherited environment and so cannot remove a
    /// variable; this runs with exactly the one given.
    private func run(_ executable: String, _ arguments: [String], env: [String: String],
                     in directory: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    private func git(_ arguments: [String]) -> (status: Int32, output: String) {
        run("/usr/bin/env", ["git"] + arguments, env: environment(), in: repo)
    }

    private var head: String { git(["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines) }

    func testTheDefaultHookFindsTheGateAndBlocksAnInvasion() throws {
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("src/app.js"))
        git(["add", "-A"])
        let before = head

        let commit = git(["commit", "-qm", "hermes edits claude's src"])

        XCTAssertFalse(commit.output.contains("gate binary not found"),
                       "the default hook could not find a gate that is right where it points: \(commit.output)")
        XCTAssertNotEqual(commit.status, 0, "the invasion was committed: \(commit.output)")
        XCTAssertEqual(head, before, "HEAD moved: the commit landed")
    }

    // MARK: - Several agents in one checkout, with no worktree label

    private func stageClaimedFile() throws {
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: repo.appendingPathComponent("src/app.js"))
        git(["add", "-A"])
    }

    /// The layout this tool is actually run in: no labelled worktree, each
    /// agent saying who it is through `GENTLEMERGE_LABEL`. Before, the gate
    /// read only the worktree label, so here every claim was somebody else's —
    /// the agent whose own edit claimed `src/` could not commit `src/`.
    func testAnAgentCommitsWhatItsOwnEditClaimed() throws {
        try stageClaimedFile()
        let before = head

        let commit = run("/usr/bin/env", ["git", "commit", "-qm", "claude commits its own work"],
                         env: environment(label: "claude"), in: repo)

        XCTAssertEqual(commit.status, 0, "an agent was blocked by its own claim: \(commit.output)")
        XCTAssertNotEqual(head, before)
    }

    /// The commit releases what it landed, under the identity it was judged by.
    func testTheCommitReleasesTheCommittersOwnClaim() throws {
        let postCommit = repo.appendingPathComponent(".git/hooks/post-commit")
        try GitHookInstaller.postCommitScript().write(to: postCommit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: postCommit.path)
        try stageClaimedFile()

        let commit = run("/usr/bin/env", ["git", "commit", "-qm", "claude lands src"],
                         env: environment(label: "claude"), in: repo)
        XCTAssertEqual(commit.status, 0, commit.output)

        let live = PathClaims(paths: Paths(home: stateHome)).load().filter { $0.isLive(at: Date()) }
        XCTAssertTrue(live.isEmpty, "the claim outlived the commit that landed it: \(live)")
    }

    /// Fail closed is unchanged: nobody to judge by, so every live claim blocks.
    func testWithNoIdentityEveryLiveClaimStillBlocks() throws {
        try stageClaimedFile()
        let before = head

        let commit = run("/usr/bin/env", ["git", "commit", "-qm", "anonymous"],
                         env: environment(label: nil), in: repo)

        XCTAssertNotEqual(commit.status, 0, commit.output)
        XCTAssertEqual(head, before)
    }

    /// 2026-10-07 stays fixed: an unverified name is a way to spell yourself,
    /// never proof — it must not let a commit pass as the claim's holder.
    func testAnUnverifiedNameIsNotAnIdentityForTheGate() throws {
        try stageClaimedFile()
        let before = head

        let commit = run("/usr/bin/env", ["git", "commit", "-qm", "borrowed name"],
                         env: environment(label: nil, extra: ["GENTLEMERGE_NAME": "claude"]), in: repo)

        XCTAssertNotEqual(commit.status, 0, "an unverified name passed as the holder: \(commit.output)")
        XCTAssertEqual(head, before)
    }

    /// The control: the same hook lets through what nobody claimed, so a block
    /// above means the gate judged it — not that the hook is merely broken.
    func testTheDefaultHookLetsAnUnclaimedCommitThrough() throws {
        try Data("docs\n".utf8).write(to: repo.appendingPathComponent("NOTES.md"))
        git(["add", "-A"])
        let before = head

        let commit = git(["commit", "-qm", "unclaimed"])

        XCTAssertEqual(commit.status, 0, commit.output)
        XCTAssertFalse(commit.output.contains("gate binary not found"), commit.output)
        XCTAssertNotEqual(head, before)
    }

    /// `$HOME` is now expanded when the hook runs, so it must still be only
    /// text: a parameter expansion's result is not scanned again for command
    /// substitution. The 2026-10-07 hardening was about exactly this.
    func testAHomeCarryingCommandSubstitutionIsOnlyText() throws {
        let marker = root.appendingPathComponent("HOOK-PWNED")
        let hostileHome = root.path + "/$(touch HOOK-PWNED)"
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")

        let result = run("/bin/sh", [hook.path], env: environment(home: hostileHome), in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the home executed a command")
        XCTAssertTrue(result.output.contains("$(touch HOOK-PWNED)/.gentlemerge/bin/gentlemerge"),
                      "the home was used as text: \(result.output)")
    }

    /// `doctor` used to model where the hook looks and found the binary there,
    /// while the hook looked somewhere else. It now asks the hook.
    func testDoctorResolvesTheGateTheWayTheHookDoes() throws {
        let env = ["HOME": userHome.path, "GENTLEMERGE_BIN": ""]
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        XCTAssertEqual(Doctor.gateTheHookResolves(hook: hook, environment: env),
                       stateHome.appendingPathComponent("bin/gentlemerge").path)

        // And the line every revision-2 standard-home hook carried resolves to
        // the path that does not exist — which doctor will now say.
        let old = root.appendingPathComponent("old-pre-commit")
        try "#!/bin/sh\nAI_DEFAULT='$HOME/.gentlemerge/bin/gentlemerge'\n"
            .write(to: old, atomically: true, encoding: .utf8)
        let resolved = try XCTUnwrap(Doctor.gateTheHookResolves(hook: old, environment: env))
        XCTAssertEqual(resolved, "$HOME/.gentlemerge/bin/gentlemerge")
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: resolved))
    }
}
