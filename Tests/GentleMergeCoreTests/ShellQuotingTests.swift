import XCTest
@testable import GentleMergeCore
@testable import GentleMergePorts

/// Two generated files are shell code, not data: `.gentlemerge/env.sh`, which the
/// docs tell you to `source`, and the installed git hooks, which run on every
/// commit. Both interpolated a value that is not ours to control — an agent label
/// and a home-derived path — with no quoting.
///
/// Neither is fixed by quoting the obvious way. The hook path went into
/// `${GENTLEMERGE_BIN:-...}`, and `word` in that expansion *is* subject to
/// command substitution, so a home containing `$(...)` ran it per commit; one
/// containing `"` produced a hook that would not parse (audit 2026-10-07). These
/// tests execute a real `/bin/sh` rather than comparing strings, because the
/// whole defect lived in how a shell reads the output.
final class ShellQuotingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("quoting-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Run a generated snippet with `/bin/sh`, reporting stdout and exit status.
    /// A snippet that does not parse comes back non-zero with a syntax error.
    private func runShell(_ body: String, env extra: [String: String] = [:]) -> (Int32, String) {
        let url = root.appendingPathComponent("snippet-\(UUID()).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path]
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private let shebang = "#!/bin/sh\n"

    // MARK: - env.sh

    /// A label that tries to run something, in a file we are told to source.
    func testALabelThatIsShellCodeIsNotExecutedWhenEnvIsSourced() {
        let marker = root.appendingPathComponent("PWNED").path
        let token = "EXECUTED-7f3a91"
        let hostile = marker + " ; echo " + token
        let body = WorktreeEnv.render(WorktreeEnv.Allocation(label: hostile, base: 4000))
            + "\nprintf '%s\\n' \"set=[$GENTLEMERGE_LABEL]\"\n"

        let (status, out) = runShell(body)

        XCTAssertEqual(status, 0, "env.sh must parse")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the label executed a command")
        XCTAssertEqual(
            out.trimmingCharacters(in: .whitespacesAndNewlines),
            "set=[" + hostile + "]",
            "the label must be set verbatim and nothing else must have run"
        )
    }

    /// Every classic shell metacharacter, one at a time. Asserts the value comes
    /// back *byte-identical*, not merely that the file parses: bare
    /// interpolation parses fine while quietly running `$(id)` and expanding
    /// `$var`, so a "does it parse" check alone would wave the bug through.
    func testEveryClassicShellMetacharacterSurvivesBeingSourced() {
        let hostiles = [
            "a'b", "a\"b", "a$b", "a`b", "a\\b", "a b", "a;b",
            "a$(id)", "a`id`", "a|b", "a&b", "a>b", "a*b", "a~b", "a\nb", "a b c",
        ]
        for hostile in hostiles {
            let body = WorktreeEnv.render(WorktreeEnv.Allocation(label: hostile, base: 4000))
                + "\nprintf '%s\\n' \"[$GENTLEMERGE_LABEL]\"\n"
            let (status, out) = runShell(body)

            XCTAssertEqual(status, 0, "env.sh did not parse for \(hostile.debugDescription)")
            XCTAssertEqual(
                out.trimmingCharacters(in: .whitespacesAndNewlines), "[" + hostile + "]",
                "\(hostile.debugDescription) did not survive verbatim — it was expanded or executed"
            )
        }
    }

    /// The values the file sets are unchanged by the quoting — asserted by
    /// sourcing it, not by matching its text, since the quoting legitimately
    /// added quotes around the label.
    func testTheDocumentedShapeIsUnchanged() {
        let script = WorktreeEnv.render(WorktreeEnv.Allocation(label: "claude", base: 4100))

        let probe = "\nprintf '%s\\n' \"$GENTLEMERGE_LABEL|$PORT|$AGENT_PORT_BASE|$AGENT_PORT_RANGE|$DATABASE_URL_SUFFIX\"\n"
        let (status, out) = runShell(script + probe)

        XCTAssertEqual(status, 0, "env.sh must parse")
        let range = WorktreeEnv.Allocation(label: "claude", base: 4100).range
        XCTAssertEqual(
            out.trimmingCharacters(in: .whitespacesAndNewlines),
            "claude|4100|4100|\(range.lowerBound)-\(range.upperBound)|_claude"
        )
    }

    // MARK: - installed git hooks

    /// A path with a quote in it must not produce a hook that fails to parse —
    /// that would break every commit, loudly, for everyone on the machine.
    func testAnInstalledHookWithAQuoteInThePathStillParses() {
        let hostile = "/tmp/it's a dir/gentlemerge"
        let script = GitHookInstaller.script(gateDefault: hostile)

        XCTAssertFalse(script.contains("GENTLEMERGE_BIN:-" + hostile),
                       "the raw path is still expanded inline")
        let (status, _) = runShell(shebang + script, env: ["GENTLEMERGE_BIN": "/bin/true"])
        XCTAssertEqual(status, 0, "the generated hook must parse")
    }

    /// And a path carrying command substitution must not run it.
    func testAnInstalledHookWithSubstitutionInThePathDoesNotExecuteIt() {
        let marker = root.appendingPathComponent("HOOK-PWNED").path
        let hostile = "/tmp/$(touch " + marker + ")/gentlemerge"
        let script = GitHookInstaller.script(gateDefault: hostile)

        let (_, out) = runShell(shebang + script, env: ["GENTLEMERGE_BIN": "/bin/true"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the path executed a command")
        XCTAssertFalse(out.contains("gate binary not found"), out)
    }

    /// The post-commit hook carries the same line and the same exposure.
    func testThePostCommitHookWithAHostilePathStillParses() {
        let hostile = "/tmp/" + "$" + "(id)" + "'" + "\"" + "x/gentlemerge"
        let script = GitHookInstaller.postCommitScript(gateDefault: hostile)

        XCTAssertFalse(script.contains("GENTLEMERGE_BIN:-/tmp/"))
        let (status, _) = runShell(shebang + script, env: ["GENTLEMERGE_BIN": "/bin/true"])
        XCTAssertEqual(status, 0, "the generated post-commit hook must parse")
    }

    /// Quoting must not break the documented override.
    func testTheGateBinaryOverrideStillWins() {
        let script = GitHookInstaller.script(gateDefault: "/nonexistent/default/gentlemerge")
        let (status, out) = runShell(shebang + script, env: ["GENTLEMERGE_BIN": "/bin/echo"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("precommit"), "GENTLEMERGE_BIN must still be honoured: \(out)")
    }

    /// The escaping primitive, directly.
    func testTheQuotingPrimitiveItself() {
        XCTAssertEqual(WorktreeEnv.shellQuoted("plain"), "'plain'")
        XCTAssertEqual(WorktreeEnv.shellQuoted("a'b"), "'a'\\''b'")
        XCTAssertEqual(GitHookInstaller.shellQuoted("$(id)"), "'$(id)'")
    }

    // MARK: - the shared primitive

    /// One quoting function, used by the generated files *and* by anything that
    /// interpolates a value into a command string. An Xcode scheme name read out
    /// of the repository used to go in bare, so a scheme file named
    /// `ok'; touch PWNED; echo '` ran its own name (audit 2026-10-08).
    func testTheSharedPrimitiveQuotesForAShell() {
        XCTAssertEqual(Shell.quoted("plain"), "'plain'")
        XCTAssertEqual(Shell.quoted("a'b"), "'a'\\''b'")
        XCTAssertEqual(Shell.quoted("$(id)"), "'$(id)'")
        XCTAssertEqual(Shell.quoted("App`id`"), "'App`id`'")
    }

    /// …and a value quoted with it survives a real shell as data, not as code.
    func testAQuotedSchemeNameDoesNotExecute() {
        let marker = root.appendingPathComponent("SCHEME-PWNED").path
        let hostile = "ok'; touch \(marker); echo '"
        let body = shebang + "printf '%s' \(Shell.quoted(hostile))\n"

        let (status, _) = runShell(body)

        XCTAssertEqual(status, 0, "the snippet must parse")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the scheme name executed a command")
    }
}