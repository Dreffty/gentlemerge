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

    public func stagedFiles(repo: URL) -> [String] {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMRD"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        return output.lines.filter { !$0.isEmpty }
    }

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
    /// `me == nil` (no identity for this worktree) never blocks: enforcing
    /// claims against an unknown actor would block a commit we cannot justify.
    ///
    /// `presence` + `isPIDAlive` reap other labels' dead-owned claims before
    /// rule 1 runs (see `PathClaims.reap`): a session that died without
    /// releasing must not block the living until its TTL runs out. Both
    /// default to "know nothing", which reaps nothing — the gate without
    /// liveness behaves exactly as before.
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
        if let me, let isPIDAlive {
            let (live, _) = PathClaims.reap(
                claims.filter { $0.label != me },
                presence: presence, isPIDAlive: isPIDAlive, now: now
            )
            effective = live + claims.filter { $0.label == me }
        } else {
            effective = claims
        }
        var violations: [Violation] = []
        for path in staged {
            // 1) Someone else holds a live claim on this path → block. Skipped
            // when `me` is nil: a claim could be our own, and enforcing
            // against an unknown actor would block a commit we cannot justify.
            if me != nil {
                let others = effective.filter {
                    $0.isLive(at: now) && $0.label != me && Glob.matches($0.pattern, path)
                }
                if let holder = others.first {
                    violations.append(.init(
                        path: path,
                        reason: ClaimRejection.plan(holder: holder, path: path, now: now),
                        blocking: true
                    ))
                    continue
                }
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
