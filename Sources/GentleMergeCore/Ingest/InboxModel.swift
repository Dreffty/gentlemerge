import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Observation

// ADAPTED: keep the public model and review API in Core for headless ingestion.
// Observation ships with Swift on Linux; this is not a Combine/UI model.
/// The inbox itself: ingests spooled events, keeps exactly one live row per
/// session, answers parked hooks, and writes everything to the ledger.
@MainActor
@Observable
public final class InboxModel {
    public private(set) var items: [InboxItem] = []
    public var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            config.save(to: paths.config)
        }
    }


    public internal(set) var lastMessage: String?

    /// Finished reviews, newest first, and the one currently running.
    public internal(set) var reviews: [Review] = []
    public internal(set) var activeReview: Review?
    var reviewTask: Task<Void, Never>?

    /// What we know about live sessions, including the commit each started from.
    var sessions: SessionRegistry

    /// Every project an agent has worked in, newest first.
    public private(set) var projects: [ProjectSummary] = []
    var projectRegistry: ProjectRegistry

    /// What each agent session is doing right now, and the notes they leave
    /// each other. This is the part every session reads before its next turn.
    public private(set) var activities: [AgentActivity] = []
    /// What the bus has to say, with the resolved notes folded away. No clock is
    /// passed: your window is a history, and a message you read yesterday is not
    /// noise the way one injected into an agent's turn is.
    public private(set) var messages: [AgentMessage] = []
    let bus: AgentBus

    /// Called for every freshly ingested item that deserves a notification.
    public var onNotify: ((InboxItem) -> Void)?

    /// Observation tracks these approvals just like the inbox rows. Core stays
    /// independent of AppKit; the app supplies the notification callback.
    public private(set) var pendingApprovals: [String: (AgentRequest, AgentTarget, String)] = [:]
    public private(set) var approvedRequestIDs: Set<String> = []
    public private(set) var lastDispatched: [String: Date] = [:]
    public var onDispatchApproval: ((AgentRequest, AgentTarget, String) -> Void)?
    @ObservationIgnored var runDispatch: (AgentRequest, AgentTarget) throws -> Task<Void, Never>
    private var dispatchedRequestIDs: Set<String> = []
    private var approvalNotifiedIDs: Set<String> = []
    private var dispatchSkipReasons: [String: Set<String>] = [:]

    public let paths: Paths
    private let spool: SpoolStore
    private let ledger: Ledger
    private let terminal = TerminalBridge()

    #if os(macOS)
    private var watcher: DispatchSourceFileSystemObject?
    #endif
    private var timer: Timer?
    /// The app is the only process that runs long enough to be trusted with
    /// housekeeping; the hooks are gone in milliseconds.
    private var lastPruneAt: Date?

    /// When we last typed into each session, keyed by session id. In memory
    /// because the rate limit is about a person watching a terminal, and a
    /// restart of the app is a moment when nobody is being interrupted.
    private var nudgedAt: [String: Date] = [:]
    /// The notes we have already made a decision about. nil until the first
    /// pass, which only learns what is already on the bus: an app that has just
    /// launched must not walk into a day of backlog and start typing.
    private var nudgesConsidered: Set<String>?

    public init(paths: Paths = .fromEnvironment()) {
        self.paths = paths
        self.runDispatch = { request, target in try Dispatcher(paths: paths).run(request, target: target) }
        _ = try? paths.createDirectories()
        self.spool = SpoolStore(paths: paths)
        self.ledger = Ledger(url: paths.ledger)
        self.config = AppConfig.load(from: paths.config)
        self.sessions = SessionRegistry(url: paths.sessions)
        let registry = ProjectRegistry(url: paths.projects)
        self.projectRegistry = registry
        self.projects = registry.projects

        let bus = AgentBus(paths: paths)
        self.bus = bus
        self.activities = bus.activities()
        self.messages = bus.visibleMessages()
        Log.fileURL = paths.log
    }

    // MARK: - Lifecycle

    public func start() {
        spool.writeAppPID()
        loadState()
        loadReviews()
        drainNow()
        startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.drainNow()
                self?.pruneIfDue()
            }
        }
        spool.prune()
        pruneIfDue()
    }

    /// Sweep the bus: stale delivery markers, and messages nobody will ever be
    /// shown again. Cheap enough to sit on the 3 s tick, so it only asks the
    /// clock whether six hours have gone by.
    func pruneIfDue(now: Date = Date()) {
        if let lastPruneAt, now.timeIntervalSince(lastPruneAt) < 6 * 3600 { return }
        lastPruneAt = now
        bus.prune()
        bus.pruneMessages(now: now)
        // A rule nobody's event ever matched stops counting the moment somebody
        // reads it; this is only about the file not growing forever.
        try? Watches(paths: paths).compact(now: now)
        // The hot ledger stays bounded; totals survive because stats reads the
        // archive alongside it.
        Ledger(url: paths.ledger).archive(paths: paths, now: now)
    }

    public func stop() {
        #if os(macOS)
        watcher?.cancel()
        watcher = nil
        #endif
        timer?.invalidate()
        timer = nil
        saveState()
        spool.clearAppPID()
    }

    private func startWatching() {
        #if os(macOS)
        let descriptor = open(paths.spool.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.error("cannot watch spool at \(paths.spool.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.drainNow() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        #endif
        // Linux uses the existing three-second poll; drainNow also stays callable.
    }

    // MARK: - Ingest

    public func drainNow() {
        for envelope in spool.drain() {
            ingest(envelope)
        }
        // After the events, so a session that reported and then died in the same
        // three seconds is buried with its last words already recorded.
        sweepDeadSessions()
        // Delivery and dispatch depend on the session state this drain wrote.
        deliverNudges()
        refreshBus()
        sweepConflictRadar()
    }

    /// One hook event through the real pipeline. `allowReview` exists so the
    /// sim can drive the same ingestion without ever triggering the session-end
    /// review runner: `--home-real` must be safe to pass on purpose, and a
    /// simulated SessionEnd should not launch a git-diff review or touch user
    /// config. The default preserves every existing caller.
    public func ingest(_ envelope: SpoolEnvelope, allowReview: Bool = true) {
        updateActivity(from: envelope)

        if let project = envelope.workingDirectory {
            projectRegistry.seen(path: project, provider: envelope.provider, at: envelope.receivedAt)
            projects = projectRegistry.projects
        }

        if let sessionID = envelope.sessionID {
            sessions.seen(
                id: sessionID,
                provider: envelope.provider,
                projectPath: envelope.workingDirectory,
                at: envelope.receivedAt,
                pid: envelope.pid,
                tty: envelope.tty,
                terminalProgram: envelope.terminalProgram
            )
        }

        switch EventTranslator.translate(envelope) {
        case .ignore:
            ledger.append(
                LedgerEntry(
                    at: envelope.receivedAt,
                    kind: .received,
                    sessionID: envelope.sessionID,
                    provider: envelope.provider,
                    project: envelope.workingDirectory,
                    title: envelope.eventName
                )
            )

        case .sessionStarted(let sessionID, let projectPath, let date):
            sessions.started(
                id: sessionID,
                provider: envelope.provider,
                projectPath: projectPath,
                at: date,
                pid: envelope.pid,
                tty: envelope.tty,
                terminalProgram: envelope.terminalProgram
            )

        case .resolveSession(let sessionID, let status):
            let record = sessions[sessionID]
            resolve(sessionID: sessionID, status: status)

            if envelope.eventName == "SessionEnd" {
                sessions.ended(id: sessionID, at: envelope.receivedAt)
                if let project = record?.projectPath ?? envelope.workingDirectory {
                    noteUnfinishedWork(
                        in: project,
                        // Derived from the envelope, so draining the same
                        // SessionEnd twice updates one row instead of two.
                        eventID: envelope.id,
                        sessionID: envelope.sessionID,
                        provider: envelope.provider,
                        eventName: envelope.eventName,
                        tty: envelope.tty,
                        terminalProgram: envelope.terminalProgram,
                        pid: envelope.pid,
                        at: envelope.receivedAt
                    )
                    if allowReview && config.reviewOnSessionEnd {
                        startReview(projectPath: project, sessionID: sessionID)
                    }
                }
            }

        case .item(let item):
            insert(item)
        }

        // Last, so a rule about a task sees the handoff as this event left it.
        settleWatches(after: envelope)
        maybeAutoLand(after: envelope)
    }

    // MARK: - Watches

    /// Hand this event to whoever asked to be told about it.
    ///
    /// The events a watch can be about, picked out of the envelope. Same two
    /// shapes the activity switch knows: Codex says "turn-complete" where
    /// Claude Code says "Stop", and both mean the turn went back to you.
    private func settleWatches(after envelope: SpoolEnvelope, now: Date = Date()) {
        let event = envelope.eventName ?? ""
        let ended = event == "SessionEnd"
        let idle = event == "Stop" || event.contains("turn-complete") || event.contains("turn-ended")
        guard ended || idle else { return }

        settleWatches(
            sessionID: envelope.sessionID,
            label: AgentBus.label(for: envelope.provider),
            project: envelope.workingDirectory,
            ended: ended,
            now: now
        )
    }

    /// Fire every standing rule this moment just made true, and settle them.
    ///
    /// Here rather than in a daemon of its own: the app already sees every event
    /// on its way in and is the only process that outlives a turn. Delivery is
    /// an ordinary bus message, so it reaches the owner through the hook it
    /// already has, on its next turn — nothing waits, nothing is interrupted.
    ///
    /// A rule fires once and is spent: `settle` marks it inside the same lock
    /// that rewrites the file, so a second drain of the same event finds
    /// nothing left to fire.
    private func settleWatches(
        sessionID: String?,
        label: String?,
        project: String?,
        ended: Bool,
        now: Date
    ) {
        let watches = Watches(paths: paths)
        let standing = watches.pending(now: now)
        // The normal state of the world, and the reason this costs nothing on
        // every turn of every session: one read of a file that is usually not
        // even there. Nobody watching means nobody hears anything.
        guard !standing.isEmpty else { return }

        // A rule's project came through `canonicalPath`, while the event's is
        // whatever directory the agent's shell happened to be in — a
        // subdirectory of the repository, or the same place spelled through a
        // symlink (`/tmp` and `/private/tmp` are the one that bites). Resolved
        // here rather than on the way in, so the `git` process it can cost is
        // only paid while somebody is actually watching.
        let project = project.map(ProjectRegistry.canonicalPath(for:))

        var fired: [(rule: WatchRule, subject: String)] = []
        // Read at most once per event, and only if somebody is actually
        // watching a task in this project.
        var handoff: ProjectHandoff?

        for rule in standing where rule.covers(project: project) {
            switch rule.resolvedKind {
            case .sessionEnd? where ended, .sessionIdle? where !ended:
                guard rule.matchesSession(id: sessionID, label: label) else { continue }
                let who = label ?? sessionID.map { "session \($0.prefix(8))" } ?? rule.target
                fired.append((rule, ended ? "\(who) ended" : "\(who) finished a turn"))

            case .taskDone?:
                guard let project else { continue }
                if handoff == nil {
                    // Reading the file is the whole cost; refreshing the commit
                    // list would spawn git on every turn of every session.
                    handoff = ProjectRegistry.handoff(for: project, refreshingCommits: false)
                }
                guard let task = handoff?.tasks.first(where: { $0.id == rule.target }), task.done else { continue }
                fired.append((rule, "task done — \(task.text)"))

            // A kind this binary has no case for, and a session rule for the
            // other half of the pair. Neither is ours to fire, and `settle`
            // leaves both standing.
            default:
                continue
            }
        }
        guard !fired.isEmpty else { return }

        for (rule, subject) in fired {
            // `post` scrubs, which is what makes a note safe to carry: it was
            // typed by a human or written by an agent, and it is about to land
            // in somebody else's context.
            bus.post(
                AgentMessage(
                    from: "inbox",
                    to: rule.owner,
                    projectPath: rule.projectPath,
                    text: rule.notice(subject: subject),
                    kind: .update
                )
            )
        }
        try? watches.settle(firing: Set(fired.map(\.rule.id)), now: now)
        messages = bus.visibleMessages()
    }

    /// A session stopped with points it had written down still unticked.
    ///
    /// Takes the facts loose rather than an envelope, because half the sessions
    /// this is about never produced one: an agent killed by a 529 leaves no
    /// SessionEnd, and it is exactly the session whose open points nobody will
    /// otherwise hear about. `eventID` is what makes the row idempotent — the
    /// envelope's id for a clean end, `"<session>-died"` for a sweep — so
    /// draining twice updates one row instead of leaving two.
    ///
    /// This is the only thing that happens about it, and it happens here rather
    /// than in the hook: the session is already gone, and a hook that answered
    /// one back to keep it working is the failure mode this whole feature is
    /// supposed to prevent, not cause.
    private func noteUnfinishedWork(
        in projectPath: String,
        eventID: String,
        sessionID: String?,
        provider: AgentProvider,
        eventName: String?,
        tty: String?,
        terminalProgram: String?,
        pid: Int?,
        at date: Date
    ) {
        // Reading the file is the whole cost. Refreshing the commit list would
        // spawn git for a row nobody asked for.
        let handoff = ProjectRegistry.handoff(for: projectPath, refreshingCommits: false)
        guard let notice = UnfinishedWork.notice(for: handoff) else { return }

        insert(
            InboxItem(
                id: "\(eventID)-unfinished",
                sessionID: sessionID,
                provider: provider,
                kind: .info,
                eventName: eventName,
                title: notice.title,
                summary: notice.summary,
                detail: notice.detail,
                projectPath: handoff.projectPath,
                tty: tty,
                terminalProgram: terminalProgram,
                pid: pid,
                createdAt: date,
                updatedAt: date
            )
        )
    }

    /// Bury the sessions whose process is gone.
    ///
    /// A session that dies badly — 529, session limit, `kill -9` — never sends
    /// a SessionEnd, so the last thing it said about itself was "working", and
    /// every other agent was told so for the next six hours. Observed, not
    /// theoretical. The probe is a `kill(pid, 0)`: cheap enough to run on every
    /// drain, and the only question whose answer is not a guess.
    ///
    /// Only the app does this. It is the single writer of the activity file and
    /// the only process that lives long enough to notice, which is why the
    /// readers get their own defence in `others` instead of a share of this.
    func sweepDeadSessions(now: Date = Date()) {
        var list = bus.activities()
        var buried: [AgentActivity] = []

        for index in list.indices where list[index].state != .ended {
            guard Liveness.isProcessAlive(list[index].pid) == false else { continue }
            list[index] = list[index].buried()
            buried.append(list[index])
        }
        guard !buried.isEmpty else { return }

        bus.save(list)
        activities = list

        for activity in buried {
            let record = sessions[activity.id]
            sessions.ended(id: activity.id, at: now)
            let project = record?.projectPath ?? activity.projectPath

            // Whoever was waiting for this session to finish gets told it
            // finished. From where they are standing a death and a clean
            // ending are the same news — and the death is the case they were
            // worried about. Before the guard below, because a session with no
            // project is still a session somebody was waiting on.
            settleWatches(
                sessionID: activity.id,
                label: AgentBus.label(for: activity.provider),
                project: project,
                ended: true,
                now: now
            )

            guard let project else { continue }
            // The same row a clean ending would have left. A death is not a
            // reason for the score to go missing — it is the reason it matters.
            noteUnfinishedWork(
                in: project,
                eventID: "\(activity.id)-died",
                sessionID: activity.id,
                provider: activity.provider,
                eventName: AgentActivity.diedEvent,
                tty: activity.tty ?? record?.tty,
                terminalProgram: activity.terminalProgram ?? record?.terminalProgram,
                pid: activity.pid,
                at: now
            )
        }
    }

    private func insert(_ incoming: InboxItem) {
        var item = incoming

        // The newest state of a session is the only one worth showing.
        if let sessionID = item.sessionID {
            for index in items.indices
            where items[index].sessionID == sessionID
                && items[index].isPending
                && items[index].id != item.id {
                items[index].status = .superseded
                items[index].updatedAt = item.createdAt
            }
        }

        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }

        ledger.record(item, kind: .received)
        trimHistory()
        saveState()

        if config.shouldNotify(for: item.kind) {
            onNotify?(item)
        }
    }

    private func resolve(sessionID: String, status: InboxStatus) {
        var changed = false
        for index in items.indices where items[index].sessionID == sessionID && items[index].isPending {
            items[index].status = status
            items[index].updatedAt = Date()
            ledger.record(items[index], kind: .resolved)
            changed = true
        }
        if changed {
            trimHistory()
            saveState()
        }
    }

    // MARK: - Clearing rows

    /// Nothing here is a decision an agent is waiting on — it is a note you have
    /// read. Clearing it only affects what you see.
    public func markHandled(_ item: InboxItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), items[index].isPending else { return }
        items[index].status = .handled
        items[index].updatedAt = Date()
        ledger.record(items[index], kind: .handled)
        trimHistory()
        saveState()
    }

    public func markAllHandled() {
        for item in pending { markHandled(item) }
    }

    public func clearHistory() {
        items.removeAll { !$0.isPending }
        saveState()
    }

    // MARK: - The bus between agents

    /// Every event says something about what that session is doing. This is the
    /// picture the other agents get to read before their next turn.
    private func updateActivity(from envelope: SpoolEnvelope) {
        recordImplicitPathClaims(from: envelope)
        guard let sessionID = envelope.sessionID else { return }

        var list = bus.activities()
        var activity = list.first { $0.id == sessionID }
            ?? AgentActivity(
                id: sessionID,
                provider: envelope.provider,
                projectPath: envelope.workingDirectory,
                startedAt: envelope.receivedAt
            )

        activity.provider = envelope.provider
        activity.projectPath = envelope.workingDirectory.map(ProjectRegistry.canonicalPath(for:)) ?? activity.projectPath
        activity.updatedAt = envelope.receivedAt
        // Where the session runs. The pid is the whole point: without it the
        // only thing anyone can say about a session that stopped reporting is
        // that it stopped reporting.
        activity.pid = envelope.pid ?? activity.pid
        activity.tty = envelope.tty ?? activity.tty
        activity.terminalProgram = envelope.terminalProgram ?? activity.terminalProgram
        // Kept once known, never cleared by an older hook: a socket path is a
        // fact about the session, and an envelope without one only proves its
        // hook predates the field.
        if let socket = envelope.socket { activity.socketPath = socket }

        switch envelope.eventName ?? "" {
        case "UserPromptSubmit":
            // What you just asked for is the truest description of what this
            // session is about to do — and it was written for one agent, not
            // three. Scrub before truncating: half a key is still a leak.
            activity.currentTask = config.shareTaskText
                ? Redactor.shared(envelope.payload.string("prompt")?.firstLine)?.truncated(to: 140)
                : nil
            activity.lastEvent = nil
            activity.state = .working

        case "Notification":
            activity.state = .waiting
            activity.lastEvent = Redactor.shared(envelope.payload.string("message"))

        case "Stop":
            activity.state = .idle
            activity.lastEvent = "finished a turn"

        case "SessionStart":
            activity.state = .working
            activity.startedAt = envelope.receivedAt

        case "SessionEnd":
            activity.state = .ended

        case let event where event.contains("turn-complete") || event.contains("turn-ended"):
            activity.state = .idle
            activity.lastEvent = Redactor.shared(
                envelope.payload.string("last-assistant-message")?.firstLine
            )?.truncated(to: 140) ?? "finished a turn"

        default:
            break
        }

        list.removeAll { $0.id == sessionID }
        list.append(activity)
        list.sort { $0.updatedAt > $1.updatedAt }
        if list.count > 40 { list = Array(list.prefix(40)) }

        bus.save(list)
        activities = list
    }

    public var liveActivities: [AgentActivity] {
        activities.filter(\.isLive).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Implicit path claims: the moment an agent edits a file, everyone else
    /// can know. Costs the agent zero tokens; the app does it while draining.
    ///
    /// Never throws and never blocks the ingest: a claim that fails to be
    /// recorded is a briefing that says less, not an agent that stops.
    private func recordImplicitPathClaims(from envelope: SpoolEnvelope) {
        let tool = envelope.payload.string("tool_name")
            ?? envelope.eventName.flatMap { name in
                // PostToolUse payloads name the tool in `tool_name`; the event
                // name alone is not enough to know an edit happened.
                ["PostToolUse"].contains(name) ? envelope.payload.string("tool_name") : nil
            }
        guard let tool, ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool),
              let filePath = envelope.payload["tool_input"]?.string("file_path")
                  ?? envelope.payload["tool_input"]?.string("notebook_path"),
              let cwd = envelope.workingDirectory
        else { return }

        let project = ProjectRegistry.canonicalPath(for: cwd)
        // The shared claim store uses the canonical repository, but paths are
        // relative to the checkout that produced the event, not the main tree.
        let checkout = (GitSnapshot(anyPathInside: cwd)?.repository ?? URL(fileURLWithPath: cwd))
            .resolvingSymlinksInPath().standardizedFileURL
        let file = (filePath.hasPrefix("/") ? URL(fileURLWithPath: filePath)
            : URL(fileURLWithPath: cwd).appendingPathComponent(filePath))
            .resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(checkout.path + "/") else { return }
        let rel = String(file.path.dropFirst(checkout.path.count + 1))
        guard !rel.isEmpty else { return }

        // A payload label is advisory attribution, not verified caller identity.
        let label = envelope.payload.string("label").map(Identity.safe)?.nonEmpty
            ?? AgentBus.label(for: envelope.provider)
        PathClaims(paths: paths).touch(file: rel, label: label, project: project)
    }

    /// Leave a note for the other agents. They pick it up on their next turn.
    public func say(_ text: String, to recipient: String? = nil, project: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = bus.post(
            AgentMessage(from: "you", to: recipient, projectPath: project, text: trimmed)
        )
        messages = bus.visibleMessages()

        if result.isSuppressed {
            lastMessage = "Withheld: that was almost entirely \(result.summary)."
        } else if result.didRedact {
            lastMessage = "Sent to \(recipient ?? "every agent"), with \(result.summary) taken out."
        } else {
            lastMessage = "Sent to \(recipient ?? "every agent")."
        }
    }

    public func refreshBus() {
        activities = bus.activities()
        messages = bus.visibleMessages()
        refreshDispatch()
    }

    // MARK: - Conflict radar and automatic landing

    /// One sweep per known project. The three-minute throttle inside keeps this
    /// to a small JSON read on most drains; git only runs when a sweep is due.
    private func sweepConflictRadar() {
        for summary in projects {
            _ = ConflictRadar.sweep(project: summary.path, paths: paths)
        }
    }

    /// With `autoLand` on, a Stop whose branch is ahead of main and clean of
    /// conflicts lands itself. Off the main actor on a serial queue: a landing
    /// rebases and runs checks, which takes seconds to minutes, and the drain
    /// must never wait for it. Serial, so two Stops never land at once; the
    /// ledger and the bus are lock-guarded files, safe from any thread.
    private func maybeAutoLand(after envelope: SpoolEnvelope) {
        guard config.autoLand else { return }
        let event = envelope.eventName ?? ""
        guard event == "Stop" || event.contains("turn-complete") || event.contains("turn-ended") else { return }
        guard let cwd = envelope.workingDirectory else { return }
        let (paths, provider) = (self.paths, envelope.provider)
        AutoLandQueue.queue.async {
            _ = Landing.autoLand(cwd: cwd, provider: provider, paths: paths)
        }
    }

    // MARK: - Headless dispatch

    private var approvalsURL: URL { paths.home.appendingPathComponent("dispatch-approvals.json") }

    /// Shared with `dispatch approve`: never replace a CLI approval using a
    /// stale in-memory set. Every read/modify/write holds the same sidecar lock.
    private func updateApprovals(_ change: (inout Set<String>) -> Void) throws {
        try LockedFile.withExclusiveLock(approvalsURL) {
            let data: Data?
            do { data = try Data(contentsOf: approvalsURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                data = nil
            }
            var ids = Set(try data.map { try JSONCoding.decoder().decode([String].self, from: $0) } ?? [])
            let before = ids
            change(&ids)
            if ids != before {
                try AtomicFile.write(try JSONCoding.encoder().encode(ids.sorted()), to: approvalsURL)
            }
            approvedRequestIDs = ids
        }
    }

    public func approve(_ id: String) {
        guard let request = Requests(paths: paths).load(id), request.state == .assigned else {
            lastMessage = "That request is no longer assigned."
            return
        }
        do {
            try updateApprovals { $0.insert(id) }
            pendingApprovals.removeValue(forKey: id)
            lastMessage = "Approved \(id); the next drain will check the dispatch gate."
        } catch { lastMessage = "Could not save approval: \(error)" }
    }

    public func deny(_ id: String) {
        do {
            _ = try Requests(paths: paths).transition(id, to: .rejected, by: "you", result: "denied by human")
            pendingApprovals.removeValue(forKey: id)
            try updateApprovals { $0.remove(id) }
            lastMessage = "Denied \(id)."
        } catch { lastMessage = "Could not deny \(id): \(error)" }
    }

    public func requestLogURL(for request: AgentRequest) -> URL? {
        guard Requests.validID(request.id) else { return nil }
        let url = paths.dispatch.appendingPathComponent("\(request.id).log")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }

    private func refreshDispatch(now: Date = Date()) {
        let assigned = Requests(paths: paths).all().filter { $0.state == .assigned }
        let ids = Set(assigned.map(\.id))
        pendingApprovals = pendingApprovals.filter { ids.contains($0.key) }
        approvalNotifiedIDs.formIntersection(ids)
        dispatchSkipReasons = dispatchSkipReasons.filter { ids.contains($0.key) }
        do {
            try updateApprovals { $0.formIntersection(ids); $0.subtract(dispatchedRequestIDs) }
        } catch {
            // A broken approval store must never turn into automatic consent.
            approvedRequestIDs = []
            lastMessage = "Could not read dispatch approvals: \(error)"
            return
        }
        let live = Set(liveActivities.map { AgentBus.label(for: $0.provider) })
            .union(Presence.marks(paths: paths).filter { !$0.isExpired }.map(\.label))
        for request in assigned {
            guard !dispatchedRequestIDs.contains(request.id) else { continue }
            switch DispatchGate.decide(request: request, config: config, liveLabels: live,
                lastDispatched: lastDispatched, approved: approvedRequestIDs.contains(request.id),
                spentTodayMinutes: Dispatcher.spentTodayMinutes(paths: paths, now: now), now: now) {
            case .dispatch(let target):
                // Mark before starting: a slow child may stay assigned past the
                // quiet period. Neither another tick nor a start failure retries it.
                dispatchedRequestIDs.insert(request.id)
                lastDispatched[target.label] = now
                pendingApprovals.removeValue(forKey: request.id)
                do {
                    _ = try runDispatch(request, target)
                } catch {
                    ledger.append(LedgerEntry(kind: .note, itemID: request.id,
                        title: "dispatch.failed", reason: "\(error)"))
                    lastMessage = "Could not dispatch \(request.id): \(error)"
                }
                do { try updateApprovals { $0.remove(request.id) } }
                catch { lastMessage = "Could not consume dispatch approval: \(error)" }
            case .needsApproval(let target, let reason):
                pendingApprovals[request.id] = (request, target, reason)
                if approvalNotifiedIDs.insert(request.id).inserted {
                    onDispatchApproval?(request, target, reason)
                }
            case .skip(let reason):
                pendingApprovals.removeValue(forKey: request.id)
                if dispatchSkipReasons[request.id, default: []].insert(reason).inserted {
                    ledger.append(LedgerEntry(kind: .note, itemID: request.id,
                        project: request.projectPath, title: "dispatch.skipped", reason: reason))
                }
            }
        }
    }

    // MARK: - Projects

    /// The shared state for a project: commits refreshed from git, plus whatever
    /// you and the agents have written into its handoff file.
    public func handoff(for projectPath: String) -> ProjectHandoff {
        ProjectRegistry.handoff(for: projectPath)
    }

    public func addTask(_ text: String, to projectPath: String, by author: String = "you") {
        _ = ProjectRegistry.addTask(text, to: projectPath, by: author)
        lastMessage = "Added to \(URL(fileURLWithPath: projectPath).lastPathComponent)."
    }

    /// Who is on which task here, the lapsed claims already gone.
    ///
    /// A read, and only a read: you are not one of the agents competing for the
    /// work, so the window shows claims and never takes one.
    public func claims(for projectPath: String) -> [String: TaskClaim] {
        TaskClaims(paths: paths).active(for: projectPath)
    }

    public func setTask(_ task: TaskItem, done: Bool, in projectPath: String) {
        _ = ProjectRegistry.setTask(task.id, done: done, in: projectPath)
        // Same rule as the CLI: ticking it off ends whatever claim was on it,
        // so nobody is left waiting for a task that no longer exists.
        if done { _ = try? TaskClaims(paths: paths).releaseAll(task.id, in: projectPath) }
    }

    public func removeTask(_ task: TaskItem, in projectPath: String) {
        _ = ProjectRegistry.removeTask(task.id, in: projectPath)
    }

    public func setNotes(_ notes: String, in projectPath: String) {
        var handoff = ProjectRegistry.handoff(for: projectPath)
        handoff.notes = notes
        _ = ProjectRegistry.save(handoff)
    }

    /// Writes the handoff file and points the project's CLAUDE.md / AGENTS.md at
    /// it, so agents find it even without our session hook.
    public func initializeProject(_ projectPath: String) {
        do {
            _ = try ProjectRegistry.initialize(projectPath: projectPath)
            projectRegistry.seen(path: projectPath, provider: nil, at: Date())
            projects = projectRegistry.projects
            lastMessage = "Handoff file ready in \(URL(fileURLWithPath: projectPath).lastPathComponent)."
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    public func forgetProject(_ projectPath: String) {
        projectRegistry.forget(path: projectPath)
        projects = projectRegistry.projects
    }

    // MARK: - Restore points

    public func snapshots(forProjectAt path: String?) -> [SnapshotRef] {
        GitSnapshot(anyPathInside: path)?.list() ?? []
    }

    public func snapshot(_ reference: String, forProjectAt path: String?) -> SnapshotRef? {
        snapshots(forProjectAt: path).first { $0.id == reference }
    }

    @discardableResult
    public func createSnapshot(forProjectAt path: String?, label: String) -> SnapshotRef? {
        guard let snapshot = GitSnapshot(anyPathInside: path) else {
            lastMessage = "That project is not a git repository, so there is nothing to snapshot."
            return nil
        }
        do {
            let reference = try snapshot.create(label: label)
            lastMessage = "Restore point taken (\(reference.dirtyFiles) changed files)."
            return reference
        } catch {
            lastMessage = error.localizedDescription
            return nil
        }
    }

    /// Writes the snapshot's files back over the current ones. Never deletes,
    /// and snapshots the state you are leaving first.
    @discardableResult
    public func restore(_ reference: SnapshotRef) -> RestoreReport? {
        guard let snapshot = GitSnapshot(anyPathInside: reference.repository) else {
            lastMessage = "That repository is gone."
            return nil
        }
        do {
            let report = try snapshot.restore(reference)
            ledger.append(
                LedgerEntry(
                    kind: .note,
                    project: reference.repository,
                    title: "Restored “\(reference.label)”",
                    summary: report.summary,
                    reason: "undo with snapshot \(report.safety.id)"
                )
            )
            lastMessage = "Restored “\(reference.label)”: \(report.summary)."
            return report
        } catch {
            lastMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Nudges

    /// Hand the notes that asked for it to `NudgeGate`, and type into whatever
    /// it lets us type into.
    ///
    /// Here and nowhere else. The CLI that posted the note is a hook: it holds
    /// no Automation permission, and it sees the activity file as it was, not as
    /// it is. The app has both, and it is already looking at every event.
    ///
    /// The bus is read directly rather than through `messages`, because the note
    /// that asks for a nudge is appended by another process and the window may
    /// not have refreshed since.
    func deliverNudges(now: Date = Date()) {
        let fresh = bus.visibleMessages(expiringAt: now).filter { $0.nudge == true }

        guard var considered = nudgesConsidered else {
            nudgesConsidered = Set(fresh.map(\.id))
            return
        }
        defer { nudgesConsidered = considered }

        // The set only ever holds ids that carried the flag — a handful a day —
        // but it outlives the log, so it is folded back onto what is still there
        // rather than allowed to grow for as long as the app is up.
        if considered.count > 400 {
            considered.formIntersection(Set(bus.messages(limit: 500).map(\.id)))
        }

        for message in fresh where !considered.contains(message.id) {
            // Decided once, whatever we decide: a note that was ignored because
            // its addressee was mid-turn is not retried thirty times over the
            // next ninety seconds. The message is already on its way through the
            // briefing, which is the channel that always works.
            considered.insert(message.id)

            guard config.allowNudges else {
                // Not silence, a record: the flag was set, nothing happened, and
                // the reason is one line away in the ledger.
                recordNudge(message, activity: nil, reason: "nudges are off")
                continue
            }

            let candidates = activities.compactMap { activity -> (AgentActivity, NudgeGate.Decision)? in
                let decision = NudgeGate.decide(
                    message: message,
                    activity: activity,
                    config: config,
                    lastNudgedAt: nudgedAt[activity.id],
                    now: now
                )
                guard decision == .nudge || decision.isSocket else { return nil }
                return (activity, decision)
            }
            guard !candidates.isEmpty else {
                recordNudge(message, activity: nil, reason: whyNobodyWasNudged(message, now: now))
                continue
            }

            for (activity, decision) in candidates {
                // Marked before the push, not after: osascript takes a moment,
                // and a failure is no reason to try the same terminal again on
                // the next tick.
                nudgedAt[activity.id] = now
                switch decision {
                case .nudgeSocket(let path):
                    deliverViaSocket(message, to: activity, path: path)
                case .nudge:
                    let outcome = terminal.send(
                        text: NudgeGate.text(from: message.from),
                        tty: activity.tty,
                        terminalProgram: activity.terminalProgram
                    )
                    recordNudge(message, activity: activity, reason: Self.describe(outcome))
                case .skipped:
                    break
                }
            }
        }
    }

    /// One fixed line over the session's own socket. When the send throws —
    /// today it always does, until the wire format is verified against the
    /// vendor's docs — back to the tty on macOS while the session is idle,
    /// and nowhere else. Every outcome is ledgered.
    private func deliverViaSocket(_ message: AgentMessage, to activity: AgentActivity, path: String) {
        do {
            try SocketBridge.send(notice: NudgeGate.text(from: message.from), to: path)
            recordNudge(message, activity: activity, reason: "socket")
        } catch {
            let cause = SocketBridge.shortError(error)
            guard NudgeGate.fallsBackToTTY(activity: activity) else {
                #if os(macOS)
                recordNudge(
                    message, activity: activity,
                    reason: "socket unavailable (\(cause)); recipient is \(activity.stateLabel), keeping the briefing"
                )
                #else
                recordNudge(message, activity: activity, reason: "socket unavailable (\(cause))")
                #endif
                return
            }
            let outcome = terminal.send(
                text: NudgeGate.text(from: message.from),
                tty: activity.tty,
                terminalProgram: activity.terminalProgram
            )
            recordNudge(
                message, activity: activity,
                reason: "nudge.socket.fallback_tty (\(cause)); \(Self.describe(outcome))"
            )
        }
    }

    /// The first reason the gate gave, for the ledger. Only asked when nobody
    /// was nudged, so it costs nothing in the normal case.
    private func whyNobodyWasNudged(_ message: AgentMessage, now: Date) -> String {
        let reasons = activities.compactMap { activity in
            NudgeGate.decide(
                message: message,
                activity: activity,
                config: config,
                lastNudgedAt: nudgedAt[activity.id],
                now: now
            ).reason
        }
        // "not for this session" is what every unrelated agent says, so it is
        // only the answer when it is the only one.
        return reasons.first { $0 != "not for this session" } ?? "no session to nudge"
    }

    private static func describe(_ outcome: TerminalBridge.Outcome) -> String {
        switch outcome {
        case .sent: return "typed"
        case .notFound: return "terminal is gone"
        case .failed(let message), .unsupported(let message): return message
        case .focused, .appActivatedOnly: return "could not type into that terminal"
        }
    }

    /// The ledger and not the window. Nudges are between the agents; a line in
    /// the record is what makes them auditable without making them noise.
    private func recordNudge(_ message: AgentMessage, activity: AgentActivity?, reason: String) {
        ledger.append(
            LedgerEntry(
                at: Date(),
                kind: .note,
                sessionID: activity?.id,
                provider: activity?.provider ?? .unknown,
                project: message.projectPath,
                title: "nudge \(message.from) → \(message.to ?? "everyone")",
                summary: activity.map { "\($0.provider.displayName) · \($0.projectName) · \($0.stateLabel)" },
                reason: reason
            )
        )
    }

    // MARK: - Terminal actions

    @discardableResult
    public func jumpToTerminal(_ item: InboxItem) -> TerminalBridge.Outcome {
        let outcome = terminal.focus(tty: item.tty, terminalProgram: item.terminalProgram)
        switch outcome {
        case .focused: lastMessage = nil
        case .appActivatedOnly:
            lastMessage = "Brought \(item.terminalProgram ?? "the terminal") forward — find the tab for \(item.projectName)."
        case .notFound: lastMessage = "That session's terminal is gone."
        case .failed(let message), .unsupported(let message): lastMessage = message
        case .sent: break
        }
        return outcome
    }

    @discardableResult
    public func reply(to item: InboxItem, text: String) -> TerminalBridge.Outcome {
        let outcome = terminal.send(text: text, tty: item.tty, terminalProgram: item.terminalProgram)
        switch outcome {
        case .sent:
            markHandled(item)
            lastMessage = "Sent to \(item.projectName)."
        case .failed(let message), .unsupported(let message):
            lastMessage = message
        case .notFound:
            lastMessage = "That session's terminal is gone."
        case .focused, .appActivatedOnly:
            lastMessage = "Could not type into that session."
        }
        return outcome
    }

    // MARK: - Views over the data

    public var pending: [InboxItem] {
        items.filter(\.isPending).sorted(by: InboxItem.ordered)
    }

    public var history: [InboxItem] {
        items.filter { !$0.isPending }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var pendingCount: Int { items.filter(\.isPending).count }

    public func ledgerEntries(limit: Int = 200) -> [LedgerEntry] {
        ledger.recent(limit: limit)
    }

    // MARK: - Persistence

    private func trimHistory() {
        let resolved = items.filter { !$0.isPending }.sorted { $0.updatedAt > $1.updatedAt }
        guard resolved.count > config.historyLimit else { return }
        let doomed = Set(resolved.dropFirst(config.historyLimit).map(\.id))
        items.removeAll { doomed.contains($0.id) }
    }

    private func loadState() {
        guard
            let data = try? Data(contentsOf: paths.state),
            let stored = try? JSONCoding.decoder().decode([InboxItem].self, from: data)
        else { return }
        items = stored
    }

    private func saveState() {
        do {
            try AtomicFile.write(try JSONCoding.encoder().encode(items), to: paths.state)
        } catch {
            Log.error("could not save state: \(error.localizedDescription)")
        }
    }
}

/// One landing at a time, off the main actor. See `maybeAutoLand`.
private enum AutoLandQueue {
    static let queue = DispatchQueue(label: "gentlemerge.autoland")
}
