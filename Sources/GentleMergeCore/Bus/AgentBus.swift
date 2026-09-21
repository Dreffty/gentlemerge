import Foundation

/// What one agent session is doing right now.
public struct AgentActivity: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        case working
        /// Stopped on a question in its own terminal.
        case waiting
        /// Finished its turn; the next move is yours.
        case idle
        case ended
    }

    public var id: String
    public var provider: AgentProvider
    public var projectPath: String?
    public var startedAt: Date
    public var updatedAt: Date
    /// The last thing you asked this session for — the best single description
    /// of what it is doing.
    public var currentTask: String?
    public var lastEvent: String?
    public var state: State
    /// The agent's own process, as its hook reported it. This is what makes the
    /// difference between a session that stopped and a session that died.
    /// Optional in both directions: activities written before we kept it decode
    /// fine, and a binary that predates it ignores the key.
    public var pid: Int?
    public var tty: String?
    public var terminalProgram: String?
    /// The session's own inbox socket, as its hook reported it (Claude Code ≥
    /// 2.1.224). A notice delivered there arrives even while the session is
    /// idle, and never types into a foreign tty. Optional in both directions:
    /// activities written before we kept it decode fine, and a binary that
    /// predates it ignores the key.
    public var socketPath: String?

    /// `lastEvent` for a session the sweep buried. One word, because it is also
    /// what the presentation matches on.
    public static let diedEvent = "died"

    public init(
        id: String,
        provider: AgentProvider,
        projectPath: String?,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        currentTask: String? = nil,
        lastEvent: String? = nil,
        state: State = .working,
        pid: Int? = nil,
        tty: String? = nil,
        terminalProgram: String? = nil,
        socketPath: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.projectPath = projectPath
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.currentTask = currentTask
        self.lastEvent = lastEvent
        self.state = state
        self.pid = pid
        self.tty = tty
        self.terminalProgram = terminalProgram
        self.socketPath = socketPath
    }

    public var projectName: String {
        guard let projectPath else { return "—" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public var isLive: Bool {
        state != .ended && Date().timeIntervalSince(updatedAt) < 6 * 3600
    }

    /// Ended without saying so. Worth its own word: a session that closed
    /// cleanly is news to nobody, and one that was killed half-way is.
    public var diedUncleanly: Bool {
        state == .ended && lastEvent == Self.diedEvent
    }

    /// The same activity, told the truth about itself. Used where a reader can
    /// see the process is gone but the file has not been swept yet — only the
    /// app writes that file, and it may not even be running.
    func buried() -> AgentActivity {
        var copy = self
        copy.state = .ended
        copy.lastEvent = Self.diedEvent
        return copy
    }

    public var stateLabel: String {
        switch state {
        case .working: return "working"
        case .waiting: return "waiting on you"
        case .idle: return "idle"
        case .ended: return "ended"
        }
    }

    /// What the peer list is fingerprinted over.
    ///
    /// Deliberately not `briefingLine`: that one ends in "(5m ago)", so a peer
    /// who did nothing but get older changed the fingerprint and broke the
    /// silence. Identity, state and the thing it is doing are what "news"
    /// actually means here.
    public var fingerprintLine: String {
        "\(id)|\(state.rawValue)|\(currentTask ?? lastEvent ?? "")"
    }

    /// One line for another agent to read.
    public func briefingLine(now: Date = Date()) -> String {
        var line = "- \(provider.displayName) · \(projectName)"
        if let currentTask, !currentTask.isEmpty {
            line += " — “\(BriefingRenderer.quote(currentTask))”"
        } else if let lastEvent, !lastEvent.isEmpty, !diedUncleanly {
            line += " — \(BriefingRenderer.quote(lastEvent))"
        }
        // "died 2h ago" rather than "2h ago, ended": the word people want here
        // is the cause, and repeating "died" as the last event would say it
        // twice.
        line += diedUncleanly
            ? " (died \(RelativeTime.short(from: updatedAt, to: now)))"
            : " (\(RelativeTime.short(from: updatedAt, to: now)), \(stateLabel))"
        return line
    }
}

/// What a message is for, which is also how long it is worth reading.
///
/// The bus used to be flat: "FYI, terminé" competed on equal terms with "do not
/// touch that file, I am migrating it", and both were still being read out four
/// hours later.
public enum MessageKind: String, Codable, Sendable {
    /// Said out of courtesy. Stale within the hour it was useful.
    case fyi
    /// The default, and what every message written before this existed is.
    case update
    /// Someone is about to step on someone else's work.
    case urgent
    /// Picking up where another agent left off.
    case handoff
    /// A delegated request: actionable and long-lived.
    case request
    /// The result of a delegated request, sent back to the requester.
    case requestResult = "request-result"
    /// A tombstone: "the message I sent as `refID` no longer applies." Never
    /// rendered — it folds the message it names out of every later read.
    case resolve

    /// How long a message of this kind is worth another agent's context.
    public var timeToLive: TimeInterval {
        switch self {
        case .fyi: return 4 * 3600
        case .update: return 24 * 3600
        // A blocker and a handoff outlive a working day on purpose: the agent
        // they are for may not have had a turn since.
        case .urgent, .handoff, .request, .requestResult: return 72 * 3600
        // Never read, only obeyed. Kept as long as what it buries.
        case .resolve: return .greatestFiniteMagnitude
        }
    }
}

/// A note left for the other agents. The reason the thing is called an inbox.
public struct AgentMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var at: Date
    /// `claude`, `codex`, `hermes`, `you`…
    public var from: String
    /// nil means everyone.
    public var to: String?
    /// nil means every project.
    public var projectPath: String?
    public var text: String
    /// nil is every line written before kinds existed, and every kind a newer
    /// binary invents that this one has never heard of. Both read as `.update`.
    public var kind: MessageKind?
    /// The message this one buries. Only ever set on a `.resolve`.
    public var refID: String?
    /// "Do not wait for their next turn to hear about this." A request, not an
    /// instruction: everything about whether it is safe to type into somebody
    /// else's terminal is decided by the app, in `NudgeGate`, at the moment it
    /// would happen. nil is every message ever written, and every binary that
    /// has never heard of the flag simply does not push.
    public var nudge: Bool?
    /// Files left with the note. nil is every message ever written without one,
    /// and a binary that has never heard of the key simply reads the note.
    public var attachments: [Attachment]?
    /// The note this one corrects. Set by `say --replaces`, and unlike `refID`
    /// it belongs on a normal message: the correction is meant to be read, the
    /// thing it corrects is not. Folded out the same way a resolve folds.
    public var replacesID: String?
    /// Which branch this is for, when it is for one. Routing by model answers
    /// "who are you"; a collision answers "what are you standing on", and those
    /// are not the same question. nil is every message ever written, and every
    /// message meant for the whole project.
    public var toBranch: String?
    /// Schema version of this line. Old lines without it decode as 1; readers
    /// ignore what they do not know per 2.4, and the version tells them when
    /// the shape itself moved on.
    public var v: Int = 1
    /// True when the sender label came from local identity, not free text.
    public var verified: Bool?
    /// The request this message announces or answers, when any.
    public var requestID: String?

    public init(
        id: String = UUID().uuidString,
        at: Date = Date(),
        from: String,
        to: String? = nil,
        projectPath: String? = nil,
        text: String,
        kind: MessageKind? = nil,
        refID: String? = nil,
        nudge: Bool? = nil,
        attachments: [Attachment]? = nil,
        replacesID: String? = nil,
        toBranch: String? = nil,
        verified: Bool? = nil,
        requestID: String? = nil
    ) {
        self.id = id
        self.at = at
        self.from = from
        self.to = to
        self.projectPath = projectPath
        self.text = text
        self.kind = kind
        self.refID = refID
        self.nudge = nudge
        self.attachments = attachments
        self.replacesID = replacesID
        self.toBranch = toBranch
        self.verified = verified
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case id, at, from, to, projectPath, text, kind, refID, nudge, attachments
        case replacesID, toBranch, verified, requestID, v
    }

    /// Written by hand for two reasons: a `kind` this binary does not know about
    /// must not cost us the line, and a missing `v` (every line written before
    /// versions) decodes as 1 instead of dropping the message.
    ///
    /// The synthesised decoder would throw on an unknown case, `compactMap`
    /// would drop the whole message, and a newer binary sharing the same
    /// `messages.jsonl` — which is the normal state of things while you upgrade
    /// one of the two — would make its notes invisible instead of merely
    /// unlabelled. Unknown reads as unlabelled, which reads as `.update`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try container.decode(Date.self, forKey: .at)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        text = try container.decode(String.self, forKey: .text)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap { MessageKind(rawValue: $0) }
        refID = try container.decodeIfPresent(String.self, forKey: .refID)
        nudge = try? container.decodeIfPresent(Bool.self, forKey: .nudge)
        attachments = try? container.decodeIfPresent([Attachment].self, forKey: .attachments)
        replacesID = try? container.decodeIfPresent(String.self, forKey: .replacesID)
        toBranch = try? container.decodeIfPresent(String.self, forKey: .toBranch)
        verified = (try? container.decodeIfPresent(Bool.self, forKey: .verified)).flatMap { $0 } ?? false
        requestID = try? container.decodeIfPresent(String.self, forKey: .requestID)
        v = (try? container.decodeIfPresent(Int.self, forKey: .v)) ?? 1
    }

    // MARK: - Saying which note you mean

    /// A short handle a person can read out loud and an agent can look up.
    ///
    /// The bug this exists for: "look at note 22" cost a session ten minutes,
    /// because 22 was a line number in a file only one of us could see and no
    /// command took it as an argument.
    ///
    /// Derived from the id rather than counted, so it never shifts as messages
    /// expire — the number you were given yesterday still names the same note
    /// today — and so nothing has to keep a counter.
    public var handle: String { Self.handle(for: id) }

    /// FNV-1a folded to sixteen bits. Deliberately not "the first four
    /// characters of the id": ids are ours to change, and a prefix of a
    /// non-random one would collide constantly.
    public static func handle(for id: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%04x", UInt16(truncatingIfNeeded: hash ^ (hash >> 16)))
    }

    /// Whether `query` names this message: its handle, its whole id, or enough
    /// of the front of the id to be worth accepting.
    public func answersTo(_ query: String) -> Bool {
        let wanted = query.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard !wanted.isEmpty else { return false }
        return wanted == handle
            || id.lowercased() == wanted
            || (wanted.count >= 6 && id.lowercased().hasPrefix(wanted))
    }

    /// The kind to treat this message as. Everything that reads the bus goes
    /// through here rather than through `kind`, so that "no kind" has exactly
    /// one meaning and it is written down once.
    public var effectiveKind: MessageKind { kind ?? .update }

    /// Whether this message has outlived what it was for.
    public func hasExpired(by now: Date) -> Bool {
        now.timeIntervalSince(at) > effectiveKind.timeToLive
    }

    /// The tag a briefing puts in front of the line, when the kind is the first
    /// thing the reader needs to know.
    public var briefingTag: String? {
        switch effectiveKind {
        case .urgent: return "[URGENT]"
        case .handoff: return "[HANDOFF]"
        case .request: return "[REQUEST]"
        case .requestResult: return "[REQUEST RESULT]"
        case .fyi, .update, .resolve: return nil
        }
    }

    /// Urgent and handoff jump the queue, and are never dropped by the cap on
    /// how much a briefing may cost.
    public var isPriority: Bool {
        effectiveKind == .urgent || effectiveKind == .handoff || effectiveKind == .request || effectiveKind == .requestResult
    }

    public var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

/// The shared channel between every agent you have running.
///
/// Two writers by design: the menu bar app owns the activity file (it sees every
/// hook event), and the CLI — running inside an agent's own hook — only reads it
/// and writes files of its own, one per agent. Nothing needs a lock.
public struct AgentBus: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: - Activity

    public func activities() -> [AgentActivity] {
        let stored: [AgentActivity]
        if let data = try? Data(contentsOf: paths.activities),
           let decoded = try? JSONCoding.decoder().decode([AgentActivity].self, from: data) {
            stored = decoded
        } else {
            stored = []
        }

        // The agents' own marks, merged in here so that every reader — `who`,
        // the peer list, the briefing — gets them without knowing they exist.
        //
        // The app's record wins where both describe the same agent: it sees
        // every hook event, so it knows about waiting and ended, while a mark
        // only ever says "working". But the app is not always running, and that
        // was the whole failure: `who` said nobody was working while five
        // sessions were mid-turn.
        let known = Set(stored.filter(\.isLive).map(\.id))
        return stored + Presence.live(paths: paths).filter { !known.contains($0.id) }
    }

    public func save(_ activities: [AgentActivity]) {
        do {
            try AtomicFile.write(try JSONCoding.encoder().encode(activities), to: paths.activities)
        } catch {
            Log.error("could not save activity: \(error.localizedDescription)")
        }
    }

    /// Everything else that is live, newest first. The session asking is never
    /// told about itself.
    ///
    /// The liveness probe is here and not only in the app's sweep because this
    /// is what a hook and `brief` call: they run in your shell whether the app
    /// is up or not, and a session that died with the app closed would
    /// otherwise be listed as working for six hours. `!= false` on purpose —
    /// an activity with no pid is unknown, never dead.
    public func others(excluding sessionID: String?, project: String? = nil) -> [AgentActivity] {
        activities()
            .filter { $0.id != sessionID && $0.isLive }
            .filter { Liveness.isProcessAlive($0.pid) != false }
            .filter { project == nil || $0.projectPath == project }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The sessions that stopped without saying goodbye, newest first.
    ///
    /// Two kinds land here and read the same way: the ones the app's sweep has
    /// already marked, and the ones whose process is provably gone but which
    /// nobody has swept yet. Never part of a briefing — a dead agent is not a
    /// peer, and telling a session about one every turn is the noise this
    /// replaces. It is `who`, where you are the one asking.
    public func died(
        project: String? = nil,
        within interval: TimeInterval = 6 * 3600,
        now: Date = Date()
    ) -> [AgentActivity] {
        activities()
            .filter { now.timeIntervalSince($0.updatedAt) < interval }
            .filter { project == nil || $0.projectPath == project }
            .compactMap { activity in
                if activity.diedUncleanly { return activity }
                guard activity.state != .ended, Liveness.isProcessAlive(activity.pid) == false else { return nil }
                return activity.buried()
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The peers a session in `project` should hear about, and how many others
    /// are working somewhere else entirely.
    ///
    /// One read of the activity file for both halves: this runs inside a hook,
    /// on every turn, and the two numbers have to come from the same snapshot
    /// or the count could disagree with the list it is appended to.
    func peers(excluding sessionID: String?, project: String?) -> (here: [AgentActivity], elsewhere: Int) {
        let live = others(excluding: sessionID)
        guard let project else { return (live, 0) }
        let here = live.filter { $0.projectPath == project }
        return (here, live.count - here.count)
    }

    /// The single line a whole other project's worth of agents is allowed to
    /// cost the session reading this.
    static func elsewhereLine(count: Int) -> String {
        count == 1
            ? "+ 1 agent in another project — gentlemerge who --all"
            : "+ \(count) agents in other projects — gentlemerge who --all"
    }

    // MARK: - Messages

    @discardableResult
    public func say(
        from: String,
        to: String? = nil,
        text: String,
        projectPath: String? = nil,
        nudge: Bool = false,
        attach: [Attachment]? = nil,
        kind: MessageKind = .update,
        requestID: String? = nil,
        verified: Bool? = nil
    ) throws -> Redactor.Result {
        let message = AgentMessage(
            from: from,
            to: to,
            projectPath: projectPath,
            text: text,
            kind: kind,
            nudge: nudge ? true : nil,
            attachments: attach?.isEmpty == true ? nil : attach,
            verified: verified,
            requestID: requestID
        )
        let result = post(message)
        if result.isSuppressed { throw RequestError.suppressed }
        return result
    }

    public func delegate(
        from: String,
        fromVerified: Bool,
        to: String,
        projectPath: String,
        title: String,
        spec: String,
        inputs: [String],
        expectedOutput: String?,
        mayTouch: [String],
        budgetMinutes: Int
    ) throws -> AgentRequest {
        guard (1...1440).contains(budgetMinutes) else { throw RequestError.invalidBudget }
        let combined = Redactor.scrub(title + "\n" + spec)
        guard !combined.isSuppressed else { throw RequestError.suppressed }

        let requests = Requests(paths: paths)
        var request = AgentRequest(
            id: requests.freshID(),
            from: from,
            fromVerified: fromVerified,
            to: to,
            projectPath: projectPath,
            title: Redactor.scrub(title).text,
            spec: Redactor.scrub(spec).text,
            inputs: inputs.map { Redactor.scrub($0).text },
            expectedOutput: expectedOutput.map { Redactor.scrub($0).text },
            mayTouch: mayTouch,
            budgetMinutes: budgetMinutes
        )

        if to.hasPrefix("capability:") {
            let capability = String(to.dropFirst("capability:".count))
            guard let target = Presence.labels(withCapability: capability, project: projectPath, paths: paths).first else {
                throw RequestError.noCapableAgent(capability)
            }
            request.resolvedTo = target
        } else {
            request.resolvedTo = to
        }
        request.state = .assigned
        let target = request.resolvedTo ?? to

        do {
            for pattern in mayTouch {
                _ = try PathClaims(paths: paths).claim(
                    pattern: pattern,
                    label: target,
                    project: projectPath,
                    intent: "request \(request.id)",
                    ttl: Double(max(budgetMinutes, 1)) * 60,
                    implicit: false,
                    requestID: request.id
                )
            }

            let taskTitle = Redactor.scrub("[\(request.id)] \(request.title)").text
            let handoff = ProjectRegistry.addTask(taskTitle, to: projectPath, by: from)
            request.taskID = handoff.tasks.first { $0.text == taskTitle }?.id

            if let taskID = request.taskID {
                let watch = WatchRule(
                    owner: from,
                    projectPath: projectPath,
                    kind: .taskDone,
                    target: taskID,
                    note: "request \(request.id) finished"
                )
                try Watches(paths: paths).add(watch)
                request.watchID = watch.id
            }

            try requests.save(request)
            try say(
                from: from,
                to: target,
                text: request.busSummary + "\nRun `gentlemerge request show \(request.id)` for the spec.",
                projectPath: projectPath,
                nudge: false,
                kind: .request,
                requestID: request.id,
                verified: fromVerified
            )
            Ledger(url: paths.ledger).append(LedgerEntry(
                at: Date(),
                kind: .note,
                project: projectPath,
                title: "request.created",
                summary: "\(request.id): \(from) -> \(target), verified \(fromVerified)"
            ))
            return request
        } catch {
            try? PathClaims(paths: paths).release(
                label: target,
                project: projectPath,
                patterns: mayTouch,
                requestID: request.id
            )
            throw error
        }
    }

    @discardableResult
    public func post(_ message: AgentMessage) -> Redactor.Result {
        var message = message
        let result = Redactor.scrub(message.text)

        if result.isSuppressed {
            // Dropping it silently would leave the sender thinking it went out.
            // The others get told something was withheld, not what it was —
            // and the ledger records the fact with the kinds found, never the
            // content, so "nothing shown" stays distinguishable from "nothing new".
            message.text = "(a message was withheld: it was almost entirely \(result.summary))"
            Ledger(url: paths.ledger).append(LedgerEntry(
                kind: .note,
                itemID: message.id,
                project: message.projectPath,
                title: "message.withheld",
                summary: "\(message.from)→\(message.to ?? "*"): \(result.summary)"
            ))
        } else {
            message.text = result.text
        }

        do {
            let data = try JSONCoding.encoder().encode(message)
            if let line = String(data: data, encoding: .utf8) {
                try AtomicFile.append(line, to: paths.messages)
            }
        } catch {
            Log.error("could not post message: \(error.localizedDescription)")
        }
        return result
    }

    public func messages(limit: Int = 100) -> [AgentMessage] {
        guard let contents = try? String(contentsOf: paths.messages, encoding: .utf8) else { return [] }
        let decoder = JSONCoding.decoder()
        return contents
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(AgentMessage.self, from: data)
            }
    }

    /// The messages still worth showing somebody: the tombstones gone, whatever
    /// they bury gone with them, and — when a clock is given — nothing that has
    /// outlived its kind.
    ///
    /// Nothing is rewritten to make this true. Expiry is a property of the read,
    /// so a fresh binary and an old one can share the file, the log stays the
    /// record of what was actually said, and `--done` costs one append instead
    /// of a rewrite under a lock.
    ///
    /// `now` is nil where age is not a reason to hide something — your own
    /// window, where the list is history rather than a briefing.
    public func visibleMessages(limit: Int = 100, expiringAt now: Date? = nil) -> [AgentMessage] {
        Self.folded(messages(limit: limit), expiringAt: now)
    }

    /// Pure so the rule can be tested and reused without touching the disk.
    static func folded(_ messages: [AgentMessage], expiringAt now: Date?) -> [AgentMessage] {
        let buried = resolvedIDs(in: messages)
        return messages.filter { message in
            guard message.effectiveKind != .resolve else { return false }
            guard !buried.contains(message.id) else { return false }
            guard let now else { return true }
            return !message.hasExpired(by: now)
        }
    }

    /// Take back what you have said here: one tombstone for each of your notes
    /// in this scope that nobody has resolved yet. Returns the originals.
    ///
    /// Scope is matched exactly, `--global` notes included by asking for nil.
    /// Finishing something in one project is no reason to fall silent in
    /// another, and an agent that resolved more than it meant to cannot undo it.
    ///
    /// Idempotent by construction: the second run finds its own tombstones and
    /// has nothing left to bury.
    @discardableResult
    public func resolveOwn(author: String, project: String?, limit: Int = 500) -> [AgentMessage] {
        let all = messages(limit: limit)
        let already = Self.resolvedIDs(in: all)
        let mine = all.filter { message in
            message.from == author
                && message.effectiveKind != .resolve
                && !already.contains(message.id)
                && message.projectPath == project
        }
        for original in mine {
            post(
                AgentMessage(
                    from: author,
                    to: original.to,
                    projectPath: original.projectPath,
                    text: Self.doneText(for: original),
                    kind: .resolve,
                    refID: original.id
                )
            )
        }
        return mine
    }

    /// What a tombstone says out loud.
    ///
    /// A binary that predates kinds will render this as an ordinary message, so
    /// it has to read as something harmless and true — the opening words of what
    /// is being taken back — rather than as a bare id or an empty line.
    static func doneText(for message: AgentMessage) -> String {
        let words = message.text.split(separator: " ", omittingEmptySubsequences: true)
        let head = words.prefix(8).joined(separator: " ")
        return "done: \(head)\(words.count > 8 ? "…" : "")"
    }

    /// The ids somebody has said no longer apply.
    ///
    /// Taken over the whole log rather than over the reader's slice of it: a
    /// resolve is addressed like the message it buries, and a reader who is not
    /// its addressee must still stop being shown the original.
    /// Every message `query` could be naming — its handle, its id, or a long
    /// enough prefix of one.
    ///
    /// Deliberately searches the raw list rather than the visible one: somebody
    /// asking for a note by name wants to see it even when it has expired or
    /// been corrected, and "that one is gone" is an answer only reachable by
    /// finding it first.
    public func messages(matching query: String, limit: Int = 500) -> [AgentMessage] {
        messages(limit: limit).filter { $0.answersTo(query) }
    }

    /// Whether this message is still standing: not expired, not buried by a
    /// tombstone or a correction. `show` needs to say so out loud.
    public func isStanding(_ message: AgentMessage, at now: Date = Date()) -> Bool {
        !message.hasExpired(by: now)
            && !Self.resolvedIDs(in: messages(limit: 500)).contains(message.id)
    }

    static func resolvedIDs(in messages: [AgentMessage]) -> Set<String> {
        // Two ways for a note to stop applying, and both end here. A tombstone
        // says "forget this"; a correction says "read this instead" — and the
        // reason a correction has to bury its original is the whole point of
        // having one. A bus that keeps a wrong number next to the right one
        // makes the reader guess which came first.
        let tombstoned = messages.filter { $0.effectiveKind == .resolve }.compactMap(\.refID)
        let superseded = messages.filter { $0.effectiveKind != .resolve }.compactMap(\.replacesID)
        return Set(tombstoned + superseded)
    }

    // MARK: - Briefing

    /// What a session should be told before its next turn: who else is working,
    /// and anything addressed to it. Returns nil when nothing has changed since
    /// the last time we told this session — silence is the default.
    ///
    /// `me` is a plain label ("claude", "codex", "hermes"), not a provider: the
    /// bus routes by what an agent calls itself, and half the agents on it will
    /// never be a case of `AgentProvider`. Passing nil means an anonymous read
    /// — `brief` run by hand or by a tool with no session of its own.
    public func briefing(
        sessionID: String?,
        me: String?,
        project: String?,
        branch: String? = nil,
        now: Date = Date(),
        mode: BriefingMode = .full,
        persistCursor: Bool = true
    ) -> String? {
        // Peers are the ones sharing this project. A session in `clipapp` was
        // being told about another project's simulator, and paying context
        // for it every turn.
        let (peers, elsewhere) = self.peers(excluding: sessionID, project: project)
        let pending = undelivered(to: sessionID, me: me, project: project, branch: branch, now: now)

        // Per-session cursor: what this session has already been told, beyond
        // the message marker — later steps (claims, requests, watches) use it
        // to announce only transitions. Loaded only for a named session.
        let cursorStore = BriefingCursorStore(paths: paths)
        var cursor = sessionID.map { cursorStore.load(sessionID: $0) } ?? BriefingCursor(sessionID: "anon")
        // The timestamp moves whether or not this read had news: the anchor is
        // "when we last injected", not "when we last had something to say".
        // Saved only for a named session and never for `persistCursor: false` —
        // a human's `brief` is a read, and must not consume the agent's deltas.
        func stampCursor() {
            if mode == .full { cursor.lastFullAt = now } else { cursor.lastDeltaAt = now }
            if persistCursor, sessionID != nil { cursorStore.save(cursor) }
        }

        var requestBlocks: [(heading: String, lines: [String])] = []
        var requestUpdates: [(id: String, state: String, line: String)] = []
        if let me, let project {
            let requests = Requests(paths: paths)
            let forMe = requests.pending(for: me, project: project)
            if !forMe.isEmpty {
                requestBlocks.append((
                    heading: "Requests for you",
                    lines: forMe.map { "\(BriefingRenderer.quote($0.busSummary)) · from \($0.from)" }
                ))
            }

            let mine = requests.mine(from: me, project: project)
            let changed = mine.filter { cursor.seenRequestStates[$0.id] != $0.state.rawValue }
            let shownMine = mode == .full ? mine.filter { $0.state != .acked } : changed
            if !shownMine.isEmpty {
                requestBlocks.append((
                    heading: mode == .full ? "Your requests" : "Request updates",
                    lines: shownMine.map { request in
                        let line = "[\(request.id)] \(request.state.rawValue)"
                            + (request.result.map { ": \(BriefingRenderer.quote($0))" } ?? "")
                            + " · \(request.resolvedTo ?? request.to)"
                        requestUpdates.append((request.id, request.state.rawValue, line))
                        return line
                    }
                ))
            }
        }

        guard !peers.isEmpty || elsewhere > 0 || !pending.isEmpty || !requestBlocks.isEmpty else {
            stampCursor()
            return nil
        }

        let shown = Array(peers.prefix(6))
        var lines: [String] = []
        if !shown.isEmpty || elsewhere > 0 {
            lines.append("Other agents you have running right now (from GentleMerge):")
            lines += shown.map { $0.briefingLine(now: now) }
            if elsewhere > 0 { lines.append(Self.elsewhereLine(count: elsewhere)) }
        }

        // The peer list is the part that repeats turn after turn. A new message
        // always goes through; an unchanged peer list does not. Taken over the
        // fingerprint lines rather than the rendered ones so that time passing
        // is not mistaken for news.
        //
        // The agents elsewhere enter it by count and never by content: what they
        // are doing is precisely what this session is not being told, so letting
        // it in would let any event in any other project break the silence — the
        // noise this scoping exists to remove. Absent when there are none, so a
        // marker written before scoping still matches.
        var material = shown.map(\.fingerprintLine)
        if elsewhere > 0 { material.append("elsewhere:\(elsewhere)") }
        let fingerprint = Self.fingerprint(material.joined(separator: "\n"))
        if pending.isEmpty, requestBlocks.isEmpty, let marker = deliveryMarker(for: sessionID), fingerprint == marker.lastFingerprint {
            return nil
        }

        // The cap exists so a backlog cannot cost a session its whole turn, and
        // it used to be the last eight by time — which is exactly how a "do not
        // touch that file" gets pushed off the end by eight people saying they
        // finished something. Priority is taken out first and never capped:
        // there are only ever a handful, and they are the reason to read at all.
        let priority = pending.filter(\.isPriority)
        let delivered = priority + pending.filter { !$0.isPriority }.suffix(8)
        // What this reader touches — claims plus request scope. Empty means no
        // signal, and a reader with no footprint gets everything, exactly as
        // before. Delta only: a session start needs the whole map.
        let readerScope: [String] = {
            guard mode == .delta, let me else { return [] }
            let mine = (project.map { PathClaims(paths: paths).live(project: $0) }
                ?? PathClaims(paths: paths).load()).filter { $0.label == me }.map(\.pattern)
            let touch = project.flatMap {
                Requests(paths: paths).inProgress(assignedTo: me, project: $0).first?.mayTouch
            } ?? []
            return BriefingRelevance.scope(myClaimPatterns: mine, mayTouch: touch)
        }()
        // Out-of-scope broadcasts, folded per sender: the notes stay on the
        // bus for `brief --as`, this just spends no turn tokens on them.
        var coalesced: [String: (count: Int, attachments: [String])] = [:]
        var urgentLines: [String] = []
        var messageLines: [String] = []
        if !delivered.isEmpty {
            for message in delivered {
                let scope = message.projectName.map { " · \($0)" } ?? ""
                // Only worth saying when the reader is not the addressee — and
                // an executor reading what was sent to "claude" is one, so the
                // same rule that delivered the line decides whether to caveat it.
                let forSomebodyElse = message.to.map { to in
                    me.map { !Self.addresses(to, $0) } ?? true
                } ?? false
                let addressed = forSomebodyElse ? " (for \(message.to!))" : ""
                // In front of the sender, not the text: it is what decides
                // whether the rest of the line gets read now or later.
                let tag = message.briefingTag.map { "\($0) " } ?? ""
                // The handle goes on every line so that "look at 3f8a" is a
                // thing either of you can say and the other can look up. Four
                // characters: cheap enough to charge every line for, long
                // enough not to collide across a day of notes.
                let handle = "#\(message.handle) "
                // A note that corrects another says so. The original is already
                // folded out of this list, so without the word the reader has no
                // way to know the subject was ever in dispute.
                let corrects = message.replacesID == nil ? "" : " (corrects an earlier note)"
                let branch = message.toBranch.map { " (for branch \($0))" } ?? ""
                let body = "- \(handle)\(tag)\(message.from)\(scope)\(addressed)\(branch)\(corrects)"
                    + " (\(RelativeTime.short(from: message.at, to: now))): \(BriefingRenderer.quote(message.text))"
                let attachments = attachmentLines(of: message)
                if !readerScope.isEmpty, !message.isPriority, message.to == nil {
                    var group = coalesced[message.from] ?? (0, [])
                    group.count += 1
                    // Paths, not summaries: the fold must not eat a pointer to
                    // a file the reader may actually need.
                    group.attachments += attachments.filter { $0.hasPrefix("    ") == false }
                    coalesced[message.from] = group
                } else if message.isPriority {
                    urgentLines.append(body)
                    urgentLines += attachments
                } else {
                    messageLines.append(body)
                    messageLines += attachments
                }
            }
            // Folded broadcasts, steadiest senders first — deterministic order
            // for a deterministic fingerprint downstream.
            if let me {
                for sender in coalesced.keys.sorted() {
                    let group = coalesced[sender]!
                    messageLines.append(BriefingRelevance.coalescedLine(from: sender, count: group.count, me: me))
                    messageLines += group.attachments
                }
            }
            if !messageLines.isEmpty {
                if !lines.isEmpty { lines.append("") }
                // An anonymous reader is looking at somebody else's post as well as
                // its own, so the heading may not promise they are all for you.
                lines.append(me == nil ? "Messages on the bus:" : "Messages left for you:")
                lines += messageLines
            }
        }

        lines.append("")
        lines.append(
            "Say something back to the others with `gentlemerge say \"...\"`, and tell them what you"
                + " are about to change before you change it."
        )
        if !delivered.isEmpty {
            lines.append(
                "The `#abcd` in front of a note is its handle: `gentlemerge show abcd` reads it in"
                    + " full, and `gentlemerge say --replaces abcd \"...\"` corrects it in place"
                    + " rather than leaving both versions standing."
            )
        }

        // Path claims by others in my project — the "where" layer of not
        // stepping on each other. Full: all live ones. Delta: only the ones
        // this session has not been shown, via the cursor — and only the ones
        // that touch this reader's scope. An out-of-scope claim stays unseen
        // (never marked shown), so it costs this reader nothing and still
        // surfaces the moment their scope grows onto it.
        if let project {
            let all = PathClaims(paths: paths).live(project: project).filter { $0.label != me }
            let unseen = (mode == .full) ? all : all.filter { !cursor.seenClaimIDs.contains($0.id) }
            let shownClaims = (mode == .full || readerScope.isEmpty)
                ? unseen
                : unseen.filter { BriefingRelevance.touchesScope(pattern: $0.pattern, scope: readerScope) }
            if !shownClaims.isEmpty {
                lines.append("")
                lines.append(mode == .full ? "Others are editing:" : "Newly claimed by others:")
                for claim in shownClaims {
                    let minutes = max(Int(claim.expires.timeIntervalSinceNow / 60), 0)
                    let why = claim.intent.map { " — \(BriefingRenderer.quote($0))" } ?? ""
                    lines.append("- \(claim.label): `\(claim.pattern)`\(why) [\(minutes)m]")
                }
                shownClaims.forEach { cursor.seenClaimIDs.insert($0.id) }
            }
            // Ownership zones are worth their tokens once per session — full
            // mode only. Pinned zones say so: HANDOFF.md zones are conveniences
            // the judged agent could have written itself.
            if mode == .full {
                let (own, authority) = Ownership.effective(project: project, paths: paths)
                if !own.rules.isEmpty {
                    lines.append("")
                    lines.append(authority == .pinned ? "Ownership zones (pinned):" : "Ownership zones (per HANDOFF.md, unpinned):")
                    lines += own.rules.map { "- \($0.pattern) → \($0.owner)" }
                }
            }
        }

        for block in requestBlocks where !block.lines.isEmpty {
            lines.append("")
            lines.append(block.heading + ":")
            lines += block.lines.map { "- \($0)" }
        }

        record(delivery: fingerprint, delivered: delivered, for: sessionID)
        // The hard budget lives here and not only in the renderer: the existing
        // briefing builds its own lines, so the cap is what makes sure the
        // per-turn injection can never balloon no matter what sections grow.
        // Anonymous and non-persistent reads (a human's `brief`) are not charged
        // per turn, so they are not capped either.
        //
        // Conflict-class lines lead and are exempt from the cut: a warning
        // enters even when the rest of the budget is spent.
        let urgentHead = urgentLines.isEmpty ? [] : ["Needs you now:"] + urgentLines + [""]
        let text = Redactor.scrub((urgentHead + lines).joined(separator: "\n")).text
        let output = mode == .delta && persistCursor
            ? BriefingRenderer.cap(text, mode: mode, keeping: urgentHead.count)
            : text
        // A candidate is not delivered until its complete, scrubbed line survives
        // the final budget. Omitted updates stay pending for the next delta.
        let deliveredLines = Set(output.components(separatedBy: "\n"))
        for update in requestUpdates {
            let line = Redactor.scrub("- " + update.line).text
            if deliveredLines.contains(line) {
                cursor.seenRequestStates[update.id] = update.state
            }
        }
        stampCursor()
        return output
    }

    /// Where a file is, and just enough of it to decide whether to open it.
    ///
    /// The path and never the contents: an agent that wants the report has a
    /// `Read` of its own, and it can spend its own context on the parts it
    /// needs. Handing over the whole file here is precisely the cost this
    /// channel exists to avoid.
    public func attachmentLines(of message: AgentMessage) -> [String] {
        let store = ArtifactStore(paths: paths)
        return (message.attachments ?? []).flatMap { attachment -> [String] in
            var lines = [attachment.line(at: store.displayPath(for: attachment))]
            if let summary = attachment.summary {
                lines += BriefingRenderer.quote(summary)
                    .split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }
            }
            return lines
        }
    }

    @available(*, deprecated, message: "Routing is by label now: briefing(sessionID:me:project:now:)")
    public func briefing(
        sessionID: String?,
        provider: AgentProvider?,
        project: String?,
        now: Date = Date()
    ) -> String? {
        briefing(sessionID: sessionID, me: provider.map(Self.label(for:)), project: project, now: now)
    }

    /// The messages this reader has not been handed yet, oldest first.
    ///
    /// With an identity: broadcasts plus what is addressed to you, never your
    /// own words coming back. Without one: everything in scope, including what
    /// was addressed to somebody else — hiding those was how a message to
    /// `hermes` became a message nobody could ever read, since `brief` is the
    /// only way Hermes and friends read the bus at all.
    func undelivered(
        to sessionID: String?,
        me: String?,
        project: String?,
        branch: String? = nil,
        now: Date = Date()
    ) -> [AgentMessage] {
        let marker = deliveryMarker(for: sessionID)
        let floor = marker?.lastMessageAt ?? Date.distantPast
        let seen = Set(marker?.deliveredIDs ?? [])
        // Timestamps are stored to the second, so a strict floor drops a message
        // that shares its second with the last one delivered. We can only relax
        // it once ids are being recorded — an older marker has no way to tell us
        // which of the two it already showed.
        let dedupedByID = marker?.deliveredIDs != nil

        // Folded before anything else: a message somebody has resolved was never
        // yours to be handed, and one that has outlived its kind is worse than
        // nothing — a blocker that was lifted three hours ago still reads like a
        // blocker.
        return visibleMessages(expiringAt: now)
            .filter { dedupedByID ? $0.at >= floor : $0.at > floor }
            .filter { !seen.contains($0.id) }
            .filter { message in
                // Not your own words coming back at you. Matched exactly, unlike
                // the address: a subagent's report is news to the session that
                // spawned it, and swallowing it would be the one delivery that
                // mattered.
                guard let me else { return true }
                guard message.from != me else { return false }
                if let to = message.to { return Self.addresses(to, me) }
                return true
            }
            .filter { message in
                guard let scope = message.projectPath, let project else { return true }
                return scope == project
            }
            .filter { message in
                // Addressed to a branch, which is a different question from
                // addressed to a model: a collision is about what you are
                // standing on, not about who you are. A reader that cannot say
                // which branch it is on is told anyway — silence would be worse
                // than a note meant for somebody else.
                guard let wanted = message.toBranch else { return true }
                guard let branch else { return true }
                return wanted == branch
            }
            .sorted { $0.at < $1.at }
    }

    @available(*, deprecated, message: "Routing is by label now: undelivered(to:me:project:)")
    func undelivered(
        to sessionID: String?,
        provider: AgentProvider?,
        project: String?
    ) -> [AgentMessage] {
        undelivered(to: sessionID, me: provider.map(Self.label(for:)), project: project)
    }

    /// Whether a note addressed to `to` is for a reader calling itself `me`.
    ///
    /// A label is free text, and `#` is the one piece of structure in it: the
    /// part before it is the agent, the part after is which of its subagents.
    /// So `--to claude` reaches the director and every executor it launched —
    /// you rarely know their names, and the point of saying "claude" is to
    /// reach whoever is being claude right now. `--to claude#exec1` is exact,
    /// and never spills onto `claude#exec2` or onto the director itself.
    ///
    /// Deliberately not the `sameAgent` rule claims use: a claim asks whether
    /// two labels are the same actor (they are), delivery asks whether this
    /// reader is inside the audience that was named (an executor is inside
    /// "claude", the director is not inside "claude#exec1").
    static func addresses(_ to: String, _ me: String) -> Bool {
        to == me || me.hasPrefix(to + "#")
    }

    /// The session id a reader that names itself keeps its delivery marker
    /// under: `brief --as hermes` consumes through `delivered/reader-hermes`.
    ///
    /// Prefixed, so it cannot land on a real session's marker — those are named
    /// by the agent's own session id and one of them is free to be the literal
    /// string "hermes". Everything a path could read as a separator is folded
    /// away for the same reason: the label reaches us from a shell wrapper, and
    /// a marker file belongs in `delivered/` whatever somebody types.
    public static func readerSessionID(for label: String) -> String {
        let safe = String(label.map { character in
            character.isLetter || character.isNumber || "#-_.".contains(character) ? character : "-"
        })
        return "reader-\(safe)"
    }

    public static func label(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .unknown: return "agent"
        }
    }

    /// Who to credit for a command an agent ran itself.
    ///
    /// `GENTLEMERGE_NAME` is asked first because it is the only thing a
    /// *subagent* can be told. A session that launches three executors is
    /// otherwise four processes all signing as "claude", inheriting the same
    /// `CLAUDECODE` from the parent: you cannot address one of them, and you
    /// cannot tell afterwards which of them said what. Exported as
    /// `claude#exec1`, an executor gets a name of its own and stays reachable
    /// as "claude".
    ///
    /// A label is never trusted to be pretty — it is typed by hand — but it is
    /// only ever a name, and everything that leaves here is scrubbed anyway.
    public static func label(in environment: [String: String]) -> String {
        if let name = environment["GENTLEMERGE_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if environment["CLAUDECODE"] != nil || environment["CLAUDE_PROJECT_DIR"] != nil { return "claude" }
        if environment["CODEX_SANDBOX"] != nil || environment["CODEX_HOME"] != nil { return "codex" }
        return "you"
    }

    // MARK: - Delivery markers

    struct DeliveryMarker: Codable, Sendable {
        var lastFingerprint: String?
        var lastMessageAt: Date?
        /// Optional so a marker written by an older binary still decodes, and so
        /// an older binary still decodes one written here.
        var deliveredIDs: [String]?
    }

    /// Enough to cover any plausible backlog without letting a long-lived
    /// session's marker grow without bound.
    static let deliveredIDCap = 300

    func markerURL(for sessionID: String) -> URL {
        paths.delivered.appendingPathComponent("\(Self.fileSafeSessionID(sessionID)).json")
    }

    /// Session ids arrive in hook payloads — agent-controlled free text — but
    /// marker files live under delivered/, so an id carrying "/" or ".." must
    /// never reach a path. Remapped deterministically (same id, same file on
    /// read and write); sane ids — UUIDs, reader-* names — map to themselves
    /// byte for byte, so nothing already stored migrates.
    static func fileSafeSessionID(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.+#"))
        var safe = String(String(id.unicodeScalars.filter { allowed.contains($0) }.map(Character.init)).prefix(128))
        while safe.contains("..") { safe = safe.replacingOccurrences(of: "..", with: "-") }
        while safe.hasPrefix(".") { safe = String(safe.dropFirst()) }
        return safe.isEmpty ? "session" : safe
    }

    func deliveryMarker(for sessionID: String?) -> DeliveryMarker? {
        guard let sessionID else { return nil }
        guard
            let data = try? Data(contentsOf: markerURL(for: sessionID)),
            let marker = try? JSONCoding.decoder().decode(DeliveryMarker.self, from: data)
        else { return DeliveryMarker() }
        return marker
    }

    func record(delivery fingerprint: String, delivered: [AgentMessage], for sessionID: String?) {
        guard let sessionID else { return }
        var marker = deliveryMarker(for: sessionID) ?? DeliveryMarker()
        marker.lastFingerprint = fingerprint
        // The newest of them, not the last one printed: priority messages are
        // rendered first and may well be older than the rest, so `last` would
        // walk the floor backwards.
        if let last = delivered.map(\.at).max() { marker.lastMessageAt = last }
        if !delivered.isEmpty {
            var ids = marker.deliveredIDs ?? []
            ids.append(contentsOf: delivered.map(\.id))
            marker.deliveredIDs = Array(ids.suffix(Self.deliveredIDCap))
        }
        try? FileManager.default.createDirectory(at: paths.delivered, withIntermediateDirectories: true)
        if let data = try? JSONCoding.encoder().encode(marker) {
            try? AtomicFile.write(data, to: markerURL(for: sessionID))
        }
    }

    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Keep the message log from growing forever, and take the chance to drop
    /// what the old unlocked append spliced in half: a line that will not decode
    /// is a line no reader was ever going to see.
    ///
    /// `keepingAtMost` is a budget for chatter, not a ceiling on the file: a
    /// standing blocker and the tombstone of something still in the log are kept
    /// past it. Both are rare and both change what a reader is told.
    ///
    /// Attachments are collected here too, and only here: an artifact is alive
    /// exactly as long as a message points at it, so the moment that decides
    /// which messages survive is also the only moment that knows which files
    /// still have a reason to exist.
    ///
    /// Returns how many lines went away.
    @discardableResult
    public func pruneMessages(
        olderThan interval: TimeInterval = 7 * 24 * 3600,
        keepingAtMost limit: Int = 500,
        now: Date = Date()
    ) -> Int {
        let cutoff = now.addingTimeInterval(-interval)
        let outcome = try? LockedFile.withExclusiveLock(paths.messages) { () -> (removed: Int, alive: [AgentMessage]) in
            guard let contents = try? String(contentsOf: paths.messages, encoding: .utf8) else { return (0, []) }
            let decoder = JSONCoding.decoder()
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

            let decoded = lines.compactMap { line -> (line: Substring, message: AgentMessage)? in
                guard
                    let data = line.data(using: .utf8),
                    let message = try? decoder.decode(AgentMessage.self, from: data)
                else { return nil }
                return (line, message)
            }
            let resolved = Self.resolvedIDs(in: decoded.map(\.message))
            // A blocker nobody has lifted is still true, however old the log is
            // allowed to get. Pruning it would be the bus lying by omission,
            // which is the one thing it must not do.
            func isStandingBlocker(_ message: AgentMessage) -> Bool {
                message.isPriority && !resolved.contains(message.id) && !message.hasExpired(by: now)
            }

            // File order is append order, which is time order; no need to sort
            // to find the most recent.
            let survivors = decoded.filter { $0.message.at >= cutoff || isStandingBlocker($0.message) }
            var keep = Set(survivors.suffix(limit).map(\.message.id))
            keep.formUnion(survivors.filter { isStandingBlocker($0.message) }.map(\.message.id))
            // A session that has read recently but not everything must not
            // lose mail to the cap: anything newer than the least-read live
            // marker survives. Markers untouched for longer than the prune
            // window are dead sessions, not protection.
            if let floor = Self.leastReadMarker(paths: paths, within: interval, now: now) {
                keep.formUnion(decoded.filter { $0.message.at >= floor }.map(\.message.id))
            }
            // A tombstone lives exactly as long as what it buries: drop it while
            // the original is still in the file and the original comes back from
            // the dead. Taken over every line and not only over the survivors —
            // a resolve older than what it resolves is nonsense by the clock and
            // perfectly possible in a log written by several machines.
            let keptSoFar = keep
            keep.formUnion(
                decoded
                    .filter { $0.message.effectiveKind == .resolve && $0.message.refID.map(keptSoFar.contains) == true }
                    .map(\.message.id)
            )
            let kept = decoded.filter { keep.contains($0.message.id) }

            let removed = lines.count - kept.count
            guard removed > 0 else { return (0, decoded.map(\.message)) }

            let text = kept.map { String($0.line) }.joined(separator: "\n")
            try AtomicFile.write(Data(text.isEmpty ? Data() : Data((text + "\n").utf8)), to: paths.messages)
            return (removed, kept.map(\.message))
        }
        // Only when we know what survived. A failed lock leaves us with no idea
        // what is referenced, and collecting on that would delete the files the
        // notes we could not read are about.
        guard let outcome else { return 0 }
        ArtifactStore(paths: paths).collect(
            keeping: ArtifactStore.keys(referencedBy: outcome.alive),
            now: now
        )
        return outcome.removed
    }

    /// The oldest message any recently-reading session has consumed, or nil
    /// when nobody has read within the window. Old markers pin nothing: a
    /// session gone longer than the prune window is not coming back for its
    /// mail, and pinning on it would let one dead reader grow the log forever.
    static func leastReadMarker(paths: Paths, within interval: TimeInterval, now: Date) -> Date? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.delivered.path) else { return nil }
        var floors: [Date] = []
        for name in names {
            let url = paths.delivered.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            guard let modified, now.timeIntervalSince(modified) < interval,
                  let data = try? Data(contentsOf: url),
                  let marker = try? JSONCoding.decoder().decode(DeliveryMarker.self, from: data),
                  let floor = marker.lastMessageAt
            else { continue }
            floors.append(floor)
        }
        return floors.min()
    }

    /// Delivery markers outlive their sessions; sweep the old ones.
    public func prune(olderThan interval: TimeInterval = 7 * 24 * 3600) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.delivered.path) else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        for name in names {
            let url = paths.delivered.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}

public enum RelativeTime {
    public static func short(from date: Date, to now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }

    /// The same age with the "ago" left off, for the places where it sits in a
    /// parenthesis behind a name: "claimed by codex (40m)".
    public static func compact(from date: Date, to now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
