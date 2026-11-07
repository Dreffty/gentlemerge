import XCTest
@testable import GentleMergeCore

/// An option nobody declared is an error, and the command does not run.
///
/// It used to be dropped without a word: `uninstall --dry-run` removed the hooks,
/// `compact --dry-run` compacted, `say "hola" --too claude` sent "hola claude" to
/// every agent. An agent reaches for `--dry-run` out of habit, on the very commands
/// where it matters most.
final class UnknownOptionTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var repo: URL!
    private var settings: URL!
    private var codexConfig: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-option-\(UUID())")
        home = root.appendingPathComponent("home")
        repo = root.appendingPathComponent("repo")
        settings = root.appendingPathComponent("settings.json")
        codexConfig = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path

        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"],
                          ["config", "user.name", "t"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(Shell.run("/usr/bin/env", ["git"] + arguments, in: repo).status, 0)
        }
        try Data("hola\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = Shell.run("/usr/bin/env", ["git", "add", "."], in: repo)
        _ = Shell.run("/usr/bin/env", ["git", "commit", "-qm", "first"], in: repo)

        // A home worth damaging: real hooks to remove, a task to tick, a note to read.
        XCTAssertEqual(run(["install"]).status, 0)
        XCTAssertEqual(run(["project", "init", repo.path]).status, 0)
        XCTAssertEqual(run(["task", "add", "la tarea", "--project", repo.path]).status, 0)
        XCTAssertEqual(run(["say", "la nota", "--project", repo.path]).status, 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ arguments: [String]) -> Shell.Output {
        Shell.run(binary, arguments, in: repo, environment: [
            "GENTLEMERGE_HOME": home.path,
            "GENTLEMERGE_CLAUDE_SETTINGS": settings.path,
            "GENTLEMERGE_CODEX_CONFIG": codexConfig.path,
            "GENTLEMERGE_LABEL": "tester",
        ])
    }

    /// Every file under the sandbox, with its contents. If a command acts, or so
    /// much as leaves a presence mark, this tells.
    private func everything() throws -> [String: Data] {
        var found: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            found[file.path] = try Data(contentsOf: file)
        }
        return found
    }

    /// Each command, in each of its forms, is handed an option that does not exist:
    /// it says so, exits 2, and nothing on disk moves.
    func testEveryCommandRefusesAnOptionItDoesNotKnowAndDoesNothing() throws {
        let forms: [[String]] = [
            ["demo"], ["sim"], ["mcp"], ["install"], ["uninstall"], ["claim", "--paths", "a.txt"], ["release"],
            ["claims"], ["git-hooks", "install"], ["git-hooks", "uninstall"], ["status"], ["doctor"],
            ["config", "set", "retentionDays", "9"], ["ownership"], ["ownership", "pin"], ["compact"], ["list"],
            ["say", "hola"], ["say", "--done"], ["who"], ["brief"], ["show", "abcd"], ["review"], ["radar"],
            ["projects"], ["project", "init"], ["project", "adopt-worktrees"], ["init"], ["handoff"], ["precommit"],
            ["postcommit"], ["land"], ["env"], ["env", "--write"], ["task"], ["task", "list"], ["task", "add", "x"],
            ["task", "done", "0"], ["task", "undone", "0"], ["task", "rm", "0"], ["task", "claim", "0"],
            ["task", "release", "0"], ["task", "step", "add", "0", "y"], ["tasks"], ["watch"], ["watch", "idle", "x"],
            ["watch", "session-end", "x"], ["watch", "task", "0"], ["watch", "rm", "x"], ["watches"],
            ["delegate", "--to", "a", "--title", "b", "--spec", "c"], ["request", "list"], ["request", "show", "x"],
            ["request", "done", "x"], ["requests"], ["presence"], ["session-context"], ["stats"], ["advise"],
            ["snapshot"], ["snapshot", "create", "x"], ["snapshot", "restore", "x"], ["snapshots"], ["history"],
            ["test-event"], ["print-hook"],
        ]

        let before = try everything()
        for form in forms {
            let output = run(form + ["--esto-no-existe"])
            let line = "gentlemerge " + form.joined(separator: " ") + " --esto-no-existe"
            XCTAssertEqual(output.status, 2, "\(line) answered \(output.status): \(output.text)")
            XCTAssertTrue(output.stderr.contains("--esto-no-existe"), "\(line) did not name the option: \(output.text)")
            let now = try everything()
            let moved = Set(before.keys).union(now.keys).filter { before[$0] != now[$0] }
            XCTAssertTrue(moved.isEmpty, "\(line) changed \(moved.sorted())")
        }
    }

    func testUninstallDryRunDoesNotUninstall() throws {
        let hooks = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(hooks.contains("gentlemerge-hook"))

        XCTAssertEqual(run(["uninstall", "--dry-run"]).status, 2)

        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), hooks)
    }

    func testAMistypedOptionDoesNotEndUpInsideTheNote() throws {
        let output = run(["say", "hola", "--too", "claude"])
        XCTAssertEqual(output.status, 2, output.text)
        let log = try String(contentsOf: home.appendingPathComponent("messages.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("hola"), "the note went out: \(log)")
    }

    func testAMistypedOptionDoesNotEndUpInsideTheTask() throws {
        let output = run(["task", "add", "x", "--foo", "bar"])
        XCTAssertEqual(output.status, 2, output.text)
        XCTAssertFalse(run(["task", "list"]).stdout.contains("x bar"))
    }

    /// `--to=claude` is the same mistake in a nicer coat. It used to travel as text:
    /// "hola --to=claude", to everyone.
    func testAnOptionWrittenWithAnEqualsSignIsRefusedToo() throws {
        let output = run(["say", "hola", "--to=claude"])
        XCTAssertEqual(output.status, 2, output.text)
        XCTAssertTrue(output.stderr.contains("--to claude"), "it should say how to write it: \(output.text)")
        let log = try String(contentsOf: home.appendingPathComponent("messages.jsonl"), encoding: .utf8)
        XCTAssertFalse(log.contains("hola"), log)
    }

    /// The way out: after a bare `--`, everything is text, however it is spelled.
    func testADoubleDashLetsYouWriteTextThatStartsWithADash() throws {
        let said = run(["say", "--project", repo.path, "--", "--too", "--done", "--global", "claude"])
        XCTAssertEqual(said.status, 0, said.text)
        XCTAssertTrue(said.stdout.contains("--too --done --global claude"), said.text)
        XCTAssertTrue(said.stdout.contains("in repo"), "--global after -- must not make it global: \(said.text)")

        let added = run(["task", "add", "--", "--no-verify", "se", "usa", "demasiado"])
        XCTAssertEqual(added.status, 0, added.text)
        XCTAssertTrue(run(["task", "list"]).stdout.contains("--no-verify se usa demasiado"))
    }

    /// What this must not break: words that merely start with a dash were already
    /// text, and agents write them all the time.
    func testTextThatOnlyLooksLikeAnOptionStillGoesThrough() throws {
        for note in ["- done: parser", "-1 on this approach", "--no-verify is being used"] {
            let output = run(["say", note])
            XCTAssertEqual(output.status, 0, "\(note): \(output.text)")
        }
    }

    /// The hooks call the CLI with these exact lines, and swallow any error: a flag
    /// missing from a declaration would silently switch the briefing off.
    func testTheLinesTheHooksSendAreAccepted() throws {
        let payload = root.appendingPathComponent("payload.json")
        try Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","cwd":"/tmp"}"#.utf8).write(to: payload)

        for line in [
            ["session-context", "--payload", payload.path, "--project", repo.path, "--provider", "claude-code"],
            ["advise", "--payload", payload.path, "--project", repo.path, "--provider", "claude-code"],
            ["precommit", "--enforce", "--staged", "--project", repo.path],
            ["postcommit", "--project", repo.path],
        ] {
            let output = run(line)
            XCTAssertEqual(output.status, 0, "\(line.joined(separator: " ")): \(output.text)")
        }
        let sent = HookScript.source.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"$CLI\" ") }
        XCTAssertEqual(sent.count, 2)
        for scriptLine in sent {
            XCTAssertTrue(
                scriptLine.contains("session-context --payload \"$PAYLOAD_FILE\" --project \"$PROJECT\"")
                    || scriptLine.contains("advise --payload \"$PAYLOAD_FILE\" --project \"$PROJECT\""),
                "the hook sends something new, add it to the lines above: \(scriptLine)"
            )
        }
    }

    // MARK: - The table cannot drift from the code

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GentleMergeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    /// Everything the CLI target says, however many files it is split into.
    private func cliSource() throws -> String {
        let directory = packageRoot.appendingPathComponent("Sources/GentleMerge")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("CLI") && $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// A new command that nobody declared would refuse nothing, which is the bug
    /// this file is about, and would pass every test above.
    func testEveryCommandTheCLIAnswersToIsDeclared() throws {
        let source = try cliSource()
        let pattern = try NSRegularExpression(pattern: #"^ {8}case ("[^:]+"):"#, options: .anchorsMatchLines)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var names = Set<String>()
        for match in matches {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            for word in source[range].split(separator: ",") {
                names.insert(word.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
            }
        }
        XCTAssertTrue(names.contains("uninstall"), "found no commands, so this stopped testing anything")
        // The top-level switch sits at this indentation, and so do a few others. Words
        // of theirs that are not commands are spelled out so a new one still trips this.
        let notCommands: Set<String> = ["help", "--help", "-h", "--version", "version"]
        let undeclared = names.subtracting(notCommands).filter { name in
            CommandOptions.allowed(command: name, arguments: []) == nil && !subcommandWords.contains(name)
        }
        XCTAssertTrue(undeclared.isEmpty, "no declaration for: \(undeclared.sorted())")
    }

    /// Words a nested `switch` at the same indentation matches on.
    private let subcommandWords: Set<String> = [
        "allowDispatch", "dispatchMode", "dispatchDailyBudgetMinutes", "claimsPolicy", "retentionDays", "autoLand",
        "add", "rm", "pin", "show", "init", "adopt-worktrees", "accept", "done", "fail", "reject", "ack",
        "undone", "claim", "release", "step", "steps", "list", "session-end", "end", "idle", "cancel",
        "create", "restore", "uninstall", "install", "full", "delta", "off", "deny", "warn",
    ]

    /// An option the code reads and the table does not name can never be used: the
    /// door refuses it before the code gets to look.
    func testEveryOptionTheCLIReadsIsDeclaredSomewhere() throws {
        let source = try cliSource()
        let pattern = try NSRegularExpression(pattern: #"(?:isSet\(|values?\(after: )"(-[^"]+)""#)
        let read = Set(pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        })
        XCTAssertTrue(read.contains("--dry-run"), "found no options, so this stopped testing anything")

        var declared = Set<String>()
        for declaration in CommandOptions.declarations.values {
            declared.formUnion(declaration.always)
            declaration.bySubcommand.values.forEach { declared.formUnion($0) }
        }
        let missing = read.subtracting(declared).sorted()
        XCTAssertTrue(missing.isEmpty, "the CLI reads \(missing) but no command declares it")
    }

    /// What the help text and the README teach has to work when you type it. Every
    /// `gentlemerge <command> … --option` they show must get past the door.
    func testEveryOptionTheDocumentationShowsIsAccepted() throws {
        let readme = try String(contentsOf: packageRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let protocolDoc = try String(contentsOf: packageRoot.appendingPathComponent("docs/AGENT_PROTOCOL.md"), encoding: .utf8)
        let help = run(["help"]).stdout
        XCTAssertFalse(help.isEmpty)

        let line = try NSRegularExpression(pattern: #"gentlemerge ([a-z-]+)((?: [^\n`|#]*)?)"#)
        for (name, text) in [("help", help), ("README.md", readme), ("AGENT_PROTOCOL.md", protocolDoc)] {
            for match in line.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let commandRange = Range(match.range(at: 1), in: text),
                      let restRange = Range(match.range(at: 2), in: text) else { continue }
                let command = String(text[commandRange])
                let words = text[restRange].split(separator: " ").map { word in
                    word.trimmingCharacters(in: CharacterSet(charactersIn: "[](),.;:"))
                }
                guard let judged = CommandOptions.allowed(command: command, arguments: words) else { continue }
                // `task claim|release`, `task done|undone|rm`: any of the forms will do.
                let forms = (words.first ?? "").split(separator: "|").map { [String($0)] + words.dropFirst() }
                let allowed = forms.reduce(judged) { $0.union(CommandOptions.allowed(command: command, arguments: $1) ?? []) }
                for word in words.prefix(while: { $0 != "--" }) where word.hasPrefix("-") && CommandArguments.looksLikeFlag(word) {
                    XCTAssertTrue(allowed.contains(word), "\(name) shows `gentlemerge \(command) … \(word)`, which is refused")
                }
            }
        }
    }
}
