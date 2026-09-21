import Foundation

/// "I am editing these paths." Short-lived, renewable, per project.
/// Unlike TaskClaims (hours, about *what*), PathClaims are minutes and about *where*.
public struct PathClaim: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var label: String
    /// Canonical (RepoIdentity) path: every worktree of a repository shares one
    /// claim store, the same rule the bus and the task list follow.
    public var projectPath: String
    /// Glob relative to the project root.
    public var pattern: String
    public var intent: String?
    public var since: Date
    public var expires: Date
    /// Created by the app from an Edit/Write event, never by the agent.
    public var implicit: Bool
    /// Set when reserved for a delegated request.
    public var requestID: String?

    public func isLive(at now: Date = Date()) -> Bool { expires > now }

    /// Forgiving decode: a claim from an older binary must still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try c.decode(String.self, forKey: .label)
        projectPath = try c.decode(String.self, forKey: .projectPath)
        pattern = try c.decode(String.self, forKey: .pattern)
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        since = try c.decodeIfPresent(Date.self, forKey: .since) ?? Date()
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
            ?? since.addingTimeInterval(PathClaims.explicitTTL)
        implicit = try c.decodeIfPresent(Bool.self, forKey: .implicit) ?? false
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
    }

    public init(
        id: String = UUID().uuidString,
        label: String,
        projectPath: String,
        pattern: String,
        intent: String?,
        since: Date,
        expires: Date,
        implicit: Bool,
        requestID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.projectPath = projectPath
        self.pattern = pattern
        self.intent = intent
        self.since = since
        self.expires = expires
        self.implicit = implicit
        self.requestID = requestID
    }
}

public struct PathClaimConflict: Error, Sendable, CustomStringConvertible {
    public let pattern: String
    public let holders: [PathClaim]

    public var description: String {
        holders.map { ClaimRejection.plan(holder: $0, path: pattern, now: Date()) }
            .joined(separator: "\n")
    }
}

/// What a refused model reads: not a complaint but a computable plan — who
/// holds the path, for how long, and the three moves available right now.
/// Asking, unstaging, or waiting: option (b) is the one that saves a whole
/// cycle, because the rest of the commit goes through immediately.
public enum ClaimRejection: Sendable {
    public static func plan(holder: PathClaim, path: String, now: Date = Date()) -> String {
        let minutes = max(Int(holder.expires.timeIntervalSince(now) / 60), 0)
        let free = minutes <= 0 ? "almost up" : "free in \(minutes)m"
        let why = holder.intent.map { " (\($0))" } ?? ""
        return "`\(path)` is claimed by \(holder.label)\(why) — \(free)."
            + " Next: (a) ask: `gentlemerge say --to \(holder.label) \"release \(path)?\"`;"
            + " (b) unstage it (`git reset \(path)`) and commit the rest now;"
            + " (c) wait."
    }
}

public struct PathClaims: Sendable {
    public static let explicitTTL: TimeInterval = 30 * 60
    public static let implicitTTL: TimeInterval = 15 * 60

    let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    // MARK: - I/O

    public func load() -> [PathClaim] {
        guard let data = try? Data(contentsOf: paths.pathClaims),
              let claims = try? JSONCoding.decoder().decode([PathClaim].self, from: data)
        else { return [] }
        return claims
    }

    func save(_ claims: [PathClaim]) throws {
        let data = try JSONCoding.encoder(pretty: true).encode(claims)
        try AtomicFile.write(data, to: paths.pathClaims)
    }

    /// Every write goes through the sidecar lock, same as the app and the CLI
    /// contend for `claims.json`: two hook processes can read-modify-write this
    /// file in the same second, and a lost rewrite is a protection that quietly
    /// stopped existing.
    func mutate(_ body: (inout [PathClaim]) throws -> Void) throws {
        try LockedFile.withExclusiveLock(paths.pathClaims) {
            var claims = load().filter { $0.isLive() }   // prune on every write
            try body(&claims)
            try save(claims)
        }
    }

    // MARK: - Queries

    public func live(project: String, at now: Date = Date()) -> [PathClaim] {
        load().filter { $0.projectPath == project && $0.isLive(at: now) }
    }

    /// Claims held by *other* labels that cover this path.
    public func conflicts(path: String, label: String, project: String) -> [PathClaim] {
        live(project: project).filter { $0.label != label && Glob.matches($0.pattern, path) }
    }

    // MARK: - Mutations

    /// Explicit claim. Fails if another live claim may overlap. Same label → renew.
    @discardableResult
    public func claim(
        pattern: String,
        label: String,
        project: String,
        intent: String?,
        ttl: TimeInterval = PathClaims.explicitTTL,
        implicit: Bool = false,
        requestID: String? = nil
    ) throws -> PathClaim {
        var result: PathClaim!
        // Shown to every other agent in briefings: scrubbed here so no entry
        // point (CLI, MCP, delegation) can store a secret in it.
        let intent = intent.map { Redactor.scrub($0).text }
        try mutate { claims in
            let others = claims.filter {
                $0.projectPath == project && $0.label != label
                    && Glob.mayOverlap($0.pattern, pattern)
            }
            // Implicit claims never fight: if someone else holds it, we just
            // don't record ours. The pre-commit hook and the PreToolUse advice
            // are what surface the conflict — an Edit that failed because of a
            // bookkeeping error would be the agent paying for our bug.
            if !others.isEmpty {
                if implicit {
                    result = others[0]
                    return
                }
                throw PathClaimConflict(pattern: pattern, holders: others)
            }
            let now = Date()
            if let index = claims.firstIndex(where: {
                $0.projectPath == project && $0.label == label
                    && $0.requestID == requestID
                    && Glob.normalize($0.pattern) == Glob.normalize(pattern)
            }) {
                claims[index].expires = now.addingTimeInterval(ttl)
                if intent != nil { claims[index].intent = intent }
                // An explicit claim stays explicit even when renewed implicitly:
                // the reverse would silently downgrade the protection.
                claims[index].implicit = claims[index].implicit && implicit
                if let requestID { claims[index].requestID = requestID }
                result = claims[index]
            } else {
                let claim = PathClaim(
                    label: label,
                    projectPath: project,
                    pattern: pattern,
                    intent: intent,
                    since: now,
                    expires: now.addingTimeInterval(ttl),
                    implicit: implicit,
                    requestID: requestID
                )
                claims.append(claim)
                result = claim
            }
        }
        return result
    }

    /// Implicit claim for a single edited file. Never throws, never blocks the
    /// agent — the moment an agent edits a file, everyone else can know.
    /// Returns the claim that stands on the path afterwards: the other agent's
    /// when they already held it, which is what the PreToolUse advice surfaces
    /// without a second bookkeeping write.
    @discardableResult
    public func touch(file relPath: String, label: String, project: String) -> PathClaim? {
        try? claim(
            pattern: relPath,
            label: label,
            project: project,
            intent: nil,
            ttl: PathClaims.implicitTTL,
            implicit: true
        )
    }

    public func release(label: String, project: String, patterns: [String]? = nil, requestID: String? = nil) throws {
        try mutate { claims in
            claims.removeAll { claim in
                claim.label == label && claim.projectPath == project &&
                    (requestID == nil || claim.requestID == requestID) &&
                    (patterns == nil || patterns!.contains {
                        Glob.normalize($0) == Glob.normalize(claim.pattern)
                    })
            }
        }
    }

    /// Hand back every claim of `label` that covers one of `files` — the paths
    /// are repository-relative, the patterns are globs, so this matches rather
    /// than comparing strings. Landing a branch calls this: what just merged
    /// no longer needs protecting. Another label's claims on the same files
    /// stand: their edits are still uncommitted somewhere.
    ///
    /// Returns what was released, so the caller can say so.
    @discardableResult
    public func releaseCovering(files: [String], project: String, label: String) throws -> [PathClaim] {
        var released: [PathClaim] = []
        try mutate { claims in
            released = claims.filter { claim in
                claim.label == label && claim.projectPath == project
                    && files.contains { Glob.matches(claim.pattern, $0) }
            }
            claims.removeAll { released.contains($0) }
        }
        return released
    }

    public func renew(label: String, project: String, ttl: TimeInterval = PathClaims.explicitTTL) throws {
        try mutate { claims in
            let now = Date()
            for index in claims.indices
            where claims[index].label == label && claims[index].projectPath == project {
                claims[index].expires = now.addingTimeInterval(ttl)
            }
        }
    }

    // MARK: - Reaping

    /// Splits live claims into those that stand and those whose owner is
    /// demonstrably gone — a session that died (a 529, a session limit, a
    /// `kill -9`) never releases, and without reaping its paths stay blocked
    /// until the TTL runs out: coordination that stops work.
    ///
    /// Pure: `isPIDAlive` answers `kill(pid, 0)` (`nil` = unknown, never
    /// dead), presence is the marks on disk. A claim is reaped only on one of
    /// two independent signs that its session is dead:
    /// - a presence mark for its label names a pid that is dead, or
    /// - every mark for its label is stale (silent past the presence TTL) —
    ///   claims only live 15/30 minutes, so a session that quiet is gone.
    /// No marks at all means unknown, never dead: a plain shell leaves no
    /// presence, and reaping it would punish the least instrumented agent.
    ///
    /// The caller's own claims never enter here — callers pass others only.
    /// You cannot be dead while committing.
    public static func reap(
        _ claims: [PathClaim],
        presence: [Presence.PresenceMark],
        isPIDAlive: @Sendable (Int) -> Bool?,
        now: Date = Date()
    ) -> (live: [PathClaim], reaped: [PathClaim]) {
        var live: [PathClaim] = []
        var reaped: [PathClaim] = []
        for claim in claims where claim.isLive(at: now) {
            let marks = presence.filter { Self.ownerLabels($0.label).contains(claim.label)
                || Self.ownerLabels(claim.label).contains($0.label) }
            let dead: Bool = {
                guard !marks.isEmpty else { return false }
                if marks.contains(where: { $0.pid.map(isPIDAlive) == false }) { return true }
                return marks.allSatisfy { now.timeIntervalSince($0.updatedAt) >= Presence.timeToLive }
            }()
            if dead { reaped.append(claim) } else { live.append(claim) }
        }
        return (live, reaped)
    }

    /// A label and its parent: `claude#exec1` belongs to `claude`, and a
    /// presence mark for either one speaks for the claim.
    static func ownerLabels(_ label: String) -> [String] {
        guard let hash = label.firstIndex(of: "#") else { return [label] }
        return [label, String(label[..<hash])]
    }

    public func prune() { _ = try? mutate { _ in } }
}
