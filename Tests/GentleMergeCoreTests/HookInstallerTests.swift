import XCTest
@testable import GentleMergeCore

final class HookInstallerTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var installer: HookInstaller!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = Paths(
            home: root.appendingPathComponent("home"),
            claudeSettings: root.appendingPathComponent("settings.json"),
            codexConfig: root.appendingPathComponent("config.toml")
        )
        installer = HookInstaller(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func settings() throws -> [String: Any] {
        try installer.readJSONObject(at: paths.claudeSettings)
    }

    private func commands(in settings: [String: Any], event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testInstallKeepsEverythingElseInSettingsJSON() throws {
        let original = """
        {"theme":"dark","enabledPlugins":{"composio@composio":true},
         "hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/my-own-hook"}]}]}}
        """
        try Data(original.utf8).write(to: paths.claudeSettings)

        _ = try installer.installClaudeCode(plan: .init())

        let updated = try settings()
        XCTAssertEqual(updated["theme"] as? String, "dark")
        XCTAssertNotNil(updated["enabledPlugins"])

        let stopCommands = commands(in: updated, event: "Stop")
        XCTAssertTrue(stopCommands.contains("/usr/local/bin/my-own-hook"), "someone else's hook must survive")
        XCTAssertEqual(stopCommands.filter { $0.contains(HookInstaller.marker) }.count, 1)

        XCTAssertTrue(commands(in: updated, event: "Notification").contains { $0.contains("--mode notify") })
        XCTAssertTrue(commands(in: updated, event: "PreToolUse").isEmpty, "remote approval is opt-in")

        // Without SessionStart there is no baseline commit, and a review can
        // only diff against HEAD — which is not what the session changed.
        XCTAssertFalse(commands(in: updated, event: "SessionStart").isEmpty)
    }




    func testUninstallLeavesForeignHooksAlone() throws {
        let original = """
        {"hooks":{"Notification":[{"hooks":[{"type":"command","command":"/opt/theirs.sh"}]}]}}
        """
        try Data(original.utf8).write(to: paths.claudeSettings)
        _ = try installer.installClaudeCode(plan: .init())

        let result = try installer.uninstallClaudeCode()
        XCTAssertTrue(result.changed)

        let updated = try settings()
        XCTAssertEqual(commands(in: updated, event: "Notification"), ["/opt/theirs.sh"])
        XCTAssertTrue(installer.claudeCodeStatus().isEmpty)
    }

    func testDryRunWritesNothing() throws {
        let result = try installer.installClaudeCode(plan: .init(), dryRun: true)
        XCTAssertFalse(result.changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.claudeSettings.path))
    }

    func testInstallBacksUpTheOriginal() throws {
        try Data(#"{"theme":"dark"}"#.utf8).write(to: paths.claudeSettings)
        let result = try installer.installClaudeCode(plan: .init())
        let backup = try XCTUnwrap(result.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), #"{"theme":"dark"}"#)
    }

    // MARK: - Codex

    func testCodexNotifyIsChainedNotStolen() throws {
        let original = """
        notify = [ "/tmp/.codex/computer-use/Client.app/Contents/MacOS/Client", "turn-ended" ]
        model = "gpt-5.6-sol"

        [marketplaces.openai]
        source = "local"
        """

        let (contents, previous) = installer.codexConfigContents(
            original: original,
            scriptPath: "/tmp/.gentlemerge/bin/codex.sh"
        )

        XCTAssertEqual(previous, [
            "/tmp/.codex/computer-use/Client.app/Contents/MacOS/Client",
            "turn-ended",
        ])
        XCTAssertTrue(contents.contains(#"notify = ["/tmp/.gentlemerge/bin/codex.sh"]"#))
        XCTAssertTrue(contents.contains("model = \"gpt-5.6-sol\""))
        XCTAssertTrue(contents.contains("[marketplaces.openai]"))
        XCTAssertEqual(contents.components(separatedBy: "notify =").count - 1, 1)

        let script = installer.codexNotifyScript(chaining: previous)
        XCTAssertTrue(script.contains("Contents/MacOS/Client\" \"turn-ended\" \"$@\""))
        XCTAssertTrue(script.contains("--provider codex"))
    }

    func testCodexWithoutAnExistingNotifyGetsATopLevelKey() throws {
        let (contents, previous) = installer.codexConfigContents(
            original: "model = \"gpt-5\"\n\n[plugins.foo]\nenabled = true\n",
            scriptPath: "/tmp/codex.sh"
        )
        XCTAssertTrue(previous.isEmpty)
        // A top-level key after a [table] header would belong to that table.
        XCTAssertTrue(contents.hasPrefix(#"notify = ["/tmp/codex.sh"]"#))
        XCTAssertFalse(installer.codexNotifyScript(chaining: []).contains("$@\" >/dev/null"))
    }
}

/// The git gate must never look protective while checking nothing: when the
/// binary it resolves is absent, both scripts say so on stderr instead of
/// passing silently.
final class GitHookScriptTests: XCTestCase {
    func testPreCommitWarnsWhenTheBinaryIsMissing() {
        XCTAssertTrue(GitHookInstaller.script.contains("NOT checked"))
        XCTAssertTrue(GitHookInstaller.script.contains("GENTLEMERGE_BIN"))
    }

    func testPostCommitWarnsWhenTheBinaryIsMissing() {
        XCTAssertTrue(GitHookInstaller.postCommitScript.contains("NOT released"))
    }

    func testHookPayloadsAreOwnerOnlyFromBirth() {
        // The hook carries verbatim tool input; the Redactor sees it later.
        XCTAssertTrue(HookScript.source.contains("umask 077"))
    }

    func testEnsureBinaryLinkRefusesOutsideTheRealBinary() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        // Under XCTest the running executable is the test bundle, not
        // gentlemerge — so this must decline, never plant a bogus link.
        XCTAssertFalse(GitHookInstaller.ensureBinaryLink(paths: Paths(home: home)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("bin/gentlemerge").path))
    }
}
