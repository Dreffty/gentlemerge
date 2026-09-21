import Foundation

/// Bring an agent's branch home: rebase onto main, run the project's checks,
/// fast-forward main, and tell the bus what landed.
///
/// Order is the safety: nothing touches main until the rebase is clean and the
/// checks pass, so a failing landing leaves main exactly where it was. The
/// worktree must be clean first — landing half-written files is how
/// somebody's afternoon ends up inside somebody else's release.
public enum Landing {
    public struct ConflictDetail: Sendable, Equatable {
        public var path: String
        public var authors: [String]

        public init(path: String, authors: [String]) {
            self.path = path
            self.authors = authors
        }
    }

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case notRepository
        case dirty(files: [String])
        case unknownBranch(String)
        case unknownInto(String)
        case sameBranch(String)
        case wrongCheckout(expected: String, actual: String?)
        case noMergeBase(branch: String, into: String)
        case conflicts(branch: String, into: String, details: [ConflictDetail])
        case rebaseFailed(into: String, output: String)
        case checksFailed([CheckResult])
        case cannotFastForward(reason: String)
        case gitTooOld(String)

        public var description: String {
            switch self {
            case .notRepository:
                return "not a git repository — nothing to land"
            case .dirty(let files):
                return "worktree is not clean:\n"
                    + files.map({ "  \($0)" }).joined(separator: "\n")
                    + "\ncommit or stash before landing."
            case .unknownBranch(let branch):
                return "no branch `\(branch)` here"
            case .unknownInto(let into):
                return "no branch `\(into)` to land onto"
            case .sameBranch(let branch):
                return "`\(branch)` is already the landing target — nothing to land"
            case .wrongCheckout(let expected, let actual):
                return "not on `\(expected)` (on `\(actual ?? "a detached HEAD")`)"
                    + " — land runs from the branch's own worktree"
            case .noMergeBase(let branch, let into):
                return "`\(branch)` and `\(into)` share no history — a rebase would fail too"
            case .conflicts(let branch, let into, let details):
                var lines = ["`\(branch)` conflicts with `\(into)` on \(details.count) file(s):"]
                for detail in details {
                    let who = detail.authors.isEmpty ? "unknown authors" : detail.authors.joined(separator: ", ")
                    lines.append("  \(detail.path) (touched by \(who))")
                }
                lines.append("Coordinate, rebase by hand, then land again.")
                return lines.joined(separator: "\n")
            case .rebaseFailed(let into, let output):
                return "rebase onto `\(into)` failed (aborted, branch untouched):\n\(output)"
            case .checksFailed(let results):
                var lines = ["\(results.count) check(s) failed — main untouched:"]
                for result in results {
                    lines.append("  ✗ \(result.name)")
                    for line in Self.tail(result.output) { lines.append("      \(line)") }
                }
                return lines.joined(separator: "\n")
            case .cannotFastForward(let reason):
                return "could not move main: \(reason)"
            case .gitTooOld(let version):
                return "git \(version) < 2.38: merge-tree unavailable, cannot check for conflicts"
            }
        }

        static func tail(_ output: String, lines: Int = 6) -> [String] {
            output.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init)
        }
    }

    public struct Report: Sendable, Equatable {
        public var branch: String
        public var into: String
        public var sha: String
        public var files: [String]
        public var checksRun: Int
        public var claimsReleased: Int
        public var dryRun: Bool
        /// The one line the CLI prints at the end — the broadcast text, or the
        /// plan when dry.
        public var message: String

        public init(
            branch: String, into: String, sha: String, files: [String],
            checksRun: Int, claimsReleased: Int, dryRun: Bool, message: String
        ) {
            self.branch = branch
            self.into = into
            self.sha = sha
            self.files = files
            self.checksRun = checksRun
            self.claimsReleased = claimsReleased
            self.dryRun = dryRun
            self.message = message
        }
    }

    public enum AutoOutcome: Sendable {
        case landed(Report)
        /// Quiet conditions — nothing ahead, dirty tree, radar conflict: the
        /// next Stop tries again, so nothing is worth writing down.
        case skipped(reason: String)
        /// Tried and failed (rebase, checks, fast-forward). Ledgers itself,
        /// throttled so a broken branch does not write one line per turn.
        case failed(reason: String)
    }

    // MARK: - Git helpers

    @discardableResult
    static func git(_ arguments: [String], in repo: String, timeout: TimeInterval = 60) -> Shell.Output {
        Shell.run(
            "/usr/bin/env",
            ["git"] + arguments,
            in: URL(fileURLWithPath: repo),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: timeout
        )
    }

    /// What `git status` would commit, as repository-relative paths.
    public static func dirtyFiles(repo: String) -> [String] {
        PrecommitCheck.parseStatus(git(["status", "--porcelain", "-z"], in: repo).stdout)
    }

    static func branchExists(_ branch: String, repo: String) -> Bool {
        git(["rev-parse", "--verify", "--quiet", "\(branch)^{commit}"], in: repo).succeeded
    }

    /// "main" when there is one, "master" when that is what the project calls
    /// it, nil when neither exists.
    public static func defaultInto(repo: String) -> String? {
        if branchExists("main", repo: repo) { return "main" }
        if branchExists("master", repo: repo) { return "master" }
        return nil
    }

    public static func tip(of branch: String, repo: String) -> String? {
        let output = git(["rev-parse", branch], in: repo)
        guard output.succeeded else { return nil }
        let sha = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    public static func shortSHA(_ sha: String) -> String { String(sha.prefix(7)) }

    /// Commits on the branch that the landing target does not have.
    public static func aheadCount(branch: String, into: String, repo: String) -> Int {
        let output = git(["rev-list", "--count", "\(into)..\(branch)"], in: repo)
        guard output.succeeded else { return 0 }
        return Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Who touched this file on each side of the merge base — the names the
    /// conflict report prints next to the path, so the landing agent knows who
    /// to talk to rather than just which file is red.
    public static func authorsOf(path: String, branch: String, into: String, repo: String) -> [String] {
        let base = git(["merge-base", into, branch], in: repo)
        guard base.succeeded else { return [] }
        let baseSHA = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var authors: [String] = []
        for range in ["\(baseSHA)..\(branch)", "\(baseSHA)..\(into)"] {
            let log = git(["log", "--format=%an", range, "--", path], in: repo)
            guard log.succeeded else { continue }
            for author in log.lines.map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if !author.isEmpty, !authors.contains(author) { authors.append(author) }
            }
            if authors.count >= 4 { break }
        }
        return Array(authors.prefix(4))
    }

    /// Paths that changed between two revisions, sorted.
    public static func filesChanged(from old: String, to new: String, repo: String) -> [String] {
        let output = git(["diff", "--name-only", old, new], in: repo)
        guard output.succeeded else { return [] }
        return output.lines.sorted()
    }

    // MARK: - The landing

    /// Rebase `branch` onto `into`, run checks, fast-forward `into`, broadcast.
    ///
    /// Throws `Failure` with the whole explanation in it — the CLI prints it
    /// and exits 1, and main is untouched in every failure case.
    ///
    /// `fast` skips the rebase and the checks and lands only what
    /// fast-forwards: the branch must already contain `into`. That is the
    /// whole automatic path — a Stop hook must never sit through a rebase and
    /// a slow suite — and `land --fast` for a human who just rebased by hand.
    @discardableResult
    public static func land(
        branch branchParam: String?,
        into intoParam: String?,
        repo: URL,
        label: String,
        verified: Bool,
        paths: Paths,
        skipChecks: Bool = false,
        dryRun: Bool = false,
        fast: Bool = false,
        progress: (String) -> Void = { _ in }
    ) throws -> Report {
        let started = Date()
        let repoPath = repo.path
        guard GitSnapshot.isRepository(repoPath) else { throw Failure.notRepository }

        let current = RepoIdentity.currentBranch(at: repoPath)
        guard let branch = branchParam ?? current else {
            throw Failure.unknownBranch("(detached HEAD — name the branch with --branch)")
        }
        guard branchExists(branch, repo: repoPath) else { throw Failure.unknownBranch(branch) }

        let into: String
        if let intoParam {
            guard branchExists(intoParam, repo: repoPath) else { throw Failure.unknownInto(intoParam) }
            into = intoParam
        } else {
            guard let resolved = defaultInto(repo: repoPath) else {
                throw Failure.unknownInto("main/master (neither exists)")
            }
            into = resolved
        }
        guard branch != into else { throw Failure.sameBranch(branch) }

        let dirty = dirtyFiles(repo: repoPath)
        guard dirty.isEmpty else { throw Failure.dirty(files: dirty.sorted()) }

        // The rebase below replays the checked-out branch; landing a branch
        // from another worktree would replay the wrong one.
        guard current == branch else {
            throw Failure.wrongCheckout(expected: branch, actual: current)
        }

        let gitVersion = ConflictRadar.gitVersion(in: repoPath)
        guard let supported = gitVersion, ConflictRadar.supportsMergeTree(version: supported) else {
            throw Failure.gitTooOld(gitVersion.map({ "\($0.0).\($0.1).\($0.2)" }) ?? "unknown")
        }

        guard let conflicted = ConflictRadar.conflicts(between: branch, and: into, in: repoPath) else {
            throw Failure.noMergeBase(branch: branch, into: into)
        }
        if !conflicted.isEmpty {
            let details = conflicted.map { path in
                ConflictDetail(path: path, authors: authorsOf(path: path, branch: branch, into: into, repo: repoPath))
            }
            throw Failure.conflicts(branch: branch, into: into, details: details)
        }

        let planned = skipChecks ? [] : ProjectChecks.checks(for: repo).filter({ !$0.optional })
        if dryRun {
            let branchTip = tip(of: branch, repo: repoPath) ?? branch
            let intoTip = tip(of: into, repo: repoPath) ?? into
            let files = filesChanged(from: intoTip, to: branchTip, repo: repoPath)
            progress("clean: yes · `\(branch)` merges into `\(into)` with no conflicts")
            progress("would rebase `\(branch)` onto `\(into)`, then run \(planned.count) check(s):"
                + (planned.isEmpty ? " none detected" : " " + planned.map(\.name).joined(separator: ", ")))
            progress("would fast-forward `\(into)` to \(shortSHA(branchTip)) (\(files.count) files)")
            return Report(
                branch: branch, into: into, sha: branchTip, files: files,
                checksRun: 0, claimsReleased: 0, dryRun: true,
                message: "plan: rebase `\(branch)` onto `\(into)`, \(planned.count) check(s), fast-forward to \(shortSHA(branchTip))"
            )
        }

        progress("rebasing `\(branch)` onto `\(into)`…")
        var results: [CheckResult] = []
        if fast {
            guard let branchTip = tip(of: branch, repo: repoPath),
                  let intoTip = tip(of: into, repo: repoPath),
                  git(["merge-base", "--is-ancestor", intoTip, branchTip], in: repoPath).succeeded
            else {
                throw Failure.cannotFastForward(
                    reason: "`\(branch)` does not contain `\(into)` — rebase first (land without --fast)")
            }
            progress("fast: no rebase, no checks — `\(into)` is an ancestor of `\(branch)`")
        } else {
            let rebased = git(["rebase", into], in: repoPath, timeout: 300)
            guard rebased.succeeded else {
                _ = git(["rebase", "--abort"], in: repoPath)
                throw Failure.rebaseFailed(into: into, output: String(rebased.text.suffix(500)))
            }

            if !skipChecks {
                results = ProjectChecks.run(planned, in: repo)
                for result in results {
                    progress("\(result.status == .passed ? "✓" : "✗") \(result.name)")
                }
                let bad = results.filter({ $0.status == .failed || $0.status == .timedOut })
                guard bad.isEmpty else { throw Failure.checksFailed(bad) }
            }
        }

        guard let sha = tip(of: branch, repo: repoPath),
              let intoSHA = tip(of: into, repo: repoPath)
        else { throw Failure.cannotFastForward(reason: "lost track of `\(branch)` after the rebase") }
        let files = filesChanged(from: intoSHA, to: sha, repo: repoPath)
        try fastForward(into: into, to: sha, from: intoSHA, branch: branch, repo: repoPath)

        let project = ProjectRegistry.canonicalPath(for: repoPath)
        let top = files.sorted().prefix(3).joined(separator: ", ")
        let more = files.count > 3 ? ", +\(files.count - 3) more" : ""
        let text = "landed \(shortSHA(sha)) from \(label): \(files.count) file(s) (\(top)\(more))"
        AgentBus(paths: paths).post(AgentMessage(
            from: label, projectPath: project, text: text, kind: .update, verified: verified
        ))
        let released = (try? PathClaims(paths: paths).releaseCovering(files: files, project: project, label: label)) ?? []
        let seconds = Int(Date().timeIntervalSince(started))
        let elapsed = seconds < 2 ? "" : " in \(seconds)s"
        Ledger(url: paths.ledger).append(LedgerEntry(
            at: Date(), kind: .note, project: project,
            title: "land.ok",
            summary: "\(branch) -> \(into) @ \(shortSHA(sha)): \(files.count) file(s), \(released.count) claim(s) released\(elapsed)"
        ))
        progress(text)
        return Report(
            branch: branch, into: into, sha: sha, files: files,
            checksRun: results.count, claimsReleased: released.count, dryRun: false,
            message: text
        )
    }

    /// Move `into` to `sha`: a real merge wherever it is checked out, a
    /// guarded ref update only when it sits on no checkout at all. Moving
    /// the ref under a live checkout leaves that worktree behind with a
    /// staged phantom diff — the next commit there would resurrect the old
    /// files. The old-value guard on `update-ref` means a main that moved
    /// under us fails loudly instead of being overwritten.
    static func fastForward(into: String, to sha: String, from intoSHA: String, branch: String, repo: String) throws {
        if let checkout = checkedOutWorktree(of: into, in: repo) {
            let merged = Shell.run(
                "/usr/bin/env", ["git", "-C", checkout, "merge", "--ff-only", sha],
                environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: 60
            )
            guard merged.succeeded else {
                throw Failure.cannotFastForward(reason: "`\(into)` is checked out in \(checkout) and would not fast-forward there — clean it up or update it first")
            }
            return
        }
        guard git(["merge-base", "--is-ancestor", intoSHA, sha], in: repo).succeeded else {
            throw Failure.cannotFastForward(reason: "`\(branch)` does not contain `\(into)` after the rebase")
        }
        let moved = git(["update-ref", "refs/heads/\(into)", sha, intoSHA], in: repo)
        guard moved.succeeded else {
            throw Failure.cannotFastForward(reason: "`\(into)` moved while landing — try again")
        }
    }

    /// The worktree path with `branch` checked out, or nil when it sits on
    /// no checkout. Only lines with a real branch count: bare and detached
    /// entries never match.
    static func checkedOutWorktree(of branch: String, in repo: String) -> String? {
        let listed = git(["worktree", "list", "--porcelain"], in: repo)
        guard listed.succeeded else { return nil }
        var current: String?
        for line in listed.lines {
            if line.hasPrefix("worktree ") {
                current = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                if let current { return current }
            } else if line.isEmpty {
                current = nil
            }
        }
        return nil
    }

    // MARK: - Automatic landing

    /// Try to land the branch at `cwd` after a Stop: only when it is ahead of
    /// main, the tree is clean, and the radar sees no conflict with main.
    ///
    /// Fast-forward only, no rebase, no checks: a Stop hook must never sit
    /// through a slow suite, and the landing announces itself on the bus
    /// (`land.ok`) where everybody — including the human — can see it. The
    /// verified path (rebase + checks) is the explicit `land` command. One
    /// landing runs at a time per machine: a second arrival skips with a
    /// reason instead of stacking Stops behind the first.
    @discardableResult
    public static func autoLand(cwd: String, provider: AgentProvider, paths: Paths) -> AutoOutcome {
        guard GitSnapshot.isRepository(cwd) else { return .skipped(reason: "not a repository") }
        guard let branch = RepoIdentity.currentBranch(at: cwd) else {
            return .skipped(reason: "detached HEAD")
        }
        guard let into = defaultInto(repo: cwd), branch != into else {
            return .skipped(reason: "not on a landing branch")
        }
        guard aheadCount(branch: branch, into: into, repo: cwd) > 0 else {
            return .skipped(reason: "nothing ahead of \(into)")
        }
        guard dirtyFiles(repo: cwd).isEmpty else {
            return .skipped(reason: "worktree not clean")
        }
        guard let conflicted = ConflictRadar.conflicts(between: branch, and: into, in: cwd),
              conflicted.isEmpty
        else {
            return .skipped(reason: "radar sees a conflict with \(into)")
        }

        let repo = URL(fileURLWithPath: cwd)
        let worktreeLabel = WorktreeLabel.read(cwd: repo)
        let label = worktreeLabel ?? AgentBus.label(for: provider)
        let project = ProjectRegistry.canonicalPath(for: cwd)
        let started = Date()
        do {
            var report: Report?
            let ran = try LockedFile.tryExclusiveLock(paths.home.appendingPathComponent("land")) {
                report = try land(
                    branch: branch, into: into, repo: repo, label: label,
                    verified: worktreeLabel != nil, paths: paths,
                    skipChecks: true, dryRun: false, fast: true, progress: { _ in }
                )
                ConflictRadar.clearAutoNote(branch: branch, project: project, paths: paths)
            }
            guard ran, let report else {
                Ledger(url: paths.ledger).append(LedgerEntry(
                    at: Date(), kind: .note, project: project,
                    title: "land.auto.skip", summary: "\(branch): another landing in progress"
                ))
                return .skipped(reason: "another landing in progress")
            }
            let seconds = Int(Date().timeIntervalSince(started))
            Ledger(url: paths.ledger).append(LedgerEntry(
                at: Date(), kind: .note, project: project,
                title: "land.auto.done", summary: "\(branch): fast-forward in \(seconds)s"
            ))
            return .landed(report)
        } catch {
            let reason = (error as? Failure)?.description ?? error.localizedDescription
            if ConflictRadar.noteAutoSkip(branch: branch, project: project, paths: paths) {
                Ledger(url: paths.ledger).append(LedgerEntry(
                    at: Date(), kind: .note, project: project,
                    title: "land.auto.skip", summary: "\(branch): \(reason)"
                ))
            }
            return .failed(reason: reason)
        }
    }
}
