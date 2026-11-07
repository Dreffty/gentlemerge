import Foundation

/// What went round the gate, counted afterwards.
///
/// `pre-commit` and `pre-merge-commit` only run for a plain commit and a true merge.
/// `git commit --no-verify`, `cherry-pick`, `revert`, `merge --ff-only` and `rebase`
/// never meet them. No hook can stop those, but one can notice: the post-* hooks look
/// at what just entered, judge it by the gate's own rules, and tell everybody. Whatever
/// passed the gate finds nothing here, so this is silent unless something got round.
public enum GateAudit {
    /// How it got in, which decides how to read what entered.
    public enum Entry: Sendable, Equatable {
        /// `post-commit`: any commit, including those of cherry-pick and revert.
        case commit
        /// `post-merge`: a fast-forward or a merge commit.
        case merge
        /// `post-rewrite`: the commits a rebase just wrote, by their new ids.
        case rebase(newCommits: [String])
    }

    /// A rebase's lines are `<old sha> <new sha> [extra]`; the new one is what entered.
    public static func newCommits(fromRewriteLines input: String) -> [String] {
        input.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ")
            return fields.count >= 2 ? String(fields[1]) : nil
        }
    }

    /// A rebase of thousands of commits should not hold the terminal for each one.
    private static let mostCommitsLookedAt = 200

    private static func git(_ arguments: [String], in repo: URL) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repo,
                  environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: 10)
    }

    /// Every path that changed with this entry. Unreadable means empty: this only
    /// ever adds a warning, so there is nothing to fail safe towards.
    static func filesEntered(_ entry: Entry, repo: URL) -> [String] {
        func changes(of commit: String) -> [String] {
            let output = git(["diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", commit], in: repo)
            return output.succeeded ? PrecommitCheck.parseStagedNameStatus(output.stdout) : []
        }
        switch entry {
        case .commit:
            // Where HEAD just was, not the commit's parent: an amend brought in only
            // what it changed, and this says so. With no reflog (a first commit, or
            // reflogs turned off) the commit itself is the honest answer.
            let moved = git(["diff", "--name-status", "-z", "HEAD@{1}", "HEAD"], in: repo)
            return moved.succeeded ? PrecommitCheck.parseStagedNameStatus(moved.stdout) : changes(of: "HEAD")
        case .merge:
            let moved = git(["diff", "--name-status", "-z", "ORIG_HEAD", "HEAD"], in: repo)
            return moved.succeeded ? PrecommitCheck.parseStagedNameStatus(moved.stdout) : []
        case .rebase(let commits):
            var seen = Set<String>()
            return commits.prefix(mostCommitsLookedAt).flatMap(changes(of:)).filter { seen.insert($0).inserted }
        }
    }

    /// The command that did it, told apart by the line git leaves in the reflog:
    /// `commit: …`, `commit (amend): …`, `cherry-pick: …`, `merge x: Fast-forward`.
    private static func how(_ entry: Entry, reflogSubject subject: String) -> String {
        if case .rebase = entry { return "git rebase" }
        let action = subject.prefix { $0 != ":" }.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = action.split(separator: " ").first.map(String.init) ?? ""
        switch entry {
        case .merge:
            let name = word.isEmpty ? "merge" : word
            return subject.contains("Fast-forward") ? "git \(name) (fast-forward)" : "git \(name) --no-verify"
        default:
            if word.isEmpty { return "git commit --no-verify" }
            guard word == "commit" else { return "git \(word)" }
            return action.contains("amend") ? "git commit --amend --no-verify" : "git commit --no-verify"
        }
    }

    /// Whether the gate itself just published this as a human skip. The hatch stays
    /// loud on a path the gate never saw (`GENTLEMERGE_SKIP=1 git cherry-pick`), and
    /// does not say the same thing twice on one it did.
    static func gatePublishedTheSkip(project: String, paths: Paths, now: Date) -> Bool {
        Ledger(url: paths.ledger).recent(limit: 50).contains {
            $0.title == "precommit.skipped" && $0.project == project && now.timeIntervalSince($0.at) < 120
        }
    }

    /// Looks at what entered and, when it lands on what somebody else holds, posts an
    /// urgent note and a ledger line. Returns what to tell the person at the terminal.
    @discardableResult
    public static func count(
        _ entry: Entry,
        repo: URL,
        project: String,
        me: String?,
        paths: Paths,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if EscapeHatch.isActive(environment), gatePublishedTheSkip(project: project, paths: paths, now: now) {
            return nil
        }
        let reflogSubject = git(["reflog", "-1", "--format=%gs"], in: repo).stdout
        // Every commit a rebase replays runs post-commit on its way through, with HEAD
        // detached. post-rewrite counts them all at the end, if the rebase gets there.
        if entry == .commit, reflogSubject.hasPrefix("rebase") { return nil }

        let files = filesEntered(entry, repo: repo)
        guard !files.isEmpty else { return nil }
        let violations = PrecommitGate.judge(files: files, me: me, project: project, paths: paths, now: now)
            .filter(\.blocking)
        guard !violations.isEmpty else { return nil }

        let how = how(entry, reflogSubject: reflogSubject)
        let who = me ?? "someone"
        let branch = RepoIdentity.currentBranch(at: repo.path) ?? "this branch"
        let held = holdings(violations)
        let text = "⚠ `\(how)` by \(who) went round the gate and put on \(branch) what others hold: \(held)."
            + " Git runs no gate on that path, so nothing stopped it. Read it before you write over it."
        AgentBus(paths: paths).post(AgentMessage(from: who, projectPath: project, text: text, kind: .urgent))
        Ledger(url: paths.ledger).append(LedgerEntry(
            at: now, kind: .note, project: project, title: Self.ledgerTitle,
            summary: "\(who) \(how): \(violations.count) violation(s) on \(branch)"
        ))
        return "gentlemerge: that went round the gate, onto what others hold: \(held). They have been told."
    }

    /// The line `stats --value` counts.
    public static let ledgerTitle = "gate.bypassed"

    /// `a.swift (hermes), b.swift (hermes)`, cut short: this goes into every other
    /// agent's context, and the first few say what to look at.
    private static func holdings(_ violations: [PrecommitGate.Violation]) -> String {
        let shown = 5
        let named = violations.prefix(shown).map { violation in
            violation.holder.map { "\(violation.path) (\($0))" } ?? violation.path
        }
        let rest = violations.count > shown ? ", +\(violations.count - shown) more" : ""
        return named.joined(separator: ", ") + rest
    }
}
