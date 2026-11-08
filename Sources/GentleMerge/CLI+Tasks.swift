import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    static func task(_ arguments: [String]) -> Int32 {
        // Only `--project` selects the directory here: a bare word is the task
        // text, not a path. This is the *project* — where the shared list lives.
        let directory = projectDirectory(arguments, allowPositional: false)
        // Who is adding it is a different question, and it is about the
        // *checkout*: `gentlemerge.label` is per worktree, so resolving the
        // author against the repository root credited the main checkout's label
        // and every worktree wrote "by claude" into the shared list.
        let checkout = checkoutDirectory(arguments, allowPositional: false)

        switch arguments.first {
        case nil, "list":
            let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
            guard !handoff.tasks.isEmpty else {
                print("No tasks for \(handoff.projectName).")
                return 0
            }
            // Merged in at render time, never stored in the file: the list you
            // read is the task list plus whoever is on it right now.
            let claimed = TaskClaims(paths: Paths.fromEnvironment()).active(for: directory)
            for (index, task) in handoff.tasks.enumerated() {
                let box = task.done ? "x" : " "
                let who = task.addedBy.map { " (\($0))" } ?? ""
                let progress = task.progressLabel.map { " · \($0)" } ?? ""
                // A finished task nobody released is not news; the claim on it
                // died with the work.
                let claim = task.done ? nil : claimed[task.id].map { " · \($0.annotation())" }
                print("\(index). [\(box)] \(task.text)\(progress)\(who)\(claim ?? "")")
                // Numbered, because that is what the step commands take.
                for (position, step) in task.steps.enumerated() {
                    print("     \(position). [\(step.done ? "x" : " ")] \(step.text)")
                }
            }
            return 0

        case "add":
            let text = positional(Array(arguments.dropFirst())).joined(separator: " ")
            guard !text.isEmpty else {
                FileHandle.standardError.write(Data("usage: gentlemerge task add \"what is left\"\n".utf8))
                return 64
            }
            let author: String
            do { author = try Identity.reconcile(explicit: value(after: "--by", in: arguments),
                resolved: Identity.resolve(cwd: checkout, provider: .unknown, paths: Paths.fromEnvironment())).label
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
            }
            let scrubbed = Redactor.scrub(text)
            guard !scrubbed.isSuppressed else {
                FileHandle.standardError.write(
                    Data("Not added — that was almost entirely \(scrubbed.summary).\n".utf8)
                )
                return 1
            }
            // Repeated `--step` rather than one string with separators in it:
            // an agent writing this line in bash gets quoting wrong far less
            // often than it gets embedded newlines or delimiters right.
            let steps = values(after: "--step", in: arguments)

            // Asked through the reporting API rather than by reading the list
            // first: `addTask` keeps the task that was already there and reports
            // nothing, so the old pre-check printed "Added to X" for a write
            // that had just failed (a read-only home, a file in the way) and
            // left the agent believing the task was on the board (audit
            // 2026-10-08).
            let (handoff, outcome) = ProjectRegistry.addTaskReporting(
                text, to: directory, by: author, steps: steps, paths: Paths.fromEnvironment()
            )
            let wanted = scrubbed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let filed = handoff.tasks.first { $0.text.caseInsensitiveCompare(wanted) == .orderedSame }

            switch outcome {
            case .refusedAsSecret, .empty:
                FileHandle.standardError.write(
                    Data("Not added — the task text could not be written down.\n".utf8)
                )
                return 1
            case .writeFailed:
                // The honest answer: the list is unwritable (read-only home, a
                // file where the directory should be), so nothing was recorded.
                FileHandle.standardError.write(
                    Data(("Not added — could not write \(handoff.projectName)'s task list."
                        + " See `gentlemerge doctor` for the home directory.\n").utf8)
                )
                return 1
            case .alreadyThere:
                let progress = filed?.progressLabel.map { " · \($0)" } ?? ""
                print("Already on \(handoff.projectName)'s list\(progress): \(scrubbed.text)")
                if !steps.isEmpty {
                    print("Nothing was changed. Add points with:"
                        + " gentlemerge task step add \"\(wanted)\" \"…\"")
                }
                return 0
            case .added:
                break
            }

            print("Added to \(handoff.projectName): \(scrubbed.text)")
            if scrubbed.didRedact { print("(\(scrubbed.summary) taken out)") }

            if let added = filed, !added.steps.isEmpty {
                print("  \(added.steps.count) points, none done yet:")
                for (position, step) in added.steps.enumerated() {
                    print("     \(position). [ ] \(step.text)")
                }
            }
            return 0

        case "done", "undone", "rm":
            let action = arguments[0]
            let words = positional(Array(arguments.dropFirst()))
            guard !words.isEmpty else {
                FileHandle.standardError.write(
                    Data("usage: gentlemerge task \(action) <number|text of the task>\n".utf8)
                )
                return 64
            }

            let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
            let target = resolveTask(words, in: handoff)

            guard let target else {
                FileHandle.standardError.write(
                    Data("No task matching “\(words.joined(separator: " "))”. Run `gentlemerge task list`.\n".utf8)
                )
                return 1
            }
            if action == "rm" {
                _ = ProjectRegistry.removeTask(target.id, in: directory, paths: Paths.fromEnvironment())
                print("Removed: \(target.text)")
            } else {
                _ = ProjectRegistry.setTask(
                    target.id, done: action == "done", in: directory, paths: Paths.fromEnvironment()
                )
                print("\(action == "done" ? "Done" : "Reopened"): \(target.text)")
            }
            // Finishing or dropping a task ends every claim on it, whoever made
            // them. Nobody should have to remember to hand back something that
            // no longer exists — and a forgotten claim is what makes the next
            // agent wait for nothing.
            if action != "undone" {
                let released = (try? TaskClaims(paths: Paths.fromEnvironment())
                    .releaseAll(target.id, in: directory)) ?? []
                if !released.isEmpty {
                    print("(claim released)")
                }
            }
            return 0

        case "claim":
            // Name collision with `task claim <n>` (about *what*, hours):
            // `--paths` present means a path claim — about *where*, minutes.
            if isSet("--paths", in: arguments) { return pathClaim(arguments) }
            return claim(arguments, in: directory)
        case "release":
            // Same collision: paths to hand back vs. a task number to drop.
            if isSet("--paths", in: arguments) { return pathRelease(arguments) }
            return claim(arguments, in: directory)

        case "step", "steps":
            return step(Array(arguments.dropFirst()), in: directory)

        default:
            FileHandle.standardError.write(
                Data(
                    ("usage: gentlemerge task [list|add <text> [--step \"…\"]…|done <n>|undone <n>"
                        + "|rm <n>|claim <n>|release <n>|step add|done|undone <task> <step>]"
                        + " [--project dir]\n").utf8
                )
            )
            return 64
        }
    }

    /// `task claim` — say out loud that you are on this one, before two agents
    /// spend an hour on the same task and find out by collision.
    ///
    /// The hard rule of the whole tool applies here more than anywhere: it
    /// reports; it never gates. A conflict exits 1 so a script can notice, and
    /// says who has it and how long they have had it — because the next move is
    /// a conversation. Nothing stops the second agent doing the work anyway,
    /// and nothing here locks a single file.
    static func claim(_ arguments: [String], in directory: String) -> Int32 {
        let action = arguments[0]
        let words = positional(Array(arguments.dropFirst()))
        guard !words.isEmpty else {
            FileHandle.standardError.write(
                Data("usage: gentlemerge task \(action) <number|text of the task> [--as label]\n".utf8)
            )
            return 64
        }

        let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
        guard let target = resolveTask(words, in: handoff) else {
            FileHandle.standardError.write(
                Data("No task matching “\(words.joined(separator: " "))”. Run `gentlemerge task list`.\n".utf8)
            )
            return 1
        }

        // `--as` for the cases `defaultAuthor()` cannot see: a wrapper running
        // on Hermes' behalf, or a subagent that wants its own name on it.
        let label: String
        do { label = try actingLabel(arguments, explicit: value(after: "--as", in: arguments)) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1 }
        let claims = TaskClaims(paths: Paths.fromEnvironment())

        do {
            if action == "claim" {
                let session = claims.currentSessionID(for: label, in: directory)
                if let held = try claims.claim(target, in: directory, by: label, sessionID: session) {
                    FileHandle.standardError.write(
                        Data("\(target.text) — \(held.conflictLine())\n".utf8)
                    )
                    return 1
                }
                print("Claimed by \(label): \(target.text)")
                print("The others see it on their next turn. It lapses on its own"
                    + " in \(hours(TaskClaims.lifetime))h, or when this session ends.")
                return 0
            }

            if try claims.release(target.id, in: directory, by: label) != nil {
                print("Released: \(target.text)")
                return 0
            }
            if let held = claims.active(for: directory)[target.id] {
                print("Not yours to release — \(held.conflictLine())")
                return 1
            }
            print("Nobody had claimed: \(target.text)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not \(action): \(error)\n".utf8))
            return 1
        }
    }

    /// The briefing gives agents the task *text*, not a number. Making them
    /// list first just to get an index is a step they will skip.
    static func resolveTask(_ words: [String], in handoff: ProjectHandoff) -> TaskItem? {
        guard let first = words.first else { return nil }
        if let index = Int(first), words.count == 1 {
            return handoff.tasks.indices.contains(index) ? handoff.tasks[index] : nil
        }
        let needle = words.joined(separator: " ").lowercased()
        return handoff.tasks.first { $0.text.lowercased().contains(needle) }
            ?? handoff.tasks.first { needle.contains($0.text.lowercased()) }
    }

    /// Same rule one level down: a number is a position, anything else is
    /// matched against the text.
    static func resolveStep(_ word: String, in task: TaskItem) -> Int? {
        if let index = Int(word), task.steps.indices.contains(index) { return index }
        let needle = word.lowercased()
        return task.steps.firstIndex { $0.text.lowercased().contains(needle) }
            ?? task.steps.firstIndex { needle.contains($0.text.lowercased()) }
    }

    /// `task step done <task> <step>` — the command that gets run mid-work, so
    /// both selectors take either a number from `task list` or a piece of the
    /// text the briefing already handed the agent.
    static func step(_ arguments: [String], in directory: String) -> Int32 {
        let action = arguments.first ?? ""
        guard ["add", "done", "undone"].contains(action) else {
            FileHandle.standardError.write(
                Data("usage: gentlemerge task step [add|done|undone] \"<task>\" \"<step>\"\n".utf8)
            )
            return 64
        }

        let words = positional(Array(arguments.dropFirst()))
        guard words.count >= 2 else {
            FileHandle.standardError.write(
                Data("usage: gentlemerge task step \(action) \"<task>\" \"<step>\"\n".utf8)
            )
            return 64
        }

        let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
        guard let (task, stepText) = split(words, in: handoff, requiringStep: action != "add") else {
            FileHandle.standardError.write(
                Data("No task matching “\(words[0])”. Run `gentlemerge task list`.\n".utf8)
            )
            return 1
        }

        if action == "add" {
            let scrubbed = Redactor.scrub(stepText)
            guard !scrubbed.isSuppressed else {
                FileHandle.standardError.write(
                    Data("Not added — that was almost entirely \(scrubbed.summary).\n".utf8)
                )
                return 1
            }
            let before = task.steps.count
            let updated = ProjectRegistry.addStep(stepText, toTask: task.id, in: directory)
            guard let now = updated.tasks.first(where: { $0.id == task.id }) else { return 1 }
            // The registry keeps the point that was already there rather than
            // filing it twice, so the count is what says whether anything
            // actually happened.
            guard now.steps.count > before else {
                print("\(now.text) · \(now.progressLabel ?? "") — that point is already on the list.")
                return 0
            }
            print("\(now.text) · \(now.progressLabel ?? "") — added: \(scrubbed.text)")
            if scrubbed.didRedact { print("(\(scrubbed.summary) taken out)") }
            return 0
        }

        guard let index = resolveStep(stepText, in: task) else {
            FileHandle.standardError.write(
                Data("No step matching “\(stepText)” under “\(task.text)”.\n".utf8)
            )
            return 1
        }

        let updated = ProjectRegistry.setStep(
            at: index,
            ofTask: task.id,
            done: action == "done",
            in: directory
        )
        guard let now = updated.tasks.first(where: { $0.id == task.id }),
              now.steps.indices.contains(index)
        else { return 1 }
        print("\(action == "done" ? "Done" : "Reopened"): \(now.steps[index].text)")
        print("\(now.text) · \(now.progressLabel ?? "")\(now.done ? " · task complete" : "")")
        return 0
    }

    /// Where the task selector ends and the step selector begins.
    ///
    /// Quoting each of the two is what an agent writing a shell line gets
    /// wrong, so the split is found rather than demanded: every cut is tried,
    /// shortest task selector first, and the first one where *both* halves name
    /// something real wins. Requiring both is what stops a one-word task
    /// selector swallowing half of the step.
    static func split(
        _ words: [String],
        in handoff: ProjectHandoff,
        requiringStep: Bool
    ) -> (task: TaskItem, step: String)? {
        var fallback: (task: TaskItem, step: String)?

        for length in 1..<words.count {
            guard let task = resolveTask(Array(words.prefix(length)), in: handoff) else { continue }
            let rest = words.dropFirst(length).joined(separator: " ")
            if !requiringStep || resolveStep(rest, in: task) != nil { return (task, rest) }
            // Kept so the failure can name the task it did find, which is a far
            // more useful thing to print than "no task matching …".
            if fallback == nil { fallback = (task, rest) }
        }

        return fallback
    }
}
