import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - helpers

    static func intValue(after flag: String, in arguments: [String]) -> Int? {
        value(after: flag, in: arguments).flatMap(Int.init)
    }

    /// Every occurrence of a repeatable flag, in the order they were written —
    /// the order the steps end up in.
    // Taking a command line apart lives in `CommandArguments`, where a test can
    // reach it. These stay as the shape every call site already uses.

    static func values(after flag: String, in arguments: [String]) -> [String] {
        CommandArguments(arguments).values(after: flag)
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        CommandArguments(arguments).value(after: flag)
    }

    static func positional(_ arguments: [String]) -> [String] {
        CommandArguments(arguments).positional
    }

    /// Whether a flag was given, ahead of any `--`: `say -- --global` is a note
    /// that says "--global", not a note for every project.
    static func isSet(_ flag: String, in arguments: [String]) -> Bool {
        CommandArguments(arguments).contains(flag)
    }

    /// `--help` or `-h` anywhere before a `--`. No command takes a `-h` of its
    /// own, and answering when somebody meant something else costs them a line,
    /// while `land x -h` taken for a command merges a branch.
    static func asksForHelp(_ arguments: [String]) -> Bool {
        arguments.prefix { $0 != "--" }.contains { $0 == "--help" || $0 == "-h" }
    }

    /// The entries of the usage that describe one command, each with the
    /// indented lines under it. Nil when the usage has none.
    static func usage(of command: String, in text: String) -> String? {
        let entry = "  gentlemerge "
        var kept: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(entry) {
                inside = line.dropFirst(entry.count).split(separator: " ").first.map(String.init) == command
            } else if !line.hasPrefix(" ") {
                inside = false
            }
            if inside { kept.append(line) }
        }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    static func printUsage(of command: String? = nil) {
        if let command, let entries = usage(of: command, in: usageText) {
            print(entries)
        } else {
            print(usageText)
        }
    }
}
