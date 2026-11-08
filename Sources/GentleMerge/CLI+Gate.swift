import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    /// What to read before you write a commit.
    ///
    /// Not a gate: it never fails, never blocks, and never touches the index.
    /// It answers one question — has anybody committed to the files I have
    /// open, since I started? — and then gets out of the way. A check that can
    /// stop you committing is a check you learn to skip.
    static func precommit(_ arguments: [String]) -> Int32 {
        let directory = projectDirectory(arguments)
        let paths = Paths.fromEnvironment()
        // The gate must see edit-claims the hooks just reported. Drain first:
        // a violation reported seconds ago is a violation now.
        InboxModel.drainHeadless(paths: paths)
        if let claimed = value(after: "--as", in: arguments) ?? value(after: "--from", in: arguments) {
            do {
                _ = try Identity.reconcile(explicit: claimed,
                    resolved: Identity.resolve(cwd: checkoutDirectory(arguments), provider: .unknown, paths: paths))
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
            }
        }

        // `--enforce --staged` is the git pre-commit gate (step 2): staged
        // files checked against path claims, ownership and requests, exit 1 on
        // a blocking violation. The overlap report below stays first — it is
        // the context, the gate is the decision.
        if isSet("--enforce", in: arguments) {
            return precommitEnforce(arguments, in: checkoutDirectory(arguments), paths: paths)
        }

        // `--since` for when you know better than we do: a rebase, a clone, or
        // a wrapper that kept its own note of where it came in.
        let baseline = value(after: "--since", in: arguments)
            ?? sessionBaseline(for: directory, paths: paths, arguments: arguments)

        // The checkout, not the project: every worktree is one project, and each
        // has its own uncommitted files.
        let report = PrecommitCheck.run(in: checkoutDirectory(arguments), baseline: baseline)

        guard report.isRepository else {
            print("\(report.projectName) is not a git repository — nothing to check.")
            return 0
        }

        let window = report.baseline
            .map { "since this session started (\($0.prefix(7)))" }
            ?? "in the last \(report.landed.count) \(report.landed.count == 1 ? "commit" : "commits")"

        guard !report.changed.isEmpty else {
            print("Nothing uncommitted in \(report.projectName). \(behindLine(report) ?? "")"
                .trimmingCharacters(in: .whitespaces))
            return 0
        }

        print("\(report.projectName) — \(count(report.changed.count, "file")) uncommitted,"
            + " checked against what landed \(window).")
        if report.checkedRecentInstead {
            print("(No session baseline here, so this is the last few commits rather than"
                + " exactly the ones that landed under you.)")
        }

        if report.overlaps.isEmpty {
            print("\nNobody has committed to any of them. You are clear to commit.")
        } else {
            print("\n⚠️  \(count(report.overlaps.count, "file")) of yours already got committed to:")
            for overlap in report.overlaps {
                print("  \(overlap.path)")
                for commit in overlap.commits {
                    let who = commit.author.map { " · \($0)" } ?? ""
                    let remote = report.isIncoming(commit)
                        ? "  ← on \(report.upstream ?? "the remote"), not in your branch"
                        : ""
                    print("      `\(commit.shortSHA)` \(RelativeTime.short(from: commit.date))\(who)"
                        + " — \(commit.subject)\(remote)")
                }
            }
            if let first = report.overlaps.first, let commit = first.commits.first {
                print("\n  Read the change before you write over it:")
                print("      git show \(commit.shortSHA) -- \(first.path)")
            }

            let untouched = report.untouched
            if !untouched.isEmpty {
                print("\nNobody has been near: \(untouched.joined(separator: ", "))")
            }
        }

        if let behind = behindLine(report) { print("\n\(behind)") }
        return 0
    }

    /// "2 commits behind origin/main" — the other way work gets overwritten,
    /// and the one a file-by-file comparison cannot see.
    static func behindLine(_ report: PrecommitReport) -> String? {
        guard !report.incoming.isEmpty else { return nil }
        return "Your branch is \(count(report.incoming.count, "commit")) behind"
            + " \(report.upstream ?? "its upstream") — pull before you push."
    }

    /// Bring this branch home: rebase onto main, run the project's checks,
    /// fast-forward main, and tell the bus what landed. Fails before touching
    /// main whenever anything is off — a dirty tree, a conflict (with the
    /// files and who touched them), a failed rebase, a failing check.
    static func land(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // The branch lands from its own worktree: the rebase replays whatever
        // is checked out here, so `--branch` naming anything else is refused
        // down in Landing rather than here.
        let cwd = checkoutDirectory(arguments, allowPositional: false)
        let repo = URL(fileURLWithPath: cwd)
        let identity: Identity
        do {
            identity = try Identity.reconcile(
                explicit: value(after: "--from", in: arguments) ?? value(after: "--as", in: arguments),
                resolved: Identity.resolve(cwd: cwd, provider: .unknown, paths: paths))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }
        // The worktree's own label first: landing credits whoever owns this
        // checkout, not whoever happened to type the command.
        let label = WorktreeLabel.read(cwd: repo) ?? identity.label
        do {
            let report = try Landing.land(
                branch: value(after: "--branch", in: arguments),
                into: value(after: "--into", in: arguments),
                repo: repo,
                label: label,
                verified: identity.verified,
                paths: paths,
                skipChecks: isSet("--skip-checks", in: arguments),
                dryRun: isSet("--dry-run", in: arguments),
                fast: isSet("--fast", in: arguments),
                progress: { print($0) }
            )
            // The steps already printed on the way; a dry run ends on the plan.
            if report.dryRun { print(report.message) }
            return 0
        } catch let failure as Landing.Failure {
            FileHandle.standardError.write(Data((failure.description + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("land failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Check every `agent/*` branch pair for the merge conflicts they will hit
    /// later, and warn both sides on the bus — once per conflict. At most one
    /// sweep per project per three minutes; never fails, just says why not.
    static func radar(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let force = isSet("--force", in: arguments)
        let single = value(after: "--project", in: arguments) != nil || !positional(arguments).isEmpty
        let targets: [String]
        if single {
            targets = [projectDirectory(arguments)]
        } else {
            // The ones with a row: a scratch folder has no branches to compare.
            targets = ProjectRegistry(url: paths.projects).visibleProjects().map(\.path)
            guard !targets.isEmpty else {
                print("No projects yet. They appear as agents work in them, or run `gentlemerge project init`.")
                return 0
            }
        }
        for target in targets {
            let name = URL(fileURLWithPath: target).lastPathComponent
            switch ConflictRadar.sweep(project: target, paths: paths, ignoreThrottle: force) {
            case .throttled:
                print("\(name): swept recently — nothing due (add --force)")
            case .skipped(let reason):
                print("\(name): radar skipped (\(reason))")
            case .nothingToDo:
                print("\(name): fewer than two agent/* branches")
            case .done(let announced, let pairs):
                print("\(name): \(pairs) pair(s) checked, \(announced) new conflict(s) announced")
            }
        }
        return 0
    }

    /// `precommit --enforce` — the gate the git hook calls. The overlap report
    /// prints first (context), then the claims/ownership/request violations
    /// (decision): a blocking one exits 1, and git refuses the commit.
    /// Who is committing, as far as the gate is concerned: a *verified*
    /// identity or nobody.
    ///
    /// `Identity.verified` already names the two sources the rest of the
    /// system trusts — `GENTLEMERGE_LABEL` and the worktree's own label — and
    /// refuses to let a caller holding either speak as anybody else. The gate
    /// read only the second. That suits the README's layout, one labelled
    /// worktree per agent, and nothing else: several agents sharing one
    /// checkout, which is how this tool is actually run, have no worktree label
    /// to tell them apart. There every claim was somebody else's, so an agent
    /// was blocked from committing the very file its own edit had just claimed,
    /// and installing the gate would have stopped every agent at once
    /// (2026-10-26). Each agent now says who it is through its own
    /// environment, and the gate believes it exactly as far as everything else
    /// does.
    ///
    /// What stays out is what 2026-10-07 removed: an unverified source — a
    /// presence mark, `GENTLEMERGE_NAME`, the provider — never becomes `me`,
    /// so a commit cannot borrow the identity of whoever happens to be alive.
    /// As the README says, this coordinates cooperative agents; one that sets a
    /// variable to pass as another is as far outside that as `--no-verify`.
    static func committerLabel(at directory: String, paths: Paths) -> String? {
        let identity = Identity.resolve(cwd: directory, provider: .unknown, paths: paths)
        return identity.verified ? identity.label : nil
    }

    static func precommitEnforce(_ arguments: [String], in directory: String, paths: Paths) -> Int32 {
        let staged = isSet("--staged", in: arguments)
        let repo = URL(fileURLWithPath: directory)
        let project = ProjectRegistry.canonicalPath(for: directory)

        // Identity for enforcement is a *verified* label (see `committerLabel`),
        // and nothing else. We deliberately do not fall back to the project's
        // single live presence mark: a mark belongs to a session, not to the
        // directory committing here, so adopting one made `me` equal whoever
        // happened to be alive. When that happened to be the claim holder, rule
        // 1's `$0.label != me` skipped its own claim and the commit sailed
        // through. With no label, `evaluate` still blocks on
        // live claims — it just cannot apply ownership zones, which need
        // somebody to tell owner from invader.
        let label = committerLabel(at: directory, paths: paths)

        // The existing overlap report, exactly as `precommit` prints it.
        let baseline = value(after: "--since", in: arguments)
            ?? sessionBaseline(for: directory, paths: paths, arguments: arguments)
        let report = PrecommitCheck.run(in: directory, baseline: baseline)
        // Only with a real baseline. Without one the report is "the last few
        // commits", which includes the committer's own: every ordinary commit in a
        // one-agent repository printed "⚠️ 1 file of yours already got committed
        // to", a warning with nothing behind it that trains everyone to skim the
        // gate's output. `gentlemerge precommit` still prints it, with its caveat.
        if report.isRepository, !report.checkedRecentInstead {
            if report.overlaps.isEmpty {
                print("Nobody has committed to any of the \(count(report.changed.count, "file")) staged/changed. You are clear so far.")
            } else {
                print("⚠️  \(count(report.overlaps.count, "file")) of yours already got committed to:")
                for overlap in report.overlaps {
                    print("  \(overlap.path)")
                }
            }
        }

        let gate = PrecommitGate(paths: paths)
        let files = staged ? gate.stagedFiles(repo: repo) : gate.dirtyFiles(repo: repo)
        let claims = PathClaims(paths: paths).live(project: project)
        let presence = Presence.marks(paths: paths)
        // Dead sessions lose their claims before the gate decides, labeled or
        // not: an unlabeled commit must not stay blocked by a ghost either.
        let (_, reaped) = PathClaims.reap(
            claims.filter { $0.label != label },
            presence: presence, isPIDAlive: { Liveness.isProcessAlive($0, seenAt: $1) }, now: Date()
        )
        if !reaped.isEmpty {
            Ledger(url: paths.ledger).append(LedgerEntry(
                at: Date(),
                kind: .note,
                project: project,
                title: "claim.reaped",
                summary: reaped.map { "\($0.label):\($0.pattern)" }.joined(separator: ", ")
            ))
        }
        let violations = PrecommitGate.judge(files: files, me: label, project: project, paths: paths)

        if label == nil {
            print("gentlemerge: no label for this worktree (run `gentlemerge project init --label <name>`); live claims still block")
        }
        for violation in violations {
            print("✖ \(violation.path): \(violation.reason)")
        }
        if violations.contains(where: { $0.blocking }) {
            // The human escape hatch lives here, not in the hook script, so a
            // skip is published instead of silent: the variable is documented
            // for humans (hook comment, README) and never printed where a
            // model reads, and the bus hears about every use.
            if EscapeHatch.isActive() {
                let who = label ?? "you"
                let summary = "\(who) skipped \(violations.count) blocking violation(s) on \(files.count) file(s)"
                AgentBus(paths: paths).post(AgentMessage(
                    from: who, projectPath: project,
                    text: "⚠ human override: \(summary). The commit went through."
                ))
                Ledger(url: paths.ledger).append(LedgerEntry(
                    at: Date(), kind: .note, project: project,
                    title: "precommit.skipped", summary: summary
                ))
                print("gentlemerge: override recorded on the bus; commit allowed.")
                return 0
            }
            print("gentlemerge: commit blocked. Coordinate via `gentlemerge say`.")
            Ledger(url: paths.ledger).append(LedgerEntry(
                at: Date(),
                kind: .note,
                project: project,
                title: "precommit.blocked",
                summary: "label \(label ?? "?"): \(violations.count) violation(s)"
            ))
            return 1
        }
        return 0
    }

    /// `gentlemerge postcommit [--merge|--rewrite] [--project dir]` — what the git
    /// post-commit, post-merge and post-rewrite hooks call: count whatever went round
    /// the gate, and after a commit release my claims on what just landed, so other
    /// agents are unblocked without waiting for the TTL. Never blocks, never fails:
    /// the exit is always 0, because a bookkeeping error must never break a commit.
    static func postcommit(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = checkoutDirectory(arguments, allowPositional: false)
        let repo = URL(fileURLWithPath: directory)
        let project = ProjectRegistry.canonicalPath(for: directory)
        // The same label the gate judges by (`committerLabel`), so what it let
        // through as yours is what gets released as yours. Falling back to the
        // project's single live presence mark released *somebody else's* claims —
        // unblocking other agents on files this worktree never owned. Without a
        // label the claims simply wait out their TTL, which is the safe direction.
        let label = committerLabel(at: directory, paths: paths)

        let entry: GateAudit.Entry
        if isSet("--rewrite", in: arguments) {
            let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            entry = .rebase(newCommits: GateAudit.newCommits(fromRewriteLines: input))
        } else if isSet("--merge", in: arguments) {
            entry = .merge
        } else {
            entry = .commit
        }

        // As the gate does: a claim an edit reported seconds ago counts now. Not for
        // long, though: somebody is waiting for their prompt back.
        InboxModel.drainHeadless(paths: paths, patience: 1)
        if let line = GateAudit.count(entry, repo: repo, project: project, me: label, paths: paths) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }

        // A human skip keeps its claims: only a plain landing hands them back.
        guard entry == .commit, !EscapeHatch.isActive(), let label else { return 0 }
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "diff-tree", "--root", "--no-commit-id", "--name-only", "-z", "-r", "HEAD"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_COUNT": "1",
                          "GIT_CONFIG_KEY_0": "core.quotePath", "GIT_CONFIG_VALUE_0": "false"],
            timeout: 10
        )
        guard output.succeeded else { return 0 }
        // -z: with the default core.quotePath, a name holding a non-ASCII byte
        // came back C-escaped and matched no claim pattern, so the claim was
        // never released and stayed blocking until its TTL.
        let files = output.stdout.components(separatedBy: "\0").filter { !$0.isEmpty }
        guard !files.isEmpty else { return 0 }
        let released = (try? PathClaims(paths: paths).releaseCovering(
            files: files, project: project, label: label
        )) ?? []
        if !released.isEmpty {
            Ledger(url: paths.ledger).append(LedgerEntry(
                at: Date(),
                kind: .note,
                project: project,
                title: "claim.released",
                summary: "\(label): \(released.count) path(s) landed"
            ))
        }
        return 0
    }

    /// The revision this session opened on, when GentleMerge saw it start.
    /// Absent for Hermes, for a plain shell, and for a session that began
    /// before the hooks were installed — all of which fall back to depth.
    static func sessionBaseline(
        for directory: String,
        paths: Paths,
        arguments: [String]
    ) -> String? {
        let label = (try? actingLabel(arguments, explicit: value(after: "--as", in: arguments)))
            ?? value(after: "--as", in: arguments) ?? defaultAuthor()
        guard let id = TaskClaims(paths: paths).currentSessionID(for: label, in: directory) else {
            return nil
        }
        return SessionRegistry(url: paths.sessions)[id]?.baselineCommit
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
