import XCTest
@testable import GentleMergeCore

/// The installer writes three kinds of file: a shell script git runs on every
/// commit, a shell command string in `~/.claude/settings.json`, and a TOML file
/// Codex parses. All three took a path — the user's home, effectively — and
/// escaped it for only one of the characters that matter.
final class InstallerQuotingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("instq-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Run a snippet with a real /bin/sh: a snippet that does not parse comes
    /// back non-zero with a syntax error, which is exactly what a broken hook is.
    private func sh(_ body: String, env: [String: String] = [:]) -> (Int32, String) {
        let url = root.appendingPathComponent("s-\(UUID()).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - #13 the Claude Code / Codex hook command string

    func testTheEscapingPrimitiveHandlesEveryCharacter() {
        XCTAssertEqual(HookInstaller.shellQuoted("plain"), "'plain'")
        XCTAssertEqual(HookInstaller.shellQuoted("a b"), "'a b'")
        XCTAssertEqual(HookInstaller.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(HookInstaller.shellQuoted("$(id)"), "'$(id)'")
        XCTAssertEqual(HookInstaller.shellQuoted("`id`"), "'`id`'")
        XCTAssertEqual(HookInstaller.shellQuoted("a\\b"), "'a\\b'")

        XCTAssertEqual(HookInstaller.tomlBasicString("plain"), "plain")
        XCTAssertEqual(HookInstaller.tomlBasicString("a\\b"), "a\\\\b")
        XCTAssertEqual(HookInstaller.tomlBasicString("a\"b"), "a\\\"b")
    }

    /// A quoted command string must survive being written into JSON and read
    /// back, then executed by a shell.
    func testAHostilePathSurvivesTheSettingsJSONRoundTrip() throws {
        let hostile = "/Users/o'brien/x" + "$" + "(id)/notify.sh"
        let quoted = HookInstaller.shellQuoted(hostile)
        let json = "{\"command\": \(jsonString(quoted))}"
        let data = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        let command = try XCTUnwrap(data?["command"])

        let (status, out) = sh("printf '%s\\n' \(command)")
        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            out.trimmingCharacters(in: .whitespacesAndNewlines), hostile,
            "the path must survive JSON and the shell byte for byte"
        )
    }

    private func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        // Take the quoted form of the single-element array's only element.
        guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }),
              let open = text.firstIndex(of: "["),
              let close = text.lastIndex(of: "]"),
              open < close else { return "\"\"" }
        return String(text[text.index(after: open)..<close])
    }

    /// Codex parses this file. A path with a quote or a backslash used to
    /// produce a `config.toml` it could not read, so the notify bridge silently
    /// stopped being installed.
    func testCodexNotifySurvivesAHostilePathInEveryPosition() throws {
        let installer = HookInstaller(paths: Paths(home: root.appendingPathComponent("home")))
        let hostile = "/Users/o\"brien/x\\y/notify.sh"

        // Replaces an existing top-level notify.
        let replaced = installer.codexConfigContents(
            original: "model = \"x\"\nnotify = [\"/old/notify.sh\"]\n",
            scriptPath: hostile
        ).contents
        XCTAssertTrue(replaced.contains("\\\"brien"), "the quote must be TOML-escaped: \(replaced)")
        XCTAssertTrue(replaced.contains("x\\\\y"), "the backslash must be TOML-escaped: \(replaced)")
        XCTAssertFalse(replaced.contains("/old/notify.sh"),
                       "the old notify line must be replaced, not preserved: \(replaced)")

        // Inserts when there is none.
        let inserted = installer.codexConfigContents(original: "model = \"x\"\n", scriptPath: hostile).contents
        XCTAssertTrue(inserted.hasPrefix("notify = "), "a top-level key goes at the top: \(inserted)")
    }

    /// A `notify` that lives inside a table is not the top-level one. The
    /// insert path already knew that; the replace path did not, so it
    /// overwrote the table's key and never wrote the top-level one.
    func testANotifyInsideATableIsNotMistakenForTheTopLevelOne() {
        let installer = HookInstaller(paths: Paths(home: root.appendingPathComponent("home")))
        let original = """
        model = "x"

        [some.table]
        notify = ["table-value"]
        """
        let result = installer.codexConfigContents(original: original, scriptPath: "/p/notify.sh").contents

        XCTAssertTrue(result.contains("[some.table]"), "the table survives: \(result)")
        XCTAssertTrue(result.contains("table-value"), "the table's own notify must not be overwritten: \(result)")
        XCTAssertTrue(result.contains("\nnotify = [\"/p/notify.sh\"]") || result.hasPrefix("notify = [\"/p/notify.sh\"]"),
                      "a top-level notify must be written: \(result)")
        XCTAssertFalse(result.contains("chaining previous"), "no previous program exists to chain")
    }

    // MARK: - #44 Doctor must look where the installer puts things

    /// `Doctor` looked in the real home while `GitHookInstaller.gateDefault`
    /// resolves `paths.bin`, so with `GENTLEMERGE_HOME` set — or Linux under
    /// `XDG_STATE_HOME` — doctor reported "commits pass unchecked" for a healthy
    /// install. Its own tests only ever set `GENTLEMERGE_BIN`, which is why the
    /// path was never exercised.
    func testDoctorFindsTheGateBinaryUnderACustomHome() throws {
        let home = root.appendingPathComponent("custom-home")
        let paths = Paths(home: home)
        try paths.createDirectories()

        // A git repo with our hooks installed and the binary where `paths` says.
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = { (args: [String]) in
            _ = Shell.run("/usr/bin/env", ["git"] + args, in: repo, timeout: 30)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "t@example.com"])
        git(["config", "user.name", "t"])

        let hooksDir = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let installer = GitHookInstaller(paths: paths)
        let scripts: [(String, String)] = GitHookInstaller.hookNames
            .map { ($0, GitHookInstaller.script(gateDefault: "/nonexistent/gentlemerge")) }
            + [("post-commit", GitHookInstaller.postCommitScript(gateDefault: "/nonexistent/gentlemerge"))]
        for (name, body) in scripts {
            let path = hooksDir.appendingPathComponent(name)
            try body.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        _ = installer

        // The binary exists under `paths.bin`, which is where the install put it.
        let binary = paths.bin.appendingPathComponent("gentlemerge")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let check = Doctor.gitHooks(paths: paths, repo: repo)
        XCTAssertEqual(
            check.level, .ok,
            "a healthy install must not be reported as unchecked: \(check.detail)"
        )
        XCTAssertFalse(check.detail.contains("gate binary is missing"))
    }
}