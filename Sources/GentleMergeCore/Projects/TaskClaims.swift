import Foundation

/// One agent saying "I am on this one" about a task in a project's handoff.
///
/// Deliberately *not* stored in `HANDOFF.md`. Two reasons, and the first one is
/// a bug waiting to happen: a task's identity is derived from its text, and the
/// metadata parser stops at the first suffix it does not recognise — so a
/// binary that predates claims would read `· claimed by claude` as part of the
/// task text, hash it into a different id, and the task would silently split in
/// two. The second is what the file is for: `HANDOFF.md` is the project's
/// memory, committed and read by humans, while a claim is coordination that
/// stops meaning anything two hours from now.
public struct TaskClaim: Codable, Sendable, Equatable {
    public var projectPath: String
    /// The FNV id of the `TaskItem`, so a task renamed by hand loses its claim
    /// rather than carrying somebody else's name into a different piece of work.
    public var taskID: String
    /// A free label — `claude`, `codex`, `hermes`, `claude#exec1` — never an
    /// `AgentProvider`: an old binary decoding an enum case it has never heard
    /// of would throw away the whole file.
    public var claimedBy: String
    /// The session behind the label, when we could work out which one it is.
    /// Its absence costs nothing but the death rule below.
    public var sessionID: String?
    public var claimedAt: Date

    public init(
        projectPath: String,
        taskID: String,
        claimedBy: String,
        sessionID: String? = nil,
        claimedAt: Date = Date()
    ) {
        self.projectPath = projectPath
        self.taskID = taskID
        self.claimedBy = claimedBy
        self.sessionID = sessionID
        self.claimedAt = claimedAt
    }

    /// What a task list or a briefing puts after the task text.
    public func annotation(now: Date = Date()) -> String {
        "claimed by \(claimedBy) (\(RelativeTime.compact(from: claimedAt, to: now)))"
    }

    /// What the agent that asked second is told. It names who and how long ago
    /// because the next move is a conversation, not a retry — nothing here
    /// stops that agent from doing the work anyway.
    public func conflictLine(now: Date = Date()) -> String {
        "claimed by \(claimedBy) \(RelativeTime.short(from: claimedAt, to: now))"
            + " — talk to them or wait"
    }
}

/// Who is on what, across every project, in one file outside the repositories.
///
/// The whole store is a report. Nothing here can stop an agent editing a file,
/// and it is not supposed to: a claim is a way of finding out, before you
/// start, that somebody else already did.
public struct TaskClaims: Sendable {
    /// How long a claim stands on the clock alone. Long enough for a real piece
    /// of work, short enough that an agent that vanished without releasing
    /// anything is not still holding the task tomorrow morning.
    public static let lifetime: TimeInterval = 2 * 3600

    /// Claims this old are dropped whenever we rewrite the file. They are dead
    /// by every rule below; this is only about the file not growing forever.
    static let maximumAge: TimeInterval = 7 * 24 * 3600

    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    private var url: URL { paths.claims }

    // MARK: - Reading

    public func claims(for projectPath: String) -> [TaskClaim] {
        stored().filter { $0.projectPath == projectPath }
    }

    /// Unlocked on purpose: every write lands by rename, so a reader sees the
    /// whole of one version or the whole of the one before it, never a splice.
    /// A missing file is "nobody has claimed anything", which is also what
    /// every install that predates this feature has.
    func stored() -> [TaskClaim] {
        guard
            let data = try? Data(contentsOf: url),
            let claims = try? JSONCoding.decoder().decode([TaskClaim].self, from: data)
        else { return [] }
        return claims
    }

    /// The claims worth showing, by task id — the expired ones already gone.
    ///
    /// Expiry is a property of the read, like a message's TTL: nobody has to
    /// run a sweep, the app does not have to be up, and a claim left behind by
    /// a session that died stops counting the moment somebody looks.
    public func active(for projectPath: String, now: Date = Date()) -> [String: TaskClaim] {
        let bus = AgentBus(paths: paths)
        var live: [String: TaskClaim] = [:]
        for claim in claims(for: projectPath) where !isStale(claim, bus: bus, now: now) {
            live[claim.taskID] = claim
        }
        return live
    }

    /// Whether this claim has stopped meaning anything.
    ///
    /// Three rules, in the order they are asked:
    ///
    /// 1. The session that made it is provably gone — ended, or a pid the
    ///    kernel no longer knows. Dead on the spot, whatever the clock says.
    ///    This is the rule that makes a claim safe to take: an agent killed by
    ///    a 529 cannot hold a task hostage.
    /// 2. The claimer is still around — the same session, or another live
    ///    session wearing the same label in the same project. Then it stands,
    ///    past the two hours: work that takes an afternoon is not abandoned.
    /// 3. Otherwise the clock decides. Nothing to ask means we only know when
    ///    it was made, and `lifetime` is how long that is worth.
    public func isStale(_ claim: TaskClaim, bus: AgentBus, now: Date = Date()) -> Bool {
        let activities = bus.activities()

        if let sessionID = claim.sessionID,
           let session = activities.first(where: { $0.id == sessionID }) {
            if session.state == .ended || Liveness.isProcessAlive(session.pid) == false { return true }
            if session.isLive { return false }
        }

        let claimerIsWorking = activities.contains { activity in
            activity.projectPath == claim.projectPath
                && activity.isLive
                && Liveness.isProcessAlive(activity.pid) != false
                && Self.sameAgent(AgentBus.label(for: activity.provider), claim.claimedBy)
        }
        if claimerIsWorking { return false }

        return now.timeIntervalSince(claim.claimedAt) > Self.lifetime
    }

    // MARK: - Writing

    /// Take the task, or find out who has it.
    ///
    /// Returns nil when the claim is yours, and otherwise the live claim that
    /// stopped it — the caller reports that and carries on. Re-claiming your
    /// own is not a conflict: it refreshes the clock, which is what an agent
    /// still working on something at the two hour mark wants.
    ///
    /// A granted claim goes on the bus as an `.update` scoped to the project,
    /// so the other agents hear it on their next turn instead of finding out by
    /// collision. That is the announcement half of the feature; without it a
    /// claim is a note to yourself.
    @discardableResult
    public func claim(
        _ task: TaskItem,
        in project: String,
        by label: String,
        sessionID: String? = nil,
        now: Date = Date()
    ) throws -> TaskClaim? {
        let bus = AgentBus(paths: paths)
        var granted: TaskClaim?

        let blocking: TaskClaim? = try LockedFile.withExclusiveLock(url) {
            var all = stored().filter { now.timeIntervalSince($0.claimedAt) < Self.maximumAge }

            if let held = all.first(where: { $0.projectPath == project && $0.taskID == task.id }),
               !Self.sameAgent(held.claimedBy, label),
               !isStale(held, bus: bus, now: now) {
                return held
            }

            all.removeAll { $0.projectPath == project && $0.taskID == task.id }
            let mine = TaskClaim(
                projectPath: project,
                taskID: task.id,
                claimedBy: label,
                sessionID: sessionID,
                claimedAt: now
            )
            all.append(mine)
            try write(all)
            granted = mine
            return nil
        }

        // Outside the lock: posting takes the message log's own lock, and
        // holding two at once is how a deadlock gets written by accident.
        if granted != nil {
            bus.post(
                AgentMessage(
                    from: label,
                    projectPath: project,
                    text: "claimed: \(task.text)",
                    kind: .update
                )
            )
        }
        return blocking
    }

    /// Give a task back. Only your own: taking somebody else's claim off them
    /// silently is the one thing that would make the report untrustworthy.
    @discardableResult
    public func release(_ taskID: String, in project: String, by label: String) throws -> TaskClaim? {
        try LockedFile.withExclusiveLock(url) {
            var all = stored()
            guard let index = all.firstIndex(where: {
                $0.projectPath == project && $0.taskID == taskID && Self.sameAgent($0.claimedBy, label)
            }) else { return nil }
            let removed = all.remove(at: index)
            try write(all)
            return removed
        }
    }

    /// Every claim on a task, whoever holds it. What finishing the task does:
    /// once it is ticked off there is nothing left to be on.
    @discardableResult
    public func releaseAll(_ taskID: String, in project: String) throws -> [TaskClaim] {
        try LockedFile.withExclusiveLock(url) {
            let all = stored()
            let (mine, rest) = all.reduce(into: ([TaskClaim](), [TaskClaim]())) { result, claim in
                if claim.projectPath == project && claim.taskID == taskID {
                    result.0.append(claim)
                } else {
                    result.1.append(claim)
                }
            }
            guard !mine.isEmpty else { return [] }
            try write(rest)
            return mine
        }
    }

    private func write(_ claims: [TaskClaim]) throws {
        try AtomicFile.write(try JSONCoding.encoder(pretty: true).encode(claims), to: url)
    }

    // MARK: - Identity

    /// The session running this command, as far as anything can tell from
    /// outside it.
    ///
    /// The CLI is invoked by an agent's shell tool, so its own pid says nothing
    /// about which session asked. The one live session in this project wearing
    /// this label is a safe guess; two of them is not, and an unknown session
    /// only costs the claim its death rule, never its correctness.
    public func currentSessionID(for label: String, in project: String) -> String? {
        let candidates = AgentBus(paths: paths)
            .others(excluding: nil, project: project)
            .filter { Self.sameAgent(AgentBus.label(for: $0.provider), label) }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    /// `claude` and `claude#exec1` are the same actor as far as a claim goes: a
    /// subagent works on its parent's behalf, and making them fight over a task
    /// would be a bug with a straight face.
    static func sameAgent(_ one: String, _ other: String) -> Bool {
        func base(_ label: String) -> String {
            String(label.split(separator: "#").first ?? "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        return base(one) == base(other)
    }
}
