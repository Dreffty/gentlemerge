import XCTest
@testable import GentleMergeCore

/// Defects the 2026-10-26 audit reproduced through the real binary: each test
/// here fails against the code as it stood.

// MARK: - The advise hook and the Codex bridge

final class AdviseHookInstallTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var installer: HookInstaller!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-advise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = Paths(
            home: root.appendingPathComponent("home"),
            claudeSettings: root.appendingPathComponent("settings.json"),
            codexConfig: root.appendingPathComponent("config.toml")
        )
        installer = HookInstaller(paths: paths)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func groups(_ event: String) throws -> [[String: Any]] {
        let settings = try installer.readJSONObject(at: paths.claudeSettings)
        return (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    private func commands(_ event: String) throws -> [String] {
        try groups(event).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    /// `install` printed "PreToolUse → advises on claimed paths" and wrote nothing.
    func testInstallActuallyWritesThePreToolUseAdviseHook() throws {
        _ = try installer.installClaudeCode(plan: .init())
        let pre = try groups("PreToolUse")
        XCTAssertEqual(pre.count, 1, "the advise hook must be in settings.json, not just in the install notes")
        XCTAssertEqual(pre.first?["matcher"] as? String, "Edit|MultiEdit|Write|NotebookEdit")
        XCTAssertTrue(try commands("PreToolUse").contains { $0.contains("--mode advise") })
        XCTAssertEqual(installer.claudeCodeStatus()["PreToolUse"], "warns before an edit lands on a claimed path")
    }

    func testReinstallingDoesNotDuplicateIt() throws {
        _ = try installer.installClaudeCode(plan: .init())
        _ = try installer.installClaudeCode(plan: .init())
        XCTAssertEqual(try commands("PreToolUse").filter { $0.contains(HookInstaller.marker) }.count, 1)
    }

    func testAForeignPreToolUseHookSurvivesInstallAndUninstall() throws {
        let original = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/opt/theirs.sh"}]}]}}"#
        try Data(original.utf8).write(to: paths.claudeSettings)
        _ = try installer.installClaudeCode(plan: .init())
        XCTAssertTrue(try commands("PreToolUse").contains("/opt/theirs.sh"))
        XCTAssertTrue(try commands("PreToolUse").contains { $0.contains("--mode advise") })

        _ = try installer.uninstallClaudeCode()
        XCTAssertEqual(try commands("PreToolUse"), ["/opt/theirs.sh"])
    }

    /// The old shape had no matcher at all; it is replaced, never kept next to the new one.
    func testAnOldMatcherlessAdviseEntryIsReplacedNotKept() throws {
        let old = "'\(paths.hookScript.path)' --provider claude-code --mode advise"
        let original = #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"\#(old)"}]}]}}"#
        try Data(original.utf8).write(to: paths.claudeSettings)
        _ = try installer.installClaudeCode(plan: .init())
        let pre = try groups("PreToolUse")
        XCTAssertEqual(pre.count, 1)
        XCTAssertNotNil(pre.first?["matcher"])
    }

    // MARK: Codex

    private func installCodex(original: String) throws -> String {
        let (contents, found) = installer.codexConfigContents(
            original: original, scriptPath: paths.codexNotifyScript.path)
        let previous = installer.codexPreviousNotify(found: found)
        if found.first?.contains(HookInstaller.codexMarker) != true {
            try installer.saveCodexPrevious(found)
        }
        try FileManager.default.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        try Data(installer.codexNotifyScript(chaining: previous).utf8).write(to: paths.codexNotifyScript)
        try Data(contents.utf8).write(to: paths.codexConfig)
        return contents
    }

    /// Installing twice made the bridge call itself first on every Codex event.
    func testInstallingTheCodexBridgeTwiceNeverChainsToItself() throws {
        let first = try installCodex(original: "model = \"x\"\nnotify = [\"/usr/bin/true\", \"turn\"]\n")
        _ = try installCodex(original: first)
        let script = try String(contentsOf: paths.codexNotifyScript, encoding: .utf8)
        XCTAssertFalse(script.contains(paths.codexNotifyScript.path + "\" \"$@\""), "the bridge is calling itself")
        XCTAssertTrue(script.contains("\"/usr/bin/true\" \"turn\" \"$@\""), "the user's real notify program must still be chained")
    }

    func testUninstallingCodexPutsTheUsersNotifyBack() throws {
        _ = try installCodex(original: "model = \"x\"\nnotify = [\"/usr/bin/true\", \"turn\"]\n\n[tbl]\nk = 1\n")
        let result = try installer.uninstallCodex()
        XCTAssertTrue(result.changed)
        let config = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        XCTAssertTrue(config.contains("notify = [\"/usr/bin/true\", \"turn\"]"), config)
        XCTAssertFalse(config.contains(HookInstaller.codexMarker))
        XCTAssertTrue(config.contains("[tbl]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexNotifyScript.path))
    }

    func testUninstallingCodexWithNothingBeforeRemovesTheKey() throws {
        _ = try installCodex(original: "model = \"x\"\n")
        _ = try installer.uninstallCodex()
        let config = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        XCTAssertFalse(config.contains("notify"))
        XCTAssertTrue(config.contains("model = \"x\""))
    }

    func testUninstallingCodexLeavesSomeoneElsesNotifyAlone() throws {
        try Data("notify = [\"/opt/other\"]\n".utf8).write(to: paths.codexConfig)
        let result = try installer.uninstallCodex()
        XCTAssertFalse(result.changed)
        XCTAssertEqual(try String(contentsOf: paths.codexConfig, encoding: .utf8), "notify = [\"/opt/other\"]\n")
    }
}

// MARK: - The escape hatch

final class EscapeHatchTests: XCTestCase {
    func testOnlyAnAffirmativeValueSkips() {
        XCTAssertTrue(EscapeHatch.isActive(["GENTLEMERGE_SKIP": "1"]))
        XCTAssertTrue(EscapeHatch.isActive(["GENTLEMERGE_SKIP": "yes"]))
        for no in ["", "0", "false", "no", "off", " 0 ", "FALSE"] {
            XCTAssertFalse(EscapeHatch.isActive(["GENTLEMERGE_SKIP": no]), "'\(no)' means do not skip")
        }
        XCTAssertFalse(EscapeHatch.isActive([:]))
    }
}

// MARK: - Config files

final class AppConfigRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAMissingFileIsNotAProblem() {
        let result = AppConfig.loadChecked(from: root.appendingPathComponent("config.json"))
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.config, AppConfig())
    }

    func testABrokenFileIsReportedNotSilentlyReplacedByDefaults() throws {
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"claimsPolicy": "deny" "basePort": 4100}"#.utf8).write(to: url)
        let result = AppConfig.loadChecked(from: url)
        XCTAssertNotNil(result.problem)
    }

    func testSavingOverABrokenFileKeepsACopyOfIt() throws {
        let url = root.appendingPathComponent("config.json")
        let broken = #"{"agents": [{"label": "hermes"}], oops"#
        try Data(broken.utf8).write(to: url)
        try AppConfig().save(to: url)
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("config.json.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(aside[0]), encoding: .utf8), broken)
    }

    func testSavingOverAHealthyFileMakesNoCopy() throws {
        let url = root.appendingPathComponent("config.json")
        try AppConfig().save(to: url)
        try AppConfig(basePort: 4000).save(to: url)
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("unreadable") }
        XCTAssertTrue(aside.isEmpty)
    }
}

// MARK: - Text that starts with a dash

final class DashTextArgumentsTests: XCTestCase {
    func testNoteTextThatStartsWithADashIsTextNotAFlag() {
        for text in ["- done: parser", "-1 on this approach", "--no-verify is being used", "-- see above"] {
            let arguments: CommandArguments = ["say", text, "--to", "codex"]
            XCTAssertEqual(arguments.positional, ["say", text], "'\(text)' was dropped as if it were a flag")
        }
    }

    func testRealFlagsAreStillFlags() {
        for flag in ["--urgent", "--no-verify", "-n", "--", "--to-branch", "-h"] {
            XCTAssertTrue(CommandArguments.looksLikeFlag(flag), flag)
        }
        for text in ["-", "-5", "- a", "--- x", "-1 on this", "--no-verify is banned", "---"] {
            XCTAssertFalse(CommandArguments.looksLikeFlag(text), text)
        }
    }

    func testANegativeNumberIsAValueNotAFlag() {
        let arguments: CommandArguments = ["claim", "--ttl", "-5"]
        XCTAssertEqual(arguments.value(after: "--ttl"), "-5")
        XCTAssertEqual(arguments.positional, ["claim"])
    }

    func testAValueThatIsClearlyAFlagIsStillNotAValue() {
        let arguments: CommandArguments = ["say", "x", "--to", "--global"]
        XCTAssertNil(arguments.value(after: "--to"))
    }
}

// MARK: - Through the binary

final class AuditCLITests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-cli-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func run(_ args: [String], extraEnvironment: [String: String] = [:]) -> Shell.Output {
        Shell.run(binary, args, in: root,
                  environment: ["GENTLEMERGE_HOME": home.path].merging(extraEnvironment) { _, new in new },
                  timeout: 60)
    }

    // Arguments that were accepted and then quietly meant something else

    func testANoteToNobodyOrToNoOneIsRefusedInsteadOfGoingToEveryone() {
        for arguments in [["say", "   ", "--global"], ["say", "hola", "--to", ""], ["say", "hola", "--to"],
                          ["say", "hola", "--to-branch", ""], ["say", "hola", "--global", "--to"]] {
            let out = run(arguments)
            XCTAssertEqual(out.status, 64, "\(arguments) was accepted: \(out.stdout)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("messages.jsonl").path),
                       "nothing may have been sent")
        XCTAssertEqual(run(["say", "hola", "--to", "codex", "--global"]).status, 0)
    }

    func testADirectoryThatIsNotThereIsAnErrorNotAFabricatedProject() {
        let nowhere = root.appendingPathComponent("no-such-dir").path
        for arguments in [["say", "hola", "--project", nowhere], ["handoff", nowhere], ["review", nowhere],
                          ["brief", nowhere], ["precommit", nowhere], ["project", "init", nowhere],
                          ["who", "--project", nowhere], ["radar", "--project", nowhere]] {
            let out = run(arguments)
            XCTAssertEqual(out.status, 64, "\(arguments) carried on: \(out.stdout)")
            XCTAssertTrue(out.stderr.contains("no such directory"), out.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("no-such-dir").path))
        XCTAssertEqual(run(["handoff", root.path]).status, 0, "an existing directory still works")
    }

    func testAWatchOnNothingAndARestoreOfNothingSaySo() {
        XCTAssertEqual(run(["watch", "idle", ""]).status, 64)
        XCTAssertEqual(run(["watch", "session-end", "  "]).status, 64)

        let git = Shell.run("/usr/bin/env", ["git", "init", "-q"], in: root)
        XCTAssertTrue(git.succeeded)
        let out = run(["snapshot", "restore", "nonexistent"])
        XCTAssertEqual(out.status, 1)
        XCTAssertTrue(out.stderr.contains("no restore point starts with"), out.stderr)
    }

    // --ttl: a claim that is born expired is a lie

    func testATtlThatIsNotAPositiveNumberOfMinutesIsRefused() {
        for ttl in ["0", "-5", "abc", "99999"] {
            let out = run(["claim", "--paths", "lib/**", "--ttl", ttl])
            XCTAssertEqual(out.status, 64, "--ttl \(ttl) must be refused, got: \(out.stdout)")
        }
        XCTAssertEqual(run(["claims"]).stdout.contains("lib/**"), false, "nothing may have been claimed")
    }

    func testAGoodTtlStillClaims() {
        let out = run(["claim", "--paths", "lib/**", "--ttl", "10"])
        XCTAssertEqual(out.status, 0, out.stderr)
        XCTAssertTrue(run(["claims"]).stdout.contains("lib/**"))
    }

    // notes that start with a dash reach the bus

    func testANoteStartingWithADashIsSent() {
        let out = run(["say", "- fixed the parser", "--global"])
        XCTAssertEqual(out.status, 0, out.stdout + out.stderr)
        XCTAssertTrue(out.stdout.contains("- fixed the parser"))
    }

    // --label with nothing usable after it

    func testLabelWithoutANameIsAnErrorNotASilentSkip() throws {
        let git = Shell.run("/usr/bin/env", ["git", "init", "-q"], in: root)
        XCTAssertTrue(git.succeeded)
        XCTAssertEqual(run(["project", "init", "--label", "--git-hooks"]).status, 64)
    }

    /// A bare `git-hooks` used to install the gate: asking what it does wrote hooks.
    func testGitHooksWithoutAnActionWritesNothing() throws {
        let git = Shell.run("/usr/bin/env", ["git", "init", "-q"], in: root)
        XCTAssertTrue(git.succeeded)
        let hook = root.appendingPathComponent(".git/hooks/pre-commit").path

        for arguments in [["git-hooks"], ["git-hooks", "--project", root.path], ["git-hooks", "instal"]] {
            let out = run(arguments)
            XCTAssertEqual(out.status, 64, "\(arguments): \(out.stdout + out.stderr)")
            XCTAssertTrue(out.stderr.contains("usage: gentlemerge git-hooks install|uninstall"), out.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook))

        XCTAssertEqual(run(["git-hooks", "install"]).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hook), "the explicit form still installs")

        // `doctor` tells people to run it, so `help` has to list it.
        XCTAssertTrue(run(["help"]).stdout.contains("git-hooks install|uninstall"))
    }

    // config.json that cannot be read

    func testAnUnreadableConfigIsReportedAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent("config.json")
        let broken = #"{"claimsPolicy": "deny" "agents": []"#
        try Data(broken.utf8).write(to: url)

        let get = run(["config", "get", "claimsPolicy"])
        XCTAssertTrue(get.stderr.contains("not valid JSON"), "the file's problem must be said, got: \(get.stderr)")

        let set = run(["config", "set", "retentionDays", "10"])
        XCTAssertEqual(set.status, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken, "the user's file must be untouched")
    }

    func testAllowDispatchIsAKnobSoDispatchCanBeSwitchedOnFromTheCLI() {
        XCTAssertEqual(run(["config", "set", "allowDispatch", "true"]).status, 0)
        XCTAssertEqual(run(["config", "get", "allowDispatch"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "true")
        XCTAssertEqual(run(["config", "set", "allowDispatch", "maybe"]).status, 64)
    }

    // review --since with a revision that does not exist

    func testReviewRefusesABaselineThatIsNotACommit() throws {
        XCTAssertTrue(Shell.run("/usr/bin/env", ["git", "init", "-q"], in: root).succeeded)
        let out = run(["review", ".", "--since", "deadbeefdeadbeef"])
        XCTAssertEqual(out.status, 1, out.stdout)
        XCTAssertTrue(out.stderr.contains("not a commit"), out.stderr)
    }

    // history: an entry with no project must not borrow the folder you stand in

    func testHistoryDoesNotShowTheCurrentFolderForEntriesWithoutAProject() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let line = #"{"id":"11111111-1111-1111-1111-111111111111","at":"2026-10-26T10:00:00Z","kind":"note","title":"no-project-entry","v":1}"# + "\n"
        try Data(line.utf8).write(to: home.appendingPathComponent("ledger.jsonl"))
        let out = run(["history", "-n", "3"])
        XCTAssertTrue(out.stdout.contains("no-project-entry"), out.stdout)
        XCTAssertFalse(out.stdout.contains(root.lastPathComponent), "showed the cwd name: \(out.stdout)")
    }
}

// MARK: - Git hooks

final class AuditGitHookTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-hooks-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "t"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: [String], environment: [String: String] = [:]) throws -> Shell.Output {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: root, environment: environment, timeout: 60)
        guard out.succeeded else {
            throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr])
        }
        return out
    }

    /// `GENTLEMERGE_SKIP=1 git commit` silently skipped the user's own post-commit hook.
    func testSkippingTheGateStillRunsTheUsersOwnPostCommitHook() throws {
        let hooks = root.appendingPathComponent(".git/hooks")
        let marker = root.appendingPathComponent("foreign-ran")
        let foreign = "#!/bin/sh\necho ran >> '\(marker.path)'\n"
        try Data(foreign.utf8).write(to: hooks.appendingPathComponent("post-commit"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: hooks.appendingPathComponent("post-commit").path)
        let install = Shell.run(binary, ["project", "init", "--git-hooks"], in: root,
                                environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
        XCTAssertEqual(install.status, 0, install.stderr)

        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"])
        try git(["commit", "-qm", "one"], environment: ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_BIN": binary])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "sanity: it chains without a skip")
        try FileManager.default.removeItem(at: marker)

        try "b\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"])
        try git(["commit", "-qm", "two"],
                environment: ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_BIN": binary, "GENTLEMERGE_SKIP": "1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the user's own post-commit hook was skipped along with ours")
    }

    func testUninstallRemovesAGateOfAnOlderRevision() throws {
        let hooks = root.appendingPathComponent(".git/hooks")
        let old = "#!/bin/sh\n# gentlemerge pre-commit (gate 2)\nexit 0\n"
        let path = hooks.appendingPathComponent("pre-commit")
        try Data(old.utf8).write(to: path)
        let message = try GitHookInstaller(paths: Paths(home: home)).uninstall(repo: root)
        XCTAssertEqual(message, "removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testTheCurrentPostCommitScriptDoesNotExitBeforeChaining() {
        let script = GitHookInstaller.postCommitScript()
        let lines = script.components(separatedBy: "\n")
        let chain = lines.firstIndex { $0.contains(".gentlemerge-prev") }
        let earlyExit = lines.firstIndex { $0.contains("GENTLEMERGE_SKIP") && $0.contains("exit 0") }
        XCTAssertNotNil(chain)
        XCTAssertNil(earlyExit, "a skip must not exit before the user's chained hook")
    }
}

/// The previous Codex notify program is called from a double-quoted word, where
/// the shell still expands `$`, backticks and backslashes.
final class CodexChainedPathQuotingTests: XCTestCase {
    func testAChainedProgramPathIsTakenLiterally() throws {
        let installer = HookInstaller(paths: Paths(home: FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-quote-\(UUID())")))
        let tricky = "/opt/it's $HOME/`id`/back\\slash \"q\"/notify"
        let script = installer.codexNotifyScript(chaining: [tricky, "turn-ended"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-quote-run-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Run only the chained line: swap the real program for `printf` so what the
        // shell passes as argv[0] is observable, and drop the hook invocation.
        let line = try XCTUnwrap(script.components(separatedBy: "\n").first { $0.contains("turn-ended") })
        let probe = "#!/bin/sh\nset -u\nprintf '%s' " + line.replacingOccurrences(of: " >/dev/null 2>&1 || :", with: "")
            .replacingOccurrences(of: "\"$@\"", with: "") + "\n"
        let file = dir.appendingPathComponent("probe.sh")
        try probe.write(to: file, atomically: true, encoding: .utf8)
        let out = Shell.run("/bin/sh", [file.path], timeout: 10)
        XCTAssertEqual(out.status, 0, out.stderr)
        // printf '%s' "<path>" "turn-ended" prints both words back to back.
        XCTAssertEqual(out.stdout, tricky + "turn-ended")
    }
}
