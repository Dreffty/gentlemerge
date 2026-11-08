import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - watch (phase 6)

    /// "Tell me when Codex finishes that migration."
    ///
    /// Asked once, answered on the bus you already read: the app notices the
    /// event and posts a note to your label, which arrives on your next turn
    /// through the hook you already have. Nothing here waits on anything, and a
    /// rule nobody's event ever matches lapses on its own after 48h.
    static func watch(_ arguments: [String]) -> Int32 {
        let watches = Watches(paths: Paths.fromEnvironment())

        switch arguments.first {
        case "session-end", "end":
            return addWatch(.sessionEnd, Array(arguments.dropFirst()), to: watches)
        case "idle":
            return addWatch(.sessionIdle, Array(arguments.dropFirst()), to: watches)
        case "task":
            return addWatch(.taskDone, Array(arguments.dropFirst()), to: watches)
        case nil, "list":
            return listWatches(watches)
        case "rm", "cancel":
            return removeWatch(Array(arguments.dropFirst()), from: watches)
        default:
            FileHandle.standardError.write(
                Data(
                    ("usage: gentlemerge watch [session-end <id|label>|idle <label>|task <n|text>]"
                        + " [--note \"…\"] [--project dir] [--global] [--as label]\n"
                        + "       gentlemerge watch list | rm <id>\n").utf8
                )
            )
            return 64
        }
    }

    static func addWatch(
        _ kind: WatchRule.Kind,
        _ arguments: [String],
        to watches: Watches
    ) -> Int32 {
        let words = positional(arguments)
        guard !words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let form: String
            switch kind {
            case .sessionEnd: form = "session-end <session id or agent label>"
            case .sessionIdle: form = "idle <agent label>"
            case .taskDone: form = "task <number|text of the task>"
            }
            FileHandle.standardError.write(Data("usage: gentlemerge watch \(form) [--note \"…\"]\n".utf8))
            return 64
        }

        // Scoped to the project you are standing in, like `say`: a watch that
        // fires on any agent finishing anywhere is the noise this replaces.
        let directory = projectDirectory(arguments, allowPositional: false)
        let scoped = isSet("--global", in: arguments) ? nil : directory
        // Whoever asks is who gets told. `--as` covers the cases the environment
        // cannot see — a wrapper asking on Hermes' behalf, mostly.
        let owner: String
        do { owner = try actingLabel(arguments, explicit: value(after: "--as", in: arguments)) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1 }

        // Written by a human or by an agent, and it ends up in somebody else's
        // context: scrubbed here as well as on its way onto the bus.
        var note: String?
        if let raw = value(after: "--note", in: arguments) {
            let scrubbed = Redactor.scrub(raw)
            guard !scrubbed.isSuppressed else {
                FileHandle.standardError.write(
                    Data("Not watched — that note was almost entirely \(scrubbed.summary).\n".utf8)
                )
                return 1
            }
            note = scrubbed.text
        }

        var target = words.joined(separator: " ")
        var subject: String

        if kind == .taskDone {
            let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
            guard let task = resolveTask(words, in: handoff) else {
                FileHandle.standardError.write(
                    Data("No task matching “\(target)”. Run `gentlemerge task list`.\n".utf8)
                )
                return 1
            }
            guard !task.done else {
                // Filing it would be a rule that can only fire on the day
                // somebody reopens the task — never what was meant.
                print("Already done: \(task.text)")
                return 0
            }
            // The id and not the text: a task renamed by hand is a different
            // task, and telling you it finished would be a lie.
            target = task.id
            subject = "“\(task.text)” is ticked off"
        } else {
            target = words[0]
            subject = kind == .sessionEnd ? "\(target)'s session ends" : "\(target) finishes a turn"
        }

        let rule = WatchRule(
            owner: owner,
            projectPath: scoped,
            kind: kind,
            target: target,
            note: note
        )
        do {
            try watches.add(rule)
        } catch {
            FileHandle.standardError.write(Data("could not file that watch: \(error)\n".utf8))
            return 1
        }

        let scope = rule.projectName.map { "in \($0)" } ?? "in every project"
        print("Watching \(scope): \(subject) → \(owner)")
        print("It fires once, as a note on the bus you already read,"
            + " and lapses on its own in \(hours(Watches.timeToLive))h. Nothing waits on it.")
        print("id \(rule.shortID) — call it off with `gentlemerge watch rm \(rule.shortID)`")
        return 0
    }

    static func listWatches(_ watches: Watches) -> Int32 {
        // Standing rules only. What has already fired is on the bus, where the
        // owner reads it; repeating it here would be two places to look.
        let standing = watches.pending()
        guard !standing.isEmpty else {
            print("Nothing being watched. `gentlemerge watch idle codex` and you will be told.")
            return 0
        }
        print("Standing watches — each fires once, then lapses:")
        for rule in standing { print("  \(rule.listLine())") }
        return 0
    }

    static func removeWatch(_ arguments: [String], from watches: Watches) -> Int32 {
        guard let prefix = positional(arguments).first else {
            FileHandle.standardError.write(Data("usage: gentlemerge watch rm <id>\n".utf8))
            return 64
        }

        let found = watches.matching(prefix: prefix)
        guard !found.isEmpty else {
            FileHandle.standardError.write(
                Data("No standing watch starting with “\(prefix)”. Run `gentlemerge watch list`.\n".utf8)
            )
            return 1
        }
        guard found.count == 1 else {
            FileHandle.standardError.write(Data("“\(prefix)” names \(found.count) watches — type more of the id.\n".utf8))
            return 1
        }

        do {
            // An append, not a rewrite: this runs in an agent's shell, and the
            // app is the only process that compacts the file.
            let cancelled = try watches.retire(ids: [found[0].id])
            print(cancelled.isEmpty ? "Already gone." : "Called off: \(found[0].listLine())")
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not call that watch off: \(error)\n".utf8))
            return 1
        }
    }
}
