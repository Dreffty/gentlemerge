import Foundation
import XCTest
@testable import GentleMergeCore

@MainActor
final class InboxModelTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var model: InboxModel!

    override func setUp() async throws {
        try await MainActor.run { try prepare() }
    }

    private func prepare() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-model-\(UUID().uuidString)")
        paths = Paths(home: root)
        try paths.createDirectories()
        model = InboxModel(paths: paths)
    }

    override func tearDown() async throws {
        await MainActor.run { cleanUp() }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func envelope(
        id: String = UUID().uuidString,
        session: String = "s1",
        event: String = "Stop",
        provider: AgentProvider = .claudeCode,
        project: String = "/tmp/gameapp",
        pid: Int? = nil,
        extra: [String: JSONValue] = [:]
    ) -> SpoolEnvelope {
        var payload: [String: JSONValue] = [
            "session_id": .string(session),
            "hook_event_name": .string(event),
        ]
        payload.merge(extra) { _, new in new }

        return SpoolEnvelope(
            id: id,
            provider: provider,
            cwd: project,
            tty: "/dev/ttys002",
            pid: pid,
            payload: .object(payload)
        )
    }

    // MARK: - Headless drain

    /// Hook events wait in the spool until something consumes them. With no
    /// app running that something must be the read commands themselves —
    /// otherwise implicit claims (and everything built on them) silently
    /// never happen on headless machines.
    func testHeadlessDrainTurnsSpoolEditsIntoClaimsWithoutTheApp() async throws {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = Shell.run("/usr/bin/env", ["git", "init", "-q", repo.path], timeout: 15)
        let file = repo.appendingPathComponent("lib").appendingPathComponent("a.ts")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: file)
        let project = ProjectRegistry.canonicalPath(for: repo.path)

        let edit = envelope(event: "PostToolUse", project: repo.path, extra: [
            "tool_name": .string("Edit"),
            "tool_input": .object(["file_path": .string(file.path)]),
            "label": .string("hermes"),
        ])
        try SpoolStore(paths: paths).enqueue(edit)
        XCTAssertTrue(
            PathClaims(paths: paths).live(project: project).isEmpty,
            "nothing consumed the spool yet"
        )

        InboxModel.drainHeadless(paths: paths)

        let live = PathClaims(paths: paths).live(project: project)
        XCTAssertTrue(
            live.contains { $0.label == "hermes" && $0.pattern.hasSuffix("a.ts") },
            "the edit became a claim: \(live.map(\.pattern))"
        )
        XCTAssertTrue(
            SpoolStore(paths: paths).drain().isEmpty,
            "the spool is consumed, not just read"
        )
    }

    /// Two drains interleaved (app tick + headless CLI): both load the same
    /// state, each ingests its own row, each saves. The last save must merge,
    /// not erase what the other just wrote.
    func testInterleavedSavesKeepBothSidesRows() throws {
        let first = InboxModel(paths: paths)
        first.loadState()
        let second = InboxModel(paths: paths)
        second.loadState()

        first.ingest(envelope(id: "a", session: "sa", event: "Stop"))
        first.saveState()
        second.ingest(envelope(id: "b", session: "sb", event: "Stop"))
        second.saveState()

        let stored = try JSONCoding.decoder().decode(
            [InboxItem].self,
            from: Data(contentsOf: paths.state)
        )
        XCTAssertEqual(Set(stored.map(\.id)), ["a", "b"])
    }

    /// The audit's repro, as processes: 24 edit envelopes, 8 drains at once
    /// through the real binary. The spool hands each envelope to exactly one
    /// drainer and the drain lock serializes them — every edit becomes a
    /// claim and a state row, none lost.
    func testParallelDrainsLoseNoRows() throws {
        let repo = root.appendingPathComponent("repo24")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = Shell.run("/usr/bin/env", ["git", "init", "-q", repo.path], timeout: 15)
        let lib = repo.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let project = ProjectRegistry.canonicalPath(for: repo.path)
        let store = SpoolStore(paths: paths)
        for i in 0..<24 {
            let file = lib.appendingPathComponent("f\(i).ts")
            try Data("v1".utf8).write(to: file)
            try store.enqueue(envelope(
                id: "e\(i)", session: "s\(i % 4)", event: "PostToolUse", project: repo.path,
                extra: [
                    "tool_name": .string("Edit"),
                    "tool_input": .object(["file_path": .string(file.path)]),
                    "label": .string("hermes"),
                ]
            ))
        }

        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let home = paths.home.path
        let group = DispatchGroup()
        for n in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                _ = Shell.run(binary, ["brief", "--as", "drain\(n)", "--project", repo.path],
                              environment: ["GENTLEMERGE_HOME": home], timeout: 120)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 300), .success, "all drains finished")

        let live = PathClaims(paths: paths).live(project: project)
        XCTAssertEqual(live.count, 24, "every edit claimed: \(live.count)")
        // PostToolUse edits leave no inbox rows (only claims + activities),
        // but every envelope must be ingested exactly once: the ledger is
        // append-only, so its received lines count the ingestions.
        let ledgerLines = (try? String(contentsOf: paths.ledger, encoding: .utf8))?
            .split(separator: "\n").filter { $0.contains("\"received\"") } ?? []
        XCTAssertEqual(ledgerLines.count, 24, "every envelope ingested once: \(ledgerLines.count)")
        XCTAssertTrue(store.drain().isEmpty)
    }

    // MARK: - Rows

    func testOnlyTheNewestStateOfASessionStays() async throws {
        model.ingest(envelope(id: "old", event: "Stop"))
        model.ingest(envelope(id: "new", event: "Stop"))

        XCTAssertEqual(model.pending.map(\.id), ["new"])
        XCTAssertEqual(model.items.first { $0.id == "old" }?.status, .superseded)
    }

    func testTypingInTheTerminalClearsThatSession() async throws {
        model.ingest(envelope(id: "idle", event: "Stop"))
        model.ingest(envelope(id: "prompt", event: "UserPromptSubmit"))

        XCTAssertEqual(model.items.first { $0.id == "idle" }?.status, .superseded)
        XCTAssertEqual(model.pendingCount, 0)
    }

    func testClearingARowChangesNothingForTheAgent() async throws {
        model.ingest(envelope(id: "note", event: "Stop"))
        let item = try XCTUnwrap(model.pending.first)

        model.markHandled(item)

        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.history.first?.status, .handled)
        // Nothing is ever written back to an agent: no answer files, no gating.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.answers.appendingPathComponent("note.json").path))
    }

    // MARK: - The bus

    func testHookActivityUsesCanonicalRepositoryIdentity() async throws {
        let repo = root.appendingPathComponent("repository")
        let child = repo.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let git = Shell.run("/usr/bin/env", ["git", "init", "-q", repo.path])
        XCTAssertTrue(git.succeeded)
        model.ingest(envelope(session: "canonical-session", project: child.path))
        let activity = try XCTUnwrap(model.liveActivities.first { $0.id == "canonical-session" })
        XCTAssertEqual(activity.projectPath, ProjectRegistry.canonicalPath(for: repo.path))
    }

    func testEveryEventUpdatesWhatThatSessionIsDoing() async throws {
        model.ingest(envelope(
            session: "s1",
            event: "UserPromptSubmit",
            extra: ["prompt": .string("arregla el generador de misiones\nsegunda línea")]
        ))

        let working = try XCTUnwrap(model.liveActivities.first)
        XCTAssertEqual(working.state, .working)
        XCTAssertEqual(working.currentTask, "arregla el generador de misiones")
        XCTAssertEqual(working.projectName, "gameapp")

        model.ingest(envelope(session: "s1", event: "Stop"))
        XCTAssertEqual(model.liveActivities.first?.state, .idle)

        model.ingest(envelope(
            session: "s1",
            event: "Notification",
            extra: ["message": .string("Claude is waiting for your input")]
        ))
        XCTAssertEqual(model.liveActivities.first?.state, .waiting)

        model.ingest(envelope(session: "s1", event: "SessionEnd"))
        XCTAssertTrue(model.liveActivities.isEmpty, "an ended session is not running")
    }

    func testTwoAgentsInTheSameProjectAreBothVisible() async throws {
        model.ingest(envelope(
            session: "claude-1",
            event: "UserPromptSubmit",
            provider: .claudeCode,
            extra: ["prompt": .string("traduce constants a EN")]
        ))
        model.ingest(envelope(
            session: "codex-1",
            event: "UserPromptSubmit",
            provider: .codex,
            extra: ["prompt": .string("arregla el schema")]
        ))

        XCTAssertEqual(Set(model.liveActivities.map(\.provider)), [.claudeCode, .codex])

        // What each of them would be told about the other.
        let forClaude = try XCTUnwrap(
            model.bus.briefing(sessionID: "claude-1", provider: .claudeCode, project: "/tmp/gameapp")
        )
        XCTAssertTrue(forClaude.contains("arregla el schema"))
        XCTAssertFalse(forClaude.contains("traduce constants"), "a session is never told about itself")
    }

    func testAMessageReachesTheOtherAgentsExactlyOnce() async throws {
        model.ingest(envelope(session: "codex-1", provider: .codex))
        model.say("he tocado el schema de misiones, no lo toquéis")

        let first = try XCTUnwrap(
            model.bus.briefing(sessionID: "claude-1", provider: .claudeCode, project: nil)
        )
        XCTAssertTrue(first.contains("he tocado el schema"))
        XCTAssertTrue(first.contains("you"), "who said it matters")

        // Same state on the next turn: saying it again would be noise, and would
        // teach the model to skip the block.
        XCTAssertNil(model.bus.briefing(sessionID: "claude-1", provider: .claudeCode, project: nil))
    }

    func testAnAgentIsNotToldItsOwnMessage() async throws {
        model.bus.post(AgentMessage(from: "claude", text: "voy a tocar el árbol"))

        XCTAssertNil(
            model.bus.briefing(sessionID: "claude-1", provider: .claudeCode, project: nil),
            "no other agents running and only its own message"
        )
        let forCodex = try XCTUnwrap(
            model.bus.briefing(sessionID: "codex-1", provider: .codex, project: nil)
        )
        XCTAssertTrue(forCodex.contains("voy a tocar el árbol"))
    }

    func testNothingHappeningMeansNothingIsInjected() async {
        XCTAssertNil(model.bus.briefing(sessionID: "lonely", provider: .claudeCode, project: nil))
    }

    func testProjectScopedMessagesStayInTheirProject() async throws {
        model.say("solo para gameapp", project: "/tmp/gameapp")

        XCTAssertNil(model.bus.briefing(sessionID: "a", provider: .claudeCode, project: "/tmp/otro"))
        XCTAssertNotNil(model.bus.briefing(sessionID: "b", provider: .claudeCode, project: "/tmp/gameapp"))
    }

    // MARK: - Nothing sensitive crosses to another agent

    func testASecretInYourPromptNeverReachesTheOtherAgents() async throws {
        model.ingest(envelope(
            session: "s1",
            event: "UserPromptSubmit",
            extra: ["prompt": .string("mete la key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz012345 en el .env y avisa a luis@example.com")]
        ))

        let task = try XCTUnwrap(model.liveActivities.first?.currentTask)
        XCTAssertFalse(task.contains("AbCdEfGhIjKlMnOpQrStUvWxYz012345"))
        XCTAssertFalse(task.contains("luis@example.com"))
        XCTAssertTrue(task.contains("[redacted key]"))
        XCTAssertTrue(task.contains("en el .env"), "lo que no es secreto se queda")

        // Not even on our own disk: the file other tools read is clean too.
        let onDisk = try String(contentsOf: paths.activities, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("AbCdEfGhIjKlMnOpQrStUvWxYz012345"))
        XCTAssertFalse(onDisk.contains("luis@example.com"))
    }

    func testAPromptThatIsOnlyASecretSharesAStubNeverSilence() async throws {
        model.ingest(envelope(
            session: "s1",
            event: "UserPromptSubmit",
            extra: ["prompt": .string("sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz012345")]
        ))

        let activity = try XCTUnwrap(model.liveActivities.first)
        let task = try XCTUnwrap(activity.currentTask, "silence reads as nothing new; a stub does not")
        XCTAssertTrue(task.contains("withheld"), task)
        XCTAssertFalse(task.contains("AbCdEfGhIjKlMnOpQrStUvWxYz012345"), "the stub names the kind, never the content")
        XCTAssertEqual(activity.state, .working, "la sesión sigue apareciendo como viva")
    }

    func testYouCanTurnOffSharingPromptTextEntirely() async throws {
        model.config.shareTaskText = false
        model.ingest(envelope(
            session: "s1",
            event: "UserPromptSubmit",
            extra: ["prompt": .string("arregla el generador de misiones")]
        ))

        XCTAssertNil(model.liveActivities.first?.currentTask)
    }

    func testAMessageWithAKeyIsScrubbedBeforeItIsStored() async throws {
        model.say("usa ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 para el deploy")

        let stored = try XCTUnwrap(model.messages.last)
        XCTAssertFalse(stored.text.contains("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))
        XCTAssertTrue(stored.text.contains("[redacted key]"))
        XCTAssertTrue(model.lastMessage?.contains("taken out") ?? false, model.lastMessage ?? "")

        let onDisk = try String(contentsOf: paths.messages, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))
    }

    func testATaskWithASecretNeverLandsInTheRepoFile() async throws {
        let project = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        model.addTask("rotar la clave AKIAIOSFODNN7EXAMPLE del deploy", to: project.path)

        let file = try String(contentsOf: ProjectHandoff.fileURL(for: project.path), encoding: .utf8)
        XCTAssertFalse(file.contains("AKIAIOSFODNN7EXAMPLE"), "esto se commitea")
        XCTAssertTrue(file.contains("rotar la clave"))
    }

    // MARK: - Sessions and projects

    func testSessionStartRecordsABaselineForLaterReview() async throws {
        model.ingest(envelope(
            id: "s-start",
            session: "s9",
            event: "SessionStart",
            extra: ["source": .string("startup")]
        ))

        let record = try XCTUnwrap(model.sessions["s9"])
        XCTAssertEqual(record.projectPath, "/tmp/gameapp")
        XCTAssertTrue(record.isLive)
    }

    func testWorkingSomewhereMakesItAProject() async throws {
        model.ingest(envelope(project: "/tmp/gameapp"))
        XCTAssertEqual(model.projects.map(\.name), ["gameapp"])
    }

    func testStateSurvivesARestart() async throws {
        model.ingest(envelope(id: "kept", event: "Stop"))
        model.markHandled(try XCTUnwrap(model.pending.first))

        let reopened = InboxModel(paths: paths)
        reopened.start()
        defer { reopened.stop() }

        XCTAssertEqual(reopened.history.first?.id, "kept")
        XCTAssertEqual(reopened.activities.first?.id, "s1")
    }

    // MARK: - What a session left behind

    /// A project with one task at 1/2, and the path the model will see.
    private func projectWithHalfDoneWork(finishingEverything: Bool = false) throws -> String {
        let directory = root.appendingPathComponent("gameapp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filed = ProjectRegistry.addTask(
            "Smoke manual de tipos de habito",
            to: directory.path,
            by: "claude",
            steps: ["contable 3 taps", "timer 5 min"]
        )
        let task = try XCTUnwrap(filed.tasks.first)
        ProjectRegistry.setStep(at: 0, ofTask: task.id, done: true, in: directory.path)
        if finishingEverything {
            ProjectRegistry.setStep(at: 1, ofTask: task.id, done: true, in: directory.path)
        }
        return directory.path
    }

    func testASessionThatEndsWithPointsOpenLeavesTheGapBehind() async throws {
        let project = try projectWithHalfDoneWork()

        model.ingest(envelope(id: "end", event: "SessionEnd", project: project))

        let row = try XCTUnwrap(model.pending.first { $0.id.hasSuffix("-unfinished") })
        XCTAssertEqual(row.kind, .info, "a note for you, never anything that gates an agent")
        XCTAssertFalse(model.config.shouldNotify(for: row.kind), "and it does not interrupt you either")
        XCTAssertTrue(row.summary.contains("1/2"))
        XCTAssertTrue(try XCTUnwrap(row.detail).contains("timer 5 min"))
    }

    func testASessionThatTickedEverythingOffLeavesNothing() async throws {
        let project = try projectWithHalfDoneWork(finishingEverything: true)

        model.ingest(envelope(id: "end", event: "SessionEnd", project: project))

        XCTAssertFalse(model.items.contains { $0.id.hasSuffix("-unfinished") })
    }

    func testTheGapIsReportedWhenTheSessionEndsAndNotOnEveryTurn() async throws {
        let project = try projectWithHalfDoneWork()

        model.ingest(envelope(id: "turn", event: "Stop", project: project))

        XCTAssertFalse(
            model.items.contains { $0.id.hasSuffix("-unfinished") },
            "a row after every turn is noise, and noise is what gets ignored"
        )
    }

    // MARK: - Sessions that died rather than ended

    /// A pid with nothing behind it any more. Launched for real: a made-up
    /// number could be somebody else's live process.
    private func pidOfAProcessThatIsGone() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = Int(process.processIdentifier)
        process.waitUntilExit()
        return pid
    }

    func testASessionWhoseProcessDiedIsBuriedInsteadOfLeftWorking() async throws {
        let project = try projectWithHalfDoneWork()
        model.ingest(envelope(event: "UserPromptSubmit", project: project, pid: try pidOfAProcessThatIsGone()))
        XCTAssertEqual(model.liveActivities.first?.state, .working)

        model.drainNow()

        let activity = try XCTUnwrap(model.activities.first { $0.id == "s1" })
        XCTAssertEqual(activity.state, .ended)
        XCTAssertEqual(activity.lastEvent, "died")
        XCTAssertTrue(model.liveActivities.isEmpty, "and nobody is told about it any more")
        XCTAssertNotNil(model.sessions["s1"]?.endedAt)
    }

    func testADeathLeavesTheSameScoreBehindThatAnEndingWould() async throws {
        let project = try projectWithHalfDoneWork()
        model.ingest(envelope(event: "UserPromptSubmit", project: project, pid: try pidOfAProcessThatIsGone()))

        model.drainNow()

        let row = try XCTUnwrap(model.pending.first { $0.id.hasSuffix("-unfinished") })
        XCTAssertEqual(row.id, "s1-died-unfinished")
        XCTAssertEqual(row.kind, .info, "a note for you — the session is gone, and was never told anything")
        XCTAssertTrue(row.summary.contains("1/2"))
    }

    func testBuryingTheSameSessionTwiceLeavesOneRow() async throws {
        let project = try projectWithHalfDoneWork()
        model.ingest(envelope(event: "UserPromptSubmit", project: project, pid: try pidOfAProcessThatIsGone()))

        model.drainNow()
        model.drainNow()

        XCTAssertEqual(model.items.filter { $0.id.contains("-died") }.count, 1)
    }

    func testASessionStillRunningIsLeftAlone() async throws {
        let project = try projectWithHalfDoneWork()
        // Our own process: alive by definition for as long as this test runs.
        model.ingest(envelope(event: "UserPromptSubmit", project: project, pid: Int(getpid())))

        model.drainNow()

        XCTAssertEqual(model.liveActivities.first?.state, .working)
        XCTAssertFalse(model.items.contains { $0.id.contains("-died") })
    }

    func testASessionFromBeforePidsWasKeptIsNeverBuriedOnSuspicion() async throws {
        let project = try projectWithHalfDoneWork()
        model.ingest(envelope(event: "UserPromptSubmit", project: project))

        model.drainNow()

        XCTAssertEqual(model.liveActivities.first?.state, .working, "no pid is not knowing, not dead")
    }

    func testAnEndingAfterABurialDoesNotLeaveTwoNotices() async throws {
        let project = try projectWithHalfDoneWork()
        model.ingest(envelope(event: "UserPromptSubmit", project: project, pid: try pidOfAProcessThatIsGone()))
        model.drainNow()

        model.ingest(envelope(id: "end", event: "SessionEnd", project: project))

        XCTAssertEqual(model.pending.filter { $0.id.hasSuffix("-unfinished") }.count, 1)
    }

    // MARK: - Review

    func testReviewRunsTheProjectsOwnChecksAndKeepsTheResult() async throws {
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"""
        {"replaceDetected":true,"checks":[
          {"name":"green","command":"true","kind":"test","timeout":30,"optional":false},
          {"name":"red","command":"echo boom >&2; exit 2","kind":"build","timeout":30,"optional":false}]}
        """#.utf8).write(to: project.appendingPathComponent(ProjectChecks.configFileName))

        model.startReview(projectPath: project.path, sessionID: "s1")

        for _ in 0..<200 where model.activeReview?.finishedAt == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let review = try XCTUnwrap(model.activeReview)
        XCTAssertEqual(review.verdict, .problems)
        XCTAssertEqual(review.checks.first { $0.name == "green" }?.status, .passed)

        let failed = try XCTUnwrap(review.checks.first { $0.name == "red" })
        XCTAssertEqual(failed.exitCode, 2)
        XCTAssertTrue(failed.output.contains("boom"), "a failure has to show why")
        XCTAssertFalse(review.openQuestions.isEmpty)
    }

    func testSpoolFilesAreConsumedOnceAndBadOnesQuarantined() async throws {
        let store = SpoolStore(paths: paths)
        let data = try JSONCoding.encoder().encode(envelope(id: "from-disk"))
        try data.write(to: paths.spool.appendingPathComponent("1-good.json"))
        try Data("not json".utf8).write(to: paths.spool.appendingPathComponent("2-bad.json"))

        XCTAssertEqual(store.drain().map(\.id), ["from-disk"])
        XCTAssertTrue(store.drain().isEmpty, "a drained envelope must not come back")

        let processed = try FileManager.default.contentsOfDirectory(atPath: paths.processed.path)
        XCTAssertTrue(processed.contains("1-good.json"))
        XCTAssertTrue(processed.contains("2-bad.json.bad"))
    }
}
