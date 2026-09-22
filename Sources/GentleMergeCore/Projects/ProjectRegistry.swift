import Foundation

public struct ProjectSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var lastSeenAt: Date
    public var lastProvider: AgentProvider?

    public init(path: String, name: String, lastSeenAt: Date, lastProvider: AgentProvider? = nil) {
        self.path = path
        self.name = name
        self.lastSeenAt = lastSeenAt
        self.lastProvider = lastProvider
    }
}

/// Every project an agent has worked in, and the handoff file that carries the
/// thread between sessions, between models, and between you and them.
public struct ProjectRegistry: Sendable {
    public private(set) var projects: [ProjectSummary]
    private let url: URL

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONCoding.decoder().decode([ProjectSummary].self, from: data) {
            projects = stored
        } else {
            projects = []
        }
    }

    // MARK: - Discovery

    /// A session's cwd can be any subdirectory; the repository is the thing
    /// that has an identity worth remembering.
    ///
    /// The repository, note — not the checkout. Every worktree of a repository
    /// resolves to the same project, so five agents in five worktrees share one
    /// bus, one task list and one handoff instead of five silos that cannot see
    /// each other. `RepoIdentity` explains why that is worth a comment.
    public static func canonicalPath(for path: String) -> String {
        if let repository = RepoIdentity.mainWorktreeRoot(for: path) { return repository }
        return PathExtractor.normalized(path)
    }

    @discardableResult
    public mutating func seen(
        path rawPath: String,
        provider: AgentProvider?,
        at date: Date
    ) -> String {
        // Resolving the repository root costs a `git` process, so a path we
        // already know about short-circuits it — events arrive far more often
        // than new projects appear.
        let path = knownRoot(containing: rawPath) ?? Self.canonicalPath(for: rawPath)
        if let index = projects.firstIndex(where: { $0.path == path }) {
            guard date > projects[index].lastSeenAt else { return path }
            projects[index].lastSeenAt = date
            if let provider { projects[index].lastProvider = provider }
        } else {
            projects.append(
                ProjectSummary(
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    lastSeenAt: date,
                    lastProvider: provider
                )
            )
        }
        projects.sort { $0.lastSeenAt > $1.lastSeenAt }
        if projects.count > 60 { projects = Array(projects.prefix(60)) }
        save()
        return path
    }

    func knownRoot(containing rawPath: String) -> String? {
        let normalized = PathExtractor.normalized(rawPath)
        return projects
            .map(\.path)
            .filter { normalized == $0 || normalized.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    public mutating func forget(path: String) {
        projects.removeAll { $0.path == path }
        save()
    }


    /// Drops the registry entries that were only ever a worktree of a project
    /// already listed, keeping the newest `lastSeenAt` of the two.
    ///
    /// Without this the fix to `canonicalPath` would be defeated by the cache
    /// in front of it: `seen()` short-circuits on the longest known path that
    /// contains the one it was handed, and a stale worktree entry is a longer
    /// match than the repository it belongs to.
    @discardableResult
    public mutating func foldWorktrees() -> [String] {
        var folded: [String] = []

        for summary in projects {
            let root = Self.canonicalPath(for: summary.path)
            // Unchanged means it is its own project — or that the directory is
            // gone and git can no longer tell us, which is not ours to guess at.
            guard root != summary.path else { continue }
            folded.append(summary.path)

            if let index = projects.firstIndex(where: { $0.path == root }) {
                if summary.lastSeenAt > projects[index].lastSeenAt {
                    projects[index].lastSeenAt = summary.lastSeenAt
                    projects[index].lastProvider = summary.lastProvider ?? projects[index].lastProvider
                }
            } else {
                projects.append(
                    ProjectSummary(
                        path: root,
                        name: URL(fileURLWithPath: root).lastPathComponent,
                        lastSeenAt: summary.lastSeenAt,
                        lastProvider: summary.lastProvider
                    )
                )
            }
        }

        guard !folded.isEmpty else { return [] }
        projects.removeAll { folded.contains($0.path) }
        projects.sort { $0.lastSeenAt > $1.lastSeenAt }
        save()
        return folded
    }

    private func save() {
        do {
            // No merge here (unlike state/sessions): `forget` and `fold` are
            // deliberate deletions, and a union would resurrect what they
            // just removed. Concurrent drains serialize on the drain lock;
            // a project entry lost to a race is re-seen on the next event,
            // so this converges without fighting explicit removals.
            try AtomicFile.write(try JSONCoding.encoder(pretty: true).encode(projects), to: url)
        } catch {
            Log.error("could not save projects: \(error.localizedDescription)")
        }
    }

    // MARK: - The handoff file

    /// Reads the file if it exists, then refreshes the commit list from git so
    /// the record is true even when every agent forgot to write it down.
    public static func handoff(for projectPath: String, refreshingCommits: Bool = true) -> ProjectHandoff {
        let path = canonicalPath(for: projectPath)
        let fileURL = ProjectHandoff.fileURL(for: path)

        var handoff: ProjectHandoff
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            handoff = HandoffMarkdown.parse(text, projectPath: path)
        } else {
            handoff = ProjectHandoff(projectPath: path)
        }
        handoff.projectPath = path

        if refreshingCommits {
            handoff.commits = recentCommits(in: path)
        }
        return handoff
    }

    @discardableResult
    public static func save(_ handoff: ProjectHandoff) -> Bool {
        var updated = handoff
        updated.updatedAt = Date()
        let fileURL = ProjectHandoff.fileURL(for: handoff.projectPath)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFile.write(Data(HandoffMarkdown.render(updated).utf8), to: fileURL)
            return true
        } catch {
            Log.error("could not write handoff: \(error.localizedDescription)")
            return false
        }
    }

    public static func exists(for projectPath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: ProjectHandoff.fileURL(for: canonicalPath(for: projectPath)).path
        )
    }

    /// How far back the handoff remembers. Three was enough when the list was
    /// only there to say what the last session did; a list you are meant to
    /// check your own files against has to cover the other agents' morning too.
    public static let commitHistoryDepth = 8

    public static func recentCommits(
        in projectPath: String,
        limit: Int = commitHistoryDepth
    ) -> [CommitRecord] {
        commits(in: projectPath, range: nil, limit: limit)
    }

    /// The same read with a revision range — `baseline..HEAD` for what landed
    /// while you were working, `HEAD..@{upstream}` for what you have not
    /// pulled. An unreachable range is a failed `git log`, which is an empty
    /// list: never an error, never a guess.
    public static func commits(
        in projectPath: String,
        range: String?,
        limit: Int = commitHistoryDepth
    ) -> [CommitRecord] {
        guard GitSnapshot.isRepository(projectPath) else { return [] }

        // Record separators between commits, unit separators between fields:
        // `--name-only` puts the paths on their own lines, and a subject with a
        // dash or a newline in it must not be able to look like either.
        var arguments = [
            "git", "log", "-\(limit)", "--name-only",
            "--format=%x1e%H%x1f%aI%x1f%s%x1f%an",
        ]
        if let range, !range.isEmpty { arguments.append(range) }

        let output = Shell.run(
            "/usr/bin/env",
            arguments,
            in: URL(fileURLWithPath: projectPath),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 20
        )
        guard output.succeeded else { return [] }

        return parseLog(output.stdout)
    }

    /// Split out from the git call so the format can be tested without a
    /// repository, and so a change to it fails loudly rather than quietly
    /// producing commits with no files.
    static func parseLog(_ raw: String) -> [CommitRecord] {
        raw.components(separatedBy: "\u{1e}").compactMap { record -> CommitRecord? in
            var lines = record.components(separatedBy: "\n")
            guard !lines.isEmpty else { return nil }

            let fields = lines.removeFirst().components(separatedBy: "\u{1f}")
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }

            return CommitRecord(
                sha: fields[0],
                date: ISO8601DateFormatter.gentleMerge.date(from: fields[1])
                    ?? ISO8601DateFormatter.gentleMergeFractional.date(from: fields[1])
                    ?? Date(),
                subject: fields[2],
                author: fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil,
                // A merge lists nothing here, and that is the truth: it changed
                // no file on its own.
                files: lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            )
        }
    }

    /// HEAD, or nil when there is no revision to seal a map with.
    public static func currentCommit(in projectPath: String) -> String? {
        // One process instead of two: outside a repository, and inside one with
        // no commits yet, `rev-parse HEAD` fails — and both answers are "there
        // is nothing to pin this to".
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "rev-parse", "HEAD"],
            in: URL(fileURLWithPath: projectPath),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded else { return nil }
        let sha = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// The project map, rebuilt when it is missing or when the commit it was
    /// sealed with is no longer HEAD.
    ///
    /// Rebuilding walks the project, so it is a session-start job, not
    /// something every read of the handoff pays for. `rebuildingWhenStale:
    /// false` is the reader's version: take what was cached and let the caller
    /// say out loud that it has drifted.
    public static func refreshedMap(
        for handoff: ProjectHandoff,
        rebuildingWhenStale: Bool
    ) -> (map: ProjectMap?, head: String?, rebuilt: Bool) {
        let head = currentCommit(in: handoff.projectPath)
        if let existing = handoff.map, existing.isSealed(with: head) || !rebuildingWhenStale {
            return (existing, head, false)
        }
        let rebuilt = ProjectMap.build(for: handoff.projectPath, head: head)
        return (rebuilt.isEmpty ? nil : rebuilt, head, true)
    }

    // MARK: - Tasks

    @discardableResult
    public static func addTask(
        _ text: String,
        to projectPath: String,
        by author: String?,
        steps: [String] = []
    ) -> ProjectHandoff {
        var handoff = handoff(for: projectPath)

        // This file gets committed and read by every agent. A key written into
        // a task would outlive the session that leaked it.
        let scrubbed = Redactor.scrub(text)
        guard !scrubbed.isSuppressed else {
            Log.error("refused to add a task: it was almost entirely \(scrubbed.summary)")
            return handoff
        }
        let trimmed = scrubbed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !handoff.tasks.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            handoff.tasks.append(
                TaskItem(text: trimmed, steps: cleanedSteps(steps), addedBy: author)
            )
        }
        save(handoff)
        return handoff
    }

    /// Every point goes through the same filter as the task itself, and one
    /// that is almost entirely secret is dropped rather than written down.
    static func cleanedSteps(_ texts: [String]) -> [TaskStep] {
        texts.compactMap { raw in
            let scrubbed = Redactor.scrub(raw)
            guard !scrubbed.isSuppressed else {
                Log.error("dropped a step: it was almost entirely \(scrubbed.summary)")
                return nil
            }
            let trimmed = scrubbed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : TaskStep(text: trimmed)
        }
    }

    /// Ticks one point of a task. Indexed, not matched by text: two points of
    /// the same task can legitimately read the same and the caller has already
    /// decided which one it meant.
    @discardableResult
    public static func setStep(
        at index: Int,
        ofTask taskID: String,
        done: Bool,
        in projectPath: String
    ) -> ProjectHandoff {
        var handoff = handoff(for: projectPath)
        if let task = handoff.tasks.firstIndex(where: { $0.id == taskID }),
           handoff.tasks[task].steps.indices.contains(index) {
            handoff.tasks[task].steps[index].done = done
        }
        save(handoff)
        return handoff
    }

    /// A plan that grew a point once the work started. Same scrubbing, and no
    /// duplicates within the one task.
    @discardableResult
    public static func addStep(
        _ text: String,
        toTask taskID: String,
        in projectPath: String
    ) -> ProjectHandoff {
        var handoff = handoff(for: projectPath)
        guard let index = handoff.tasks.firstIndex(where: { $0.id == taskID }),
              let step = cleanedSteps([text]).first,
              !handoff.tasks[index].steps.contains(where: {
                  $0.text.caseInsensitiveCompare(step.text) == .orderedSame
              })
        else {
            save(handoff)
            return handoff
        }
        handoff.tasks[index].steps.append(step)
        save(handoff)
        return handoff
    }

    @discardableResult
    public static func setTask(_ id: String, done: Bool, in projectPath: String) -> ProjectHandoff {
        var handoff = handoff(for: projectPath)
        if let index = handoff.tasks.firstIndex(where: { $0.id == id }) {
            handoff.tasks[index].done = done
        }
        save(handoff)
        return handoff
    }

    @discardableResult
    public static func removeTask(_ id: String, in projectPath: String) -> ProjectHandoff {
        var handoff = handoff(for: projectPath)
        handoff.tasks.removeAll { $0.id == id }
        save(handoff)
        return handoff
    }

    // MARK: - Session context

    /// How many unfinished points of one task the briefing spells out. Enough
    /// to pick the work back up, few enough that a ten-point task does not
    /// cost ten lines of somebody's context window.
    public static let stepPreviewLimit = 3

    /// How many commits the briefing spells out. The handoff file keeps more —
    /// it is read on purpose, while this is charged to every session's context
    /// window whether it needed the history or not.
    public static let briefingCommitLimit = 5

    /// The block handed to an agent the moment a session starts. Short on
    /// purpose: it is paid for out of the session's context window.
    ///
    /// `claims` is passed in rather than read here: this is a pure render of a
    /// handoff plus whatever the caller knows about who is on what, and the
    /// claims live in a file this type has no business opening. An empty map —
    /// the default, and what every older caller gets — annotates nothing.
    public static func sessionContext(
        for projectPath: String,
        taskLimit: Int = 12,
        refreshingMap: Bool = true,
        claims: [String: TaskClaim] = [:]
    ) -> String? {
        var handoff = handoff(for: projectPath)
        let (map, head, rebuilt) = refreshedMap(for: handoff, rebuildingWhenStale: refreshingMap)
        handoff.map = map

        // Writing the map back is what stops the next session walking the tree
        // again. Two conditions, both about consent: a caller that asked not to
        // refresh asked for a read, and a project with no handoff file has not
        // asked us to leave one behind.
        if refreshingMap, rebuilt, map != nil, exists(for: handoff.projectPath) { save(handoff) }

        let open = handoff.openTasks.prefix(taskLimit)
        guard map != nil || !handoff.commits.isEmpty || !open.isEmpty || !handoff.notes.isEmpty else {
            return nil
        }

        var lines = ["Where \(handoff.projectName) stood when the last session ended (from GentleMerge):"]

        if let map {
            lines.append("")
            lines += map.briefingLines(head: head)
        }

        // Held out of the scrub below and put back afterwards; see the note
        // where they go back in.
        var shas: [String] = []

        if !handoff.commits.isEmpty {
            lines.append("")
            lines.append("Recent commits:")
            // The files each one touched are deliberately *not* here: eight
            // commits' worth of paths would cost more context than the whole
            // rest of the briefing, and `precommit` reads them on demand.
            for commit in handoff.commits.prefix(briefingCommitLimit) {
                let who = commit.author.map { " · \($0)" } ?? ""
                shas.append(commit.shortSHA)
                lines.append(
                    "- \(shaPlaceholder(shas.count - 1))"
                        + " \(HandoffMarkdown.dayFormatter.string(from: commit.date))"
                        + "\(who) — \(commit.subject)"
                )
            }
        }

        if !open.isEmpty {
            lines.append("")
            lines.append("Open tasks:")
            for task in open {
                let who = task.addedBy.map { " (from \($0))" } ?? ""
                let progress = task.progressLabel.map { " — \($0) done" } ?? ""
                let claim = claims[task.id].map { " · \($0.annotation())" } ?? ""
                lines.append("- \(task.text)\(progress)\(who)\(claim)")

                // Only what is left. The points already ticked off are the part
                // the next session does not need to be told about, and the
                // whole list is paid for out of its context window.
                let pending = task.openSteps
                for step in pending.prefix(stepPreviewLimit) {
                    lines.append("  - [ ] \(step.text)")
                }
                if pending.count > stepPreviewLimit {
                    lines.append("  - …and \(pending.count - stepPreviewLimit) more in the file")
                }
            }
            if handoff.openTasks.count > taskLimit {
                lines.append("- …and \(handoff.openTasks.count - taskLimit) more in the file")
            }
        }

        if !handoff.notes.isEmpty {
            lines.append("")
            lines.append("Notes: \(handoff.notes.prefix(500))")
        }

        lines.append("")
        lines.append(
            "This lives in .gentlemerge/HANDOFF.md. When you finish something or commit, update the"
                + " task list there so the next session — or a different model — does not lose the thread."
        )
        // Said every session, unconditionally. Somebody else committing to a
        // file you have open is not a state we can detect in advance and warn
        // about — the whole point is that you ask before you write.
        lines.append(
            "Before you commit, run `gentlemerge precommit`: it tells you whether anyone else has"
                + " committed to the files you have changed since this session started, so you do not"
                + " write over their work. The full list, with the files each commit touched, is in"
                + " the Recent commits section of that file."
        )
        // Only said when there is something claimed: a rule nobody needs today
        // is a rule that teaches the reader to skim the block.
        if open.contains(where: { claims[$0.id] != nil }) {
            lines.append(
                "Somebody is already on the tasks marked claimed — talk to them rather than doubling"
                    + " up, and run `gentlemerge task claim \"…\"` before you start on one yourself."
            )
        }
        // The file is hand-editable by anyone, so it gets the same treatment as
        // anything else crossing into another agent's context.
        var text = Redactor.scrub(lines.joined(separator: "\n")).text

        // And now the shas, which were never the filter's business. A short sha
        // is seven hex characters, so roughly one commit in thirty comes out
        // all digits and looks exactly like the long numbers the filter exists
        // to eat — and a commit whose sha reads `[redacted number]` is one
        // nobody can go and read. Everything else on the line, the subject
        // included, went through the filter like the rest of the briefing.
        for (index, sha) in shas.enumerated() {
            text = text.replacingOccurrences(of: shaPlaceholder(index), with: sha)
        }
        return text
    }

    /// Deliberately unlike anything the filter looks for, and unlike anything
    /// a person would type into a handoff by hand.
    static func shaPlaceholder(_ index: Int) -> String { "«gentlemerge-sha-\(index)»" }

    // MARK: - Setting a project up

    /// The pointer that teaches an agent to read the handoff even when the
    /// session-start hook is not in play (Codex, a fresh clone, a colleague).
    public static let pointerMarker = "<!-- gentlemerge:handoff -->"

    public static func pointerSection(for projectName: String) -> String {
        """
        \(pointerMarker)
        ## Agent handoff

        Read `.gentlemerge/HANDOFF.md` before doing anything in \(projectName): it holds the last
        commits — with the files each one touched — and the open task list. When you finish
        something, or when you commit, update the task list there so the next session — or a
        different model — picks up where you left off.

        Before every commit, run `gentlemerge precommit`. It compares the files you have changed
        against the commits that landed since your session started, so you find out that somebody
        else already changed one of them *before* you write over their work rather than after.
        """
    }

    /// Creates the handoff file and points the project's agent instructions at
    /// it. Idempotent: running it twice changes nothing.
    @discardableResult
    public static func initialize(projectPath: String, instructionFiles: [String] = ["CLAUDE.md", "AGENTS.md"]) throws -> ProjectHandoff {
        let path = canonicalPath(for: projectPath)
        var handoff = handoff(for: path)
        _ = save(handoff)
        handoff = self.handoff(for: path)

        for name in instructionFiles {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard !existing.contains(pointerMarker) else { continue }
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            let updated = existing + separator + pointerSection(for: handoff.projectName) + "\n"
            try AtomicFile.write(Data(updated.utf8), to: url)
        }

        return handoff
    }
}
