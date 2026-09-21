import XCTest
@testable import GentleMergeCore

/// "Avísame cuando Codex termine" used to mean polling the briefing. These are
/// the properties that make asking once enough — and the ones that keep a watch
/// from becoming another source of noise.
@MainActor
final class WatchTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var paths: Paths!
    private var model: InboxModel!
    private var watches: Watches!

    override func setUp() async throws {
        try await MainActor.run { try prepare() }
    }

    private func prepare() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-watch-\(UUID().uuidString)")
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-watched-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        paths = Paths(home: root)
        try paths.createDirectories()
        model = InboxModel(paths: paths)
        watches = Watches(paths: paths)
    }

    override func tearDown() async throws {
        await MainActor.run { cleanUp() }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: project)
    }

    /// The project as everything that files a rule sees it: `watch` and `task`
    /// both go through `canonicalPath`, while the events arrive spelled the way
    /// the agent's shell had it. The two have to meet.
    private var here: String { ProjectRegistry.canonicalPath(for: project.path) }
    private var asTheShellSawIt: String { project.path }

    private func envelope(
        id: String = UUID().uuidString,
        session: String = "codex-1",
        event: String = "Stop",
        provider: AgentProvider = .codex,
        project: String? = nil,
        pid: Int? = nil
    ) -> SpoolEnvelope {
        SpoolEnvelope(
            id: id,
            provider: provider,
            cwd: project ?? asTheShellSawIt,
            tty: "/dev/ttys004",
            pid: pid,
            payload: .object([
                "session_id": .string(session),
                "hook_event_name": .string(event),
            ])
        )
    }

    /// What the owner would actually be handed, and nothing else.
    private func noticesForClaude() -> [AgentMessage] {
        model.bus.messages().filter { $0.from == "inbox" && $0.to == "claude" }
    }

    /// A pid with nothing behind it any more. Launched for real: a number picked
    /// out of the air could be somebody else's live process.
    private func pidOfAProcessThatIsGone() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = Int(process.processIdentifier)
        process.waitUntilExit()
        return pid
    }

    // MARK: - A session ending

    func testASessionEndingTellsWhoeverAskedToBeTold() async throws {
        try watches.add(
            WatchRule(owner: "claude", projectPath: here, kind: .sessionEnd, target: "codex", note: "then I merge")
        )

        model.ingest(envelope(event: "SessionEnd"))

        let notices = noticesForClaude()
        XCTAssertEqual(notices.count, 1, "exactly one: a watch that fires twice is worse than one that never fires")
        XCTAssertTrue(try XCTUnwrap(notices.first).text.contains("codex ended"))
        XCTAssertTrue(try XCTUnwrap(notices.first).text.contains("then I merge"), "the note is why you asked")
        XCTAssertEqual(notices.first?.projectPath, here, "scoped like everything else on this bus")

        let rule = try XCTUnwrap(watches.all().first)
        XCTAssertNotNil(rule.firedAt, "and the rule is spent")
        XCTAssertTrue(watches.pending().isEmpty)
    }

    func testASpentRuleNeverFiresAgain() async throws {
        try watches.add(WatchRule(owner: "claude", projectPath: here, kind: .sessionEnd, target: "codex"))

        model.ingest(envelope(id: "end", event: "SessionEnd"))
        model.drainNow()
        model.ingest(envelope(id: "end-again", session: "codex-2", event: "SessionEnd"))

        XCTAssertEqual(noticesForClaude().count, 1)
    }

    func testTheOwnerIsHandedItOnItsNextTurn() async throws {
        try watches.add(WatchRule(owner: "claude", projectPath: here, kind: .sessionEnd, target: "codex"))

        model.ingest(envelope(event: "SessionEnd"))

        // The whole delivery mechanism is the bus it already reads: no daemon,
        // no second channel, and it arrives through the hook it already has.
        let briefing = try XCTUnwrap(
            model.bus.briefing(sessionID: "claude-1", me: "claude", project: here)
        )
        XCTAssertTrue(briefing.contains("watch: codex ended"), briefing)
    }

    func testASessionThatDiedCountsAsOneThatEnded() async throws {
        try watches.add(WatchRule(owner: "claude", projectPath: here, kind: .sessionEnd, target: "codex"))
        // Reported once and then killed: no SessionEnd will ever arrive, and
        // this is precisely the case somebody waiting was worried about.
        model.ingest(envelope(event: "UserPromptSubmit", pid: try pidOfAProcessThatIsGone()))
        XCTAssertTrue(noticesForClaude().isEmpty, "still working, as far as anyone knew")

        model.drainNow()

        let notices = noticesForClaude()
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(try XCTUnwrap(notices.first).text.contains("codex ended"))
    }

    // MARK: - A session handing the turn back

    func testAnIdleWatchFiresWhenTheAgentFinishesItsTurn() async throws {
        try watches.add(WatchRule(owner: "claude", projectPath: here, kind: .sessionIdle, target: "codex"))

        model.ingest(envelope(event: "Stop"))

        XCTAssertEqual(noticesForClaude().count, 1)
        XCTAssertTrue(try XCTUnwrap(noticesForClaude().first).text.contains("finished a turn"))
    }

    func testAnEndWatchIgnoresATurnAndAnIdleWatchIgnoresAnEnding() async throws {
        try watches.add(WatchRule(owner: "claude", projectPath: here, kind: .sessionEnd, target: "codex"))
        try watches.add(WatchRule(owner: "claude", projectPath: here, kind: .sessionIdle, target: "codex"))

        model.ingest(envelope(id: "turn", event: "Stop"))

        XCTAssertEqual(noticesForClaude().count, 1, "only the idle one")
        XCTAssertEqual(watches.pending().count, 1, "and the other is still standing")
        XCTAssertEqual(watches.pending().first?.resolvedKind, .sessionEnd)
    }

    func testWatchingOneSubagentDoesNotCatchTheOthers() async throws {
        try watches.add(
            WatchRule(owner: "you", projectPath: here, kind: .sessionIdle, target: "claude#exec2")
        )

        model.ingest(envelope(session: "claude-1", event: "Stop", provider: .claudeCode))

        XCTAssertTrue(model.bus.messages().filter { $0.from == "inbox" }.isEmpty)
    }

    func testASessionCanBeNamedByTheIdYouReadInWho() async throws {
        try watches.add(
            WatchRule(owner: "claude", projectPath: here, kind: .sessionEnd, target: "9f3c1")
        )

        model.ingest(envelope(session: "9f3c1a77-dead-beef", event: "SessionEnd"))

        XCTAssertEqual(noticesForClaude().count, 1)
    }

    // MARK: - A task getting ticked off

    /// One open task, filed the way another agent would file it.
    private func openTask() throws -> TaskItem {
        let filed = ProjectRegistry.addTask("traducir constants a EN", to: here, by: "you")
        return try XCTUnwrap(filed.tasks.first)
    }

    func testATaskClosedByAnotherAgentReachesWhoeverWasWaiting() async throws {
        let task = try openTask()
        try watches.add(
            WatchRule(owner: "claude", projectPath: here, kind: .taskDone, target: task.id, note: "then I review it")
        )

        // Nothing yet: the task is still open, and a turn ending is not news.
        model.ingest(envelope(id: "turn", event: "Stop"))
        XCTAssertTrue(noticesForClaude().isEmpty)

        // Somebody else ticks it off — the CLI writes exactly this.
        _ = ProjectRegistry.setTask(task.id, done: true, in: here)
        model.ingest(envelope(id: "turn-2", event: "Stop"))

        let notices = noticesForClaude()
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(try XCTUnwrap(notices.first).text.contains("traducir constants a EN"))
        XCTAssertTrue(try XCTUnwrap(notices.first).text.contains("then I review it"))
    }

    func testATaskWatchIsAboutItsOwnProject() async throws {
        let task = try openTask()
        try watches.add(WatchRule(owner: "claude", projectPath: here, kind: .taskDone, target: task.id))
        _ = ProjectRegistry.setTask(task.id, done: true, in: here)

        model.ingest(envelope(id: "elsewhere", event: "Stop", project: root.appendingPathComponent("otro").path))

        XCTAssertTrue(noticesForClaude().isEmpty, "an event in another project is not news here")
        XCTAssertEqual(watches.pending().count, 1)
    }

    // MARK: - Silence, and not growing forever

    func testARuleNobodyMatchedLapsesInsteadOfWaitingForever() async throws {
        try watches.add(
            WatchRule(
                createdAt: Date().addingTimeInterval(-49 * 3600),
                owner: "claude",
                projectPath: here,
                kind: .sessionEnd,
                target: "codex"
            )
        )
        XCTAssertTrue(watches.pending().isEmpty, "two days old, and nobody is still waiting on it")

        model.ingest(envelope(event: "SessionEnd"))

        XCTAssertTrue(noticesForClaude().isEmpty)
        // And the file does not keep it: the app is the one that sweeps.
        try watches.compact()
        XCTAssertTrue(watches.all().isEmpty)
    }

    func testNobodyWatchingMeansNothingIsSaid() async throws {
        model.ingest(envelope(event: "SessionEnd"))
        model.drainNow()

        XCTAssertTrue(model.bus.messages().isEmpty, "silence is the default here as everywhere")
    }

    func testAKindThisBinaryHasNeverHeardOfIsLeftAlone() async throws {
        try watches.add(
            WatchRule(owner: "claude", projectPath: here, rawKind: "session-crashed", target: "codex")
        )

        model.ingest(envelope(event: "SessionEnd"))

        XCTAssertTrue(noticesForClaude().isEmpty, "not ours to fire")
        XCTAssertEqual(watches.pending().count, 1, "and not ours to throw away either")
    }

    // MARK: - Nothing crosses unscrubbed

    func testAKeyInTheNoteNeverReachesTheOtherAgent() async throws {
        try watches.add(
            WatchRule(
                owner: "claude",
                projectPath: here,
                kind: .sessionEnd,
                target: "codex",
                note: "usa ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 para el deploy"
            )
        )

        model.ingest(envelope(event: "SessionEnd"))

        let text = try XCTUnwrap(noticesForClaude().first).text
        XCTAssertFalse(text.contains("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))
        XCTAssertTrue(text.contains("[redacted key]"))
        let onDisk = try String(contentsOf: paths.messages, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))
    }

    // MARK: - The store itself

    func testTheNewestWordOnARuleIsTheTrueOne() async throws {
        let rule = WatchRule(owner: "claude", projectPath: here, kind: .sessionEnd, target: "codex")
        try watches.add(rule)
        var spent = rule
        spent.firedAt = Date()
        try watches.add(spent)

        XCTAssertEqual(watches.all().count, 1, "a rule's history is one row, not two")
        XCTAssertNotNil(watches.all().first?.firedAt)
        XCTAssertTrue(watches.pending().isEmpty)
    }

    func testCallingAWatchOffTakesItOutOfTheStandingRules() async throws {
        let rule = WatchRule(owner: "claude", projectPath: here, kind: .sessionIdle, target: "codex")
        try watches.add(rule)

        let cancelled = try watches.retire(ids: [rule.id])

        XCTAssertEqual(cancelled.map(\.id), [rule.id])
        XCTAssertTrue(watches.pending().isEmpty)
        // Cancelling it appends; only the app rewrites this file.
        model.ingest(envelope(event: "Stop"))
        XCTAssertTrue(noticesForClaude().isEmpty)
        XCTAssertTrue(try watches.retire(ids: [rule.id]).isEmpty, "and calling it off twice is not an error")
    }

    func testAMissingFileIsNobodyWatchingAnything() async {
        XCTAssertTrue(Watches(paths: Paths(home: root.appendingPathComponent("empty"))).pending().isEmpty)
    }
}
