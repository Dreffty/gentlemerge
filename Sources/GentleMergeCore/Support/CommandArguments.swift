import Foundation

/// One command line, taken apart.
///
/// This lived as a handful of private helpers inside the CLI, where nothing
/// could reach it — and then three bugs shipped in a row, every one of them
/// here. A flag that takes a value was added to a command but not declared, so
/// the value it consumed was read as the note's own text. A caller asked for
/// the first positional argument to mean a directory, in a command whose first
/// positional is the message. Neither is exotic; both were invisible because
/// the only way to exercise this code was to run the binary and look.
public struct CommandArguments: Sendable, Equatable, ExpressibleByArrayLiteral {
    public let raw: [String]

    public init(_ raw: [String]) { self.raw = raw }
    public init(arrayLiteral elements: String...) { self.raw = elements }

    /// Flags that consume the next argument. Without this, `task add "fix it"
    /// --project ~/x` would file a task called "fix it ~/x".
    ///
    /// A flag missing from here is not a small mistake: it does not fail, it
    /// quietly folds its own value into whatever the command reads as text.
    /// `CommandArgumentsTests` checks that every flag the CLI reads a value
    /// from is declared here, because remembering to do it by hand is exactly
    /// what failed.
    public static let valueFlags: Set<String> = [
        "--project", "--by", "--since", "--to", "--from", "--payload", "--provider", "-n",
        "--step", "--kind", "--as", "--note", "--attach", "--replaces", "--to-branch",
        // Path claims (step 2): who is editing what, and for how long.
        "--paths", "--intent", "--ttl", "--label", "--script", "--worktree",
        "--capabilities", "--expect", "--inputs", "--may-touch", "--result", "--spec", "--task", "--title", "--budget",
        // Landing (step 9): which branch, onto what.
        "--branch", "--into",
        // Stats (step 10): one session's share; session-context's --mode override.
        "--session", "--mode",
    ]

    /// The part of the line that can hold flags: everything before a bare `--`.
    private var flagged: ArraySlice<String> { raw.prefix { $0 != CommandOptions.literalSeparator } }

    /// What comes after that `--`: text, however it is spelled.
    private var literal: ArraySlice<String> {
        raw.drop { $0 != CommandOptions.literalSeparator }.dropFirst()
    }

    public func contains(_ flag: String) -> Bool { flagged.contains(flag) }

    /// Whether a token is a flag (`--urgent`, `-n`) rather than somebody's text.
    ///
    /// "Starts with a dash" is not the same thing. Notes and task text are
    /// ordinary words, and agents write `say "- done: parser"`, `say "-1 on this
    /// approach"`, `task add "--no-verify is being used"`: all of them were taken
    /// for flags and dropped, so the command answered with its usage text and the
    /// note never went out. A flag is one or two dashes and then a name — letters,
    /// digits, `-`, `_` — with no space in it.
    public static func looksLikeFlag(_ token: String) -> Bool {
        if token == "--" { return true }
        let dashes = token.prefix(while: { $0 == "-" }).count
        guard (1...2).contains(dashes) else { return false }
        let name = token.dropFirst(dashes)
        guard let first = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The value after the first occurrence of `flag`.
    ///
    /// A following `--something` is another flag, not a value: `--to --global`
    /// is somebody who forgot to say who, and reading "--global" as the
    /// addressee would route the note to nobody at all.
    public func value(after flag: String) -> String? {
        let line = flagged
        guard let index = line.firstIndex(of: flag), index + 1 < line.endIndex else { return nil }
        let value = line[index + 1]
        return Self.looksLikeFlag(value) ? nil : value
    }

    /// Every value given for a flag that may be repeated, such as `--attach`.
    public func values(after flag: String) -> [String] {
        let line = Array(flagged)
        var found: [String] = []
        var index = 0
        while index < line.count {
            if line[index] == flag, index + 1 < line.count, !Self.looksLikeFlag(line[index + 1]) {
                found.append(line[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return found
    }

    /// What is left once the flags and the values they eat are taken out.
    public var positional: [String] {
        let line = Array(flagged)
        var result: [String] = []
        var index = 0
        while index < line.count {
            let argument = line[index]
            if Self.valueFlags.contains(argument) {
                // Only skip the next token when it really is a value. `value(after:)`
                // returns nil for a following flag (so `--to --global` reads the
                // right way), but this unconditionally did `index += 2` and
                // swallowed that flag too. Reachable: `gentlemerge radar --project`
                // with no value left `single == false` downstream and swept every
                // registered project instead of the named one, with no error.
                let nextIsValue = index + 1 < line.count && !Self.looksLikeFlag(line[index + 1])
                index += nextIsValue ? 2 : 1
            } else if Self.looksLikeFlag(argument) || argument == "-" {
                // A bare "-" is the conventional "standard input" and never somebody's text.
                index += 1
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result + literal
    }
}
