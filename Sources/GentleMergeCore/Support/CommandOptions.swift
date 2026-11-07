import Foundation

/// Which options each command understands.
///
/// An option nobody declared used to be dropped without a word, and the command
/// ran anyway: `uninstall --dry-run` uninstalled, `compact --dry-run` compacted,
/// `say "hola" --too claude` sent "hola claude" to everyone. So every command says
/// what it takes, and anything else stops the line before it can act or leave a
/// trace.
public enum CommandOptions {
    /// What `--` hands over to the text, and what a refusal tells you to reach for.
    public static let literalSeparator = "--"

    /// The options of one command: those of every form of it, plus those of a
    /// subcommand (`task add`, `watch idle`), which is the first word after it.
    struct Declaration {
        var always: Set<String> = []
        var bySubcommand: [String: Set<String>] = [:]
    }

    /// `--from`, `--as` and `--provider` say who is working, and a command an agent
    /// runs files that mark before it does anything else.
    private static let identity: Set<String> = ["--from", "--as", "--provider"]

    private static let claimOptions: Set<String> = ["--paths", "--intent", "--ttl", "--project", "--from", "--provider"]
    private static let projectInitOptions: Set<String> = ["--project", "--label", "--git-hooks"]

    private static let watchRuleOptions: Set<String> = ["--note", "--project", "--global"]

    static let declarations: [String: Declaration] = [
        "demo": .init(always: ["--keep", "--home-real"]),
        "sim": .init(always: ["--script", "--worktree"]),
        "mcp": .init(always: ["--project", "--label"]),
        "install": .init(always: ["--minimal", "--codex", "--dry-run"]),
        "uninstall": .init(),
        "claim": .init(always: claimOptions),
        "release": .init(always: ["--paths", "--project", "--from", "--provider"]),
        "claims": .init(always: ["--project", "--json"]),
        "git-hooks": .init(always: ["--project"]),
        "status": .init(),
        "doctor": .init(always: ["--project"]),
        "config": .init(),
        "ownership": .init(always: ["--project"]),
        "compact": .init(),
        "list": .init(),
        "say": .init(always: identity.union([
            "--project", "--global", "--done", "--to", "--to-branch", "--kind", "--urgent", "--fyi",
            "--replaces", "--attach", "--nudge",
        ])),
        "who": .init(always: ["--all", "--project"]),
        "brief": .init(always: identity.union(["--project"])),
        "show": .init(),
        "review": .init(always: ["--slow", "--since"]),
        "radar": .init(always: ["--project", "--force"]),
        "projects": .init(always: ["--all"]),
        "project": .init(bySubcommand: [
            "init": projectInitOptions,
            "adopt-worktrees": ["--project"],
        ]),
        "init": .init(always: projectInitOptions),
        "handoff": .init(always: identity.union(["--project"])),
        "precommit": .init(always: identity.union(["--project", "--since", "--enforce", "--staged"])),
        "postcommit": .init(always: ["--project", "--merge", "--rewrite"]),
        "land": .init(always: identity.union([
            "--project", "--branch", "--into", "--skip-checks", "--dry-run", "--fast",
        ])),
        "env": .init(always: identity.union(["--write", "--project"])),
        "task": .init(always: identity.union(["--project"]), bySubcommand: [
            "add": ["--by", "--step"],
            "claim": claimOptions,
            "release": ["--paths"],
        ]),
        "watch": .init(always: identity, bySubcommand: [
            "session-end": watchRuleOptions, "end": watchRuleOptions,
            "idle": watchRuleOptions, "task": watchRuleOptions,
            "list": ["--project"], "rm": ["--project"], "cancel": ["--project"],
        ]),
        "delegate": .init(always: identity.union([
            "--to", "--title", "--spec", "--inputs", "--may-touch", "--expect", "--budget", "--project",
        ])),
        "request": .init(always: identity.union(["--project"]), bySubcommand: [
            "list": ["--mine", "--for-me"],
            "accept": ["--result"], "done": ["--result"], "fail": ["--result"],
            "reject": ["--result"], "ack": ["--result"],
        ]),
        "presence": .init(always: identity.union(["--label", "--task", "--capabilities", "--project"])),
        "session-context": .init(always: identity.union(["--project", "--payload", "--mode"])),
        "stats": .init(always: ["--value", "--session"]),
        "advise": .init(always: identity.union(["--project", "--payload"])),
        "snapshot": .init(always: ["--project"]),
        "history": .init(always: ["-n"]),
        "test-event": .init(always: ["--blocking"]),
        "print-hook": .init(),
    ]

    /// The same command under another name.
    static let aliases: [String: String] = [
        "tasks": "task", "watches": "watch", "requests": "request", "snapshots": "snapshot",
    ]

    /// Every command name a declaration answers to, aliases included.
    public static var commands: [String] { Array(declarations.keys) + Array(aliases.keys) }

    /// What this command line may carry. Nil when the command is not ours to judge:
    /// `help`, `version`, or a word that is not a command at all (which gets its
    /// own error, further on).
    public static func allowed(command: String, arguments: [String]) -> Set<String>? {
        guard let declaration = declarations[aliases[command] ?? command] else { return nil }
        let subcommand = arguments.first.flatMap { declaration.bySubcommand[$0] } ?? []
        return declaration.always.union(subcommand)
    }

    /// Commands with text of their own, where the way out of a refusal is `--`.
    private static let takesText: Set<String> = ["say", "task", "tasks", "watch", "watches", "snapshot", "snapshots"]

    /// Why this line must not run, or nil. Looks only ahead of the first `--`:
    /// past it everything is somebody's text.
    public static func problem(command: String, arguments: [String]) -> String? {
        guard let allowed = allowed(command: command, arguments: arguments) else { return nil }
        for token in arguments.prefix(while: { $0 != literalSeparator }) {
            if let name = nameBeforeEquals(in: token) {
                let value = token.dropFirst(name.count + 1)
                return "\(command): write `\(name) \(value)`, not `\(token)`. Nothing was done."
            }
            guard CommandArguments.looksLikeFlag(token), !allowed.contains(token) else { continue }
            let known = allowed.isEmpty ? "It takes no options." : "It takes: \(allowed.sorted().joined(separator: ", "))."
            let escape = takesText.contains(command)
                ? "\nFor text that starts with a dash: gentlemerge \(command) \(literalSeparator) \"\(token)\""
                : ""
            return "\(command): unknown option \(token). Nothing was done. \(known)\(escape)"
        }
        return nil
    }

    /// `--to` out of `--to=claude`: the spelling this CLI does not read, and which
    /// used to travel on as plain text. Anything before the `=` with a space in it
    /// is a sentence that happens to contain one.
    private static func nameBeforeEquals(in token: String) -> String? {
        guard token.hasPrefix("--"), let equals = token.firstIndex(of: "=") else { return nil }
        let name = String(token[..<equals])
        return name != literalSeparator && CommandArguments.looksLikeFlag(name) ? name : nil
    }
}
