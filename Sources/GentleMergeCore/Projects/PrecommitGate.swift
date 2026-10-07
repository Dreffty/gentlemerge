import Foundation

/// The gate the git pre-commit hook calls into: given the staged files and the
/// current world, which of them must not be committed. The filesystem part
/// (running git) is kept separate from the decision (pure) so the matrix can be
/// tested without a repository.
public struct PrecommitGate: Sendable {
    public struct Violation: Sendable, Equatable {
        public let path: String
        public let reason: String
        /// A non-blocking violation is reported but lets the commit through.
        public let blocking: Bool

        public init(path: String, reason: String, blocking: Bool) {
            self.path = path
            self.reason = reason
            self.blocking = blocking
        }
    }

    let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// `git diff --cached --name-status -z`, which is the one form of this
    /// output that never quotes, escapes or truncates a path.
    ///
    /// Three deliberate choices, each of which was a live bypass before
    /// (audit 2026-10-07):
    ///
    /// - **`-z`, not `--name-only`.** With `--name-only` git C-quotes any path
    ///   holding a non-ASCII byte (`"lib/donn\303\251es/caf\303\251.txt"`), and
    ///   no zone pattern but a bare `**` can match that literal string — so a
    ///   claim on `lib/données/**` was silently not enforced for any file with
    ///   an accent. `core.quotePath=false` is belt-and-braces for anything that
    ///   shells out to git elsewhere.
    /// - **`--name-status`, not `--name-only`.** A rename yields only its
    ///   destination in `--name-only`; the old name is unrecoverable, so
    ///   `git mv` — or simply deleting and re-adding a file that differs by one
    ///   byte, which git reports as `R092` — moved a file *out of* somebody
    ///   else's claim without ever naming it. We need both names.
    /// - **`T` in the filter.** `ACMRD` skips a typechange, so replacing a
    ///   claimed file with a symlink (100644 => 120000) listed nothing and the
    ///   gate passed. `U` is in the filter too for symmetry, though git itself
    ///   refuses to commit an unmerged index, so it is belt-and-braces.
    public func stagedFiles(repo: URL) -> [String] {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "diff", "--cached", "--name-status", "-z", "--diff-filter=ACMRDTU"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_COUNT": "1",
                          "GIT_CONFIG_KEY_0": "core.quotePath", "GIT_CONFIG_VALUE_0": "false"],
            timeout: 10
        )
        // Fail loud, not open. If git could not answer we know nothing about
        // what is staged, and returning [] reads as "nothing is claimed" —
        // which is how a gate that cannot see turns into a gate that says yes.
        guard output.succeeded, !output.timedOut else {
            Log.error("could not read the staged files in \(repo.path): \(output.stderr.isEmpty ? "git failed or timed out" : output.stderr)")
            return ["\(PrecommitGate.unreadableIndexSentinel)"]
        }
        return PrecommitCheck.parseStagedNameStatus(output.stdout)
    }

    /// A path nothing can own, so an unreadable index surfaces as a blocking
    /// violation on every staged file rather than a silent pass.
    static let unreadableIndexSentinel = "\u{0}gentlemerge: index unreadable"

    public func dirtyFiles(repo: URL) -> [String] {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "status", "--porcelain", "-z"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        return PrecommitCheck.parseStatus(output.stdout)
    }

    /// Pure. Given staged paths and the current world, list violations.
    ///
    /// `me == nil` (no identity for this worktree) still blocks on live
    /// claims: with no label there is no "mine" to compare against, and the
    /// README's promise — the hook rejects invasions — cannot depend on every
    /// worktree having run `project init --label` (audit 2026-10-06,
    /// finding 4). It does not block on ownership zones, which do need a
    /// label to tell the owner from an invader.
    ///
    /// `presence` + `isPIDAlive` reap dead-owned claims before rule 1 runs
    /// (see `PathClaims.reap`): a session that died without releasing must
    /// not block the living until its TTL runs out — with or without a label
    /// on this worktree. Both default to "know nothing", which reaps nothing
    /// — the gate without liveness behaves exactly as before.
    ///
    /// The delegated-request check (mayTouch) joins in step 3, once
    /// `AgentRequest` exists — commits stay green per step.
    public static func evaluate(
        staged: [String],
        me: String?,
        claims: [PathClaim],
        ownership: Ownership,
        activeRequest: AgentRequest? = nil,
        now: Date = Date(),
        presence: [Presence.PresenceMark] = [],
        isPIDAlive: (@Sendable (Int) -> Bool?)? = nil
    ) -> [Violation] {
        let effective: [PathClaim]
        if let isPIDAlive {
            let (live, _) = PathClaims.reap(
                claims.filter { $0.label != me },
                presence: presence, isPIDAlive: isPIDAlive, now: now
            )
            effective = live + claims.filter { me == $0.label }
        } else {
            effective = claims
        }
        var violations: [Violation] = []
        // An index we could not read is not an empty index. Say so loudly and
        // block, rather than reporting "nothing is claimed" about a state we
        // never observed.
        if staged.contains(PrecommitGate.unreadableIndexSentinel) {
            return [.init(
                path: PrecommitGate.unreadableIndexSentinel,
                reason: "could not read the staged files (git failed or timed out), so this commit is unchecked"
                    + " — nothing was staged, or nothing was checked. Re-run with an explicit path list to proceed.",
                blocking: true
            )]
        }
        for path in staged {
            // 1) A live claim on this path → block. With a label the holder
            // must be somebody else; without one there is no "else" to compare
            // against, so any live claim blocks — a commit we cannot justify
            // is exactly what the gate is for. The reason names the way out:
            // init a label (the holder's, if the claim is really ours).
            let others = effective.filter {
                $0.isLive(at: now) && (me == nil || $0.label != me) && Glob.matches($0.pattern, path)
            }
            if let holder = others.first {
                var reason = ClaimRejection.plan(holder: holder, path: path, now: now)
                if me == nil {
                    reason += " This worktree has no label, so the claim cannot be verified as yours"
                        + " — run `gentlemerge project init --label <name>` (the holder's, if the claim is yours)."
                }
                violations.append(.init(
                    path: path,
                    reason: reason,
                    blocking: true
                ))
                continue
            }
            // 2) Path in another agent's ownership zone and I hold no explicit
            // claim → block. An implicit claim (the app recorded an Edit we
            // made) does not count: it is history, not a decision.
            if let me, let owner = ownership.owner(of: path), owner != me {
                let mine = claims.contains {
                    $0.isLive(at: now) && $0.label == me && !$0.implicit && Glob.matches($0.pattern, path)
                }
                if !mine {
                    violations.append(.init(
                        path: path,
                        reason: "owned by \(owner) per HANDOFF.md; claim it explicitly to override",
                        blocking: true
                    ))
                    continue
                }
            }
            if let activeRequest, !activeRequest.mayTouch.isEmpty,
               !activeRequest.mayTouch.contains(where: { Glob.matches($0, path) }) {
                violations.append(.init(
                    path: path,
                    reason: "outside delegated request \(activeRequest.id) mayTouch (\(activeRequest.mayTouch.joined(separator: ", ")))",
                    blocking: true
                ))
                continue
            }
        }
        return violations
    }

    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
