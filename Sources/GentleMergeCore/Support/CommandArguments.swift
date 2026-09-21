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

    public func contains(_ flag: String) -> Bool { raw.contains(flag) }

    /// The value after the first occurrence of `flag`.
    ///
    /// A following `--something` is another flag, not a value: `--to --global`
    /// is somebody who forgot to say who, and reading "--global" as the
    /// addressee would route the note to nobody at all.
    public func value(after flag: String) -> String? {
        guard let index = raw.firstIndex(of: flag), index + 1 < raw.count else { return nil }
        let value = raw[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    /// Every value given for a flag that may be repeated, such as `--attach`.
    public func values(after flag: String) -> [String] {
        var found: [String] = []
        var index = 0
        while index < raw.count {
            if raw[index] == flag, index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                found.append(raw[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return found
    }

    /// What is left once the flags and the values they eat are taken out.
    public var positional: [String] {
        var result: [String] = []
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if Self.valueFlags.contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result
    }
}
