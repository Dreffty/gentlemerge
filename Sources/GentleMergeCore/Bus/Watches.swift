import Foundation

/// "Tell me when Codex finishes that migration."
///
/// Until this existed the only way to find out was to poll the briefing, which
/// costs a turn every time you look and tells you nothing 90 % of those times.
/// A watch turns the question round: you say it once, and the answer arrives on
/// the bus you already read.
///
/// Deliberately not a daemon. The app already sees every event on its way in —
/// it drains the spool, it buries the sessions that died — so it is the one
/// process that can notice, and the delivery is an ordinary bus message, which
/// means it reaches the owner through the hook it already has. A second process
/// would duplicate this state and break the "two writers by design" rule the
/// rest of the bus is built on.
public struct WatchRule: Codable, Sendable, Equatable, Identifiable {
    /// What an event has to be for a rule to be about it.
    ///
    /// Stored as a plain `String` and not as this enum, for the same reason
    /// `MessageKind` is decoded by hand: a rule written by a newer binary with
    /// a kind this one has never heard of has to survive being read, ignored
    /// and written back out, rather than take the line — or the file — with it.
    public enum Kind: String, Sendable {
        /// A session stopped for good, whether it said goodbye or was buried by
        /// the sweep. The two are the same news to whoever was waiting.
        case sessionEnd = "session-end"
        /// A session finished a turn and the next move is somebody else's.
        case sessionIdle = "session-idle"
        /// A task on a project's list got ticked off, by anyone.
        case taskDone = "task-done"
    }

    public var id: String
    public var createdAt: Date
    /// The label to notify — `claude`, `codex`, `claude#exec1`, `you`. A label
    /// and never an `AgentProvider`: half the agents on this bus will never be
    /// a case of that enum, and an old binary decoding one it does not know
    /// would throw away the whole file.
    public var owner: String
    /// nil means "wherever it happens"; otherwise the rule only looks at events
    /// in this project. Scoped by default, like everything else here.
    public var projectPath: String?
    /// One of `Kind`, kept loose. See the enum.
    public var kind: String
    /// A session id prefix or an agent label for the session kinds; the task's
    /// id for `task-done`.
    public var target: String
    /// Why you asked — written by a human or by an agent, so it is scrubbed
    /// before it is stored and again on its way onto the bus.
    public var note: String?
    /// When this rule stopped standing: the app sets it as it fires the rule,
    /// and `watch rm` sets it to call the whole thing off. Either way the rule
    /// is spent and will never fire again — which is the property that makes
    /// "fires once" true even if two events land in the same drain.
    public var firedAt: Date?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        owner: String,
        projectPath: String? = nil,
        kind: Kind,
        target: String,
        note: String? = nil,
        firedAt: Date? = nil
    ) {
        self.init(
            id: id,
            createdAt: createdAt,
            owner: owner,
            projectPath: projectPath,
            rawKind: kind.rawValue,
            target: target,
            note: note,
            firedAt: firedAt
        )
    }

    /// The way in for a kind we do not have a case for — a test, or a file
    /// written by a newer binary.
    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        owner: String,
        projectPath: String? = nil,
        rawKind: String,
        target: String,
        note: String? = nil,
        firedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.owner = owner
        self.projectPath = projectPath
        self.kind = rawKind
        self.target = target
        self.note = note
        self.firedAt = firedAt
    }

    /// nil for a kind this binary has never heard of: not ours to fire, and not
    /// ours to throw away either.
    public var resolvedKind: Kind? { Kind(rawValue: kind) }

    public var isSpent: Bool { firedAt != nil }

    public func hasLapsed(by now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > Watches.timeToLive
    }

    /// Whether an event in `project` is inside this rule's scope. A rule with no
    /// project watches everywhere — that is what `--global` buys you.
    public func covers(project: String?) -> Bool {
        guard let projectPath else { return true }
        return projectPath == project
    }

    /// Whether the session that just did something is the one being watched.
    ///
    /// Two ways to name a session, because you have exactly two to hand: the id
    /// you read in `who` (by prefix — nobody types a whole UUID) and the label
    /// the agent goes by. The label rule is the delivery rule, so watching
    /// "claude" catches its executors too, and "claude#exec1" catches only that
    /// one.
    public func matchesSession(id sessionID: String?, label: String?) -> Bool {
        if let sessionID, !target.isEmpty, sessionID.hasPrefix(target) { return true }
        guard let label else { return false }
        return AgentBus.addresses(target, label)
    }

    /// What the owner is told. The note goes last: the fact is the part that has
    /// to survive being skim-read.
    public func notice(subject: String) -> String {
        var text = "watch: \(subject)"
        if let note, !note.isEmpty { text += " — \(note)" }
        return text
    }

    public var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// One line for `watch list`.
    public func listLine(now: Date = Date()) -> String {
        let scope = projectName ?? "everywhere"
        var line = "\(shortID)  \(kind) \(target) · \(scope) → \(owner)"
        line += "  (\(RelativeTime.short(from: createdAt, to: now)))"
        if let note, !note.isEmpty { line += " — \(note)" }
        return line
    }

    /// Enough of the id to name it in `watch rm`, which takes a prefix.
    public var shortID: String { String(id.prefix(8)) }
}

/// Every standing watch, in one append-only file.
///
/// Append-only for the same reason the message log is: several processes write
/// it — any agent can ask for a watch from its own shell — and an append under
/// the shared lock is the one write that cannot lose somebody else's. The app
/// is the only thing that ever rewrites the file, when it settles a rule it has
/// just fired or sweeps the lapsed ones out.
///
/// A missing file is "nobody asked for anything", which is what every install
/// that predates this has, and a binary that predates it ignores the file
/// entirely. Nothing here can block an agent: the worst failure mode is a watch
/// that never fires, and the owner asking again.
public struct Watches: Sendable {
    /// How long a rule stands unfired. Two days: long enough to survive a night
    /// and a morning, short enough that a question you have forgotten asking
    /// does not answer itself a week later.
    public static let timeToLive: TimeInterval = 48 * 3600

    /// How long a spent rule is kept in the file after it fired. Only so that
    /// looking straight afterwards shows what happened rather than an empty
    /// file — it can never fire again from the moment `firedAt` is set.
    static let afterlife: TimeInterval = 3600

    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    private var url: URL { paths.watches }

    // MARK: - Reading

    /// Every rule, one row per id, the newest word on each.
    ///
    /// The file holds a rule's history rather than its state — settling one
    /// appends a spent copy — so the last line about an id is the true one.
    /// File order is append order, which is time order.
    public func all() -> [WatchRule] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONCoding.decoder()
        var byID: [String: WatchRule] = [:]
        var order: [String] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let data = line.data(using: .utf8),
                let rule = try? decoder.decode(WatchRule.self, from: data)
            else { continue }
            if byID[rule.id] == nil { order.append(rule.id) }
            byID[rule.id] = rule
        }
        return order.compactMap { byID[$0] }
    }

    /// The rules still worth evaluating: not spent, not lapsed.
    ///
    /// Expiry is a property of the read, like a message's TTL and a claim's:
    /// nothing has to have swept for a two-day-old rule to stop firing, and the
    /// app being closed all weekend cannot resurrect one.
    public func pending(now: Date = Date()) -> [WatchRule] {
        all().filter { !$0.isSpent && !$0.hasLapsed(by: now) }
    }

    // MARK: - Writing

    /// File a rule. One locked append; no read, no rewrite.
    public func add(_ rule: WatchRule) throws {
        let data = try JSONCoding.encoder().encode(rule)
        guard let line = String(data: data, encoding: .utf8) else { return }
        try AtomicFile.append(line, to: url)
    }

    /// Call rules off without rewriting anything: a spent copy of each, which
    /// the next compaction folds away. Returns the rules that were still
    /// standing, so the caller can say what it actually cancelled.
    ///
    /// Used by `watch rm`, which runs in an agent's shell and must not be the
    /// second process that rewrites this file.
    @discardableResult
    public func retire(ids: Set<String>, now: Date = Date()) throws -> [WatchRule] {
        let standing = pending(now: now).filter { ids.contains($0.id) }
        for rule in standing {
            var spent = rule
            spent.firedAt = now
            try add(spent)
        }
        return standing
    }

    /// The rules a prefix names — what `watch rm a1b2c3d4` resolves to.
    public func matching(prefix: String, now: Date = Date()) -> [WatchRule] {
        guard !prefix.isEmpty else { return [] }
        return pending(now: now).filter { $0.id.hasPrefix(prefix) }
    }

    /// Mark these rules fired and rewrite the file without whatever is finished
    /// with. The app only: it is the single process that fires a rule, and the
    /// only one that rewrites this file.
    ///
    /// Fired and lapsed are both dropped here, so the TTL costs nothing on the
    /// read path and the file cannot grow without bound.
    @discardableResult
    public func settle(firing fired: Set<String> = [], now: Date = Date()) throws -> [WatchRule] {
        try LockedFile.withExclusiveLock(url) {
            var kept: [WatchRule] = []
            for var rule in all() {
                if fired.contains(rule.id), !rule.isSpent { rule.firedAt = now }
                if let firedAt = rule.firedAt {
                    guard now.timeIntervalSince(firedAt) < Self.afterlife else { continue }
                } else if rule.hasLapsed(by: now) {
                    continue
                }
                kept.append(rule)
            }

            let encoder = JSONCoding.encoder()
            let lines = kept.compactMap { rule -> String? in
                guard let data = try? encoder.encode(rule) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            let text = lines.joined(separator: "\n")
            try AtomicFile.write(text.isEmpty ? Data() : Data((text + "\n").utf8), to: url)
            return kept
        }
    }

    /// Housekeeping on its own: drop what has lapsed or is long spent. Same
    /// call, nothing fired.
    @discardableResult
    public func compact(now: Date = Date()) throws -> [WatchRule] {
        try settle(firing: [], now: now)
    }
}
