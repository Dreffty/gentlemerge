import XCTest
@testable import GentleMergeCore

@MainActor
final class RequestsTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var paths: Paths!
    private var bus: AgentBus!

    override func setUp() async throws {
        try await MainActor.run { try prepare() }
    }

    private func prepare() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-requests-\(UUID().uuidString)")
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-request-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        paths = try Paths(home: root).createDirectories()
        bus = AgentBus(paths: paths)
    }

    override func tearDown() async throws {
        await MainActor.run { cleanUp() }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: project)
    }

    private var here: String { ProjectRegistry.canonicalPath(for: project.path) }

    private func envelope(event: String = "Stop") -> SpoolEnvelope {
        SpoolEnvelope(
            id: UUID().uuidString,
            provider: .codex,
            cwd: project.path,
            tty: "/dev/ttys001",
            payload: .object([
                "session_id": .string("codex-1"),
                "hook_event_name": .string(event),
            ])
        )
    }

    func testDelegateAcceptDoneWatchResultAndAckLifecycle() async throws {
        let request = try bus.delegate(
            from: "claude",
            fromVerified: true,
            to: "codex",
            projectPath: here,
            title: "write fixture",
            spec: "create the tiny output",
            inputs: ["README.md"],
            expectedOutput: "Tests/Fixture.txt",
            mayTouch: ["Tests/**"],
            budgetMinutes: 10
        )

        XCTAssertEqual(request.state, .assigned)
        XCTAssertEqual(request.resolvedTo, "codex")
        XCTAssertNotNil(request.taskID)
        XCTAssertNotNil(request.watchID)
        XCTAssertEqual(Requests(paths: paths).pending(for: "codex", project: here).map(\.id), [request.id])
        XCTAssertEqual(PathClaims(paths: paths).live(project: here).first?.requestID, request.id)
        XCTAssertTrue(bus.messages().contains { $0.kind == .request && $0.requestID == request.id })

        XCTAssertEqual(try RequestActions.perform(action: "accept", id: request.id, by: "codex", result: nil, paths: paths), "accepted \(request.id)")
        XCTAssertEqual(try RequestActions.perform(action: "done", id: request.id, by: "codex", result: "ok", paths: paths), "done \(request.id)")

        XCTAssertTrue(PathClaims(paths: paths).live(project: here).isEmpty)
        let stored = try XCTUnwrap(Requests(paths: paths).load(request.id))
        XCTAssertEqual(stored.state, .done)
        XCTAssertEqual(stored.result, "ok")
        XCTAssertEqual(ProjectRegistry.handoff(for: here, refreshingCommits: false).tasks.first?.done, true)
        XCTAssertTrue(bus.messages().contains { $0.kind == .requestResult && $0.to == "claude" && $0.text.contains("ok") })

        let model = InboxModel(paths: paths)
        model.ingest(envelope())
        XCTAssertTrue(bus.messages().contains { $0.from == "inbox" && $0.to == "claude" && $0.text.contains("request \(request.id)") })

        XCTAssertEqual(try RequestActions.perform(action: "ack", id: request.id, by: "claude", result: nil, paths: paths), "acked \(request.id)")
        XCTAssertEqual(Requests(paths: paths).load(request.id)?.state, .acked)
    }

    func testGeneratedRequestIDSurvivesRedactionForNumericUUIDPrefix() async throws {
        // Prefix captured from the failing lifecycle run; the UUID tail is irrelevant.
        let uuid = try XCTUnwrap(UUID(uuidString: "21452098-0000-4000-8000-000000000000"))
        let id = AgentRequest.makeID(from: uuid)
        XCTAssertTrue(Requests.validID(id))
        let messages = [
            "[\(id)] write fixture -> Tests/Fixture.txt · budget 10m",
            "Run `gentlemerge request show \(id)` for the spec.",
            "[\(id)] done: ok",
            "watch: task done — [\(id)] write fixture — request \(id) finished",
        ]
        for message in messages {
            XCTAssertEqual(Redactor.scrub(message).text, message)
        }
        // Do not solve the identifier collision by weakening secret filtering.
        XCTAssertEqual(Redactor.scrub("account 21452098").text, "account [redacted number]")
    }

    func testInvalidTransitionsAndWrongActorThrowButYouCanAct() async throws {
        var request = AgentRequest(
            from: "claude",
            fromVerified: true,
            to: "codex",
            projectPath: here,
            title: "x",
            spec: "x"
        )
        request.resolvedTo = "codex"
        request.state = .assigned
        try Requests(paths: paths).save(request)

        XCTAssertThrowsError(try Requests(paths: paths).transition(request.id, to: .done, by: "codex", result: nil))
        XCTAssertThrowsError(try Requests(paths: paths).transition(request.id, to: .inProgress, by: "hermes", result: nil))
        XCTAssertNoThrow(try Requests(paths: paths).transition(request.id, to: .inProgress, by: "you", result: nil))
        XCTAssertNoThrow(try Requests(paths: paths).transition(request.id, to: .failed, by: "you", result: "stopped"))
        XCTAssertThrowsError(try Requests(paths: paths).transition(request.id, to: .acked, by: "codex", result: nil))
        XCTAssertNoThrow(try Requests(paths: paths).transition(request.id, to: .acked, by: "you", result: nil))
    }

    func testCapabilityRouteRequiresALiveCapableAgentAndChoosesNewest() async throws {
        XCTAssertThrowsError(try bus.delegate(
            from: "claude",
            fromVerified: true,
            to: "capability:image_generation",
            projectPath: here,
            title: "draw",
            spec: "make image",
            inputs: [],
            expectedOutput: nil,
            mayTouch: [],
            budgetMinutes: 10
        )) { error in
            XCTAssertTrue("\(error)".contains("image_generation"))
        }

        Presence.record(
            label: "old-codex",
            project: here,
            branch: nil,
            paths: paths,
            now: Date().addingTimeInterval(-5),
            capabilities: ["image_generation"]
        )
        Presence.record(
            label: "new-codex",
            project: here,
            branch: nil,
            paths: paths,
            now: Date(),
            capabilities: ["image_generation"]
        )

        let request = try bus.delegate(
            from: "claude",
            fromVerified: true,
            to: "capability:image_generation",
            projectPath: here,
            title: "draw",
            spec: "make image",
            inputs: [],
            expectedOutput: nil,
            mayTouch: [],
            budgetMinutes: 10
        )
        XCTAssertEqual(request.resolvedTo, "new-codex")
    }

    func testHeartbeatPreservesCapabilitiesAndExplicitEmptyClearsThem() async {
        Presence.record(label: "codex", project: here, branch: "main", paths: paths,
                        environment: [:], capabilities: ["images"])
        Presence.record(label: "codex", project: here, branch: "main", paths: paths,
                        environment: [:])
        XCTAssertEqual(Presence.labels(withCapability: "images", project: here, paths: paths), ["codex"])
        Presence.record(label: "codex", project: here, branch: "main", paths: paths,
                        environment: [:], capabilities: [])
        XCTAssertTrue(Presence.labels(withCapability: "images", project: here, paths: paths).isEmpty)
    }

    func testCapabilityRoutingExcludesARecentlyExitedProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let deadPID = Int(process.processIdentifier)
        XCTAssertEqual(Liveness.isProcessAlive(deadPID), false)
        Presence.record(label: "alive", project: here, branch: nil,
                        pid: Int(ProcessInfo.processInfo.processIdentifier), paths: paths,
                        now: Date().addingTimeInterval(-5), capabilities: ["images"])
        Presence.record(label: "dead", project: here, branch: nil, pid: deadPID,
                        paths: paths, capabilities: ["images"])
        XCTAssertEqual(Presence.labels(withCapability: "images", project: here, paths: paths), ["alive"])
    }

    func testDoneReleasesOnlyClaimsForThatRequest() async throws {
        var request = AgentRequest(
            from: "claude",
            fromVerified: true,
            to: "codex",
            projectPath: here,
            title: "x",
            spec: "x",
            mayTouch: ["Sources/**"]
        )
        request.resolvedTo = "codex"
        request.state = .inProgress
        try Requests(paths: paths).save(request)

        _ = try PathClaims(paths: paths).claim(pattern: "Sources/**", label: "codex", project: here, intent: "request", requestID: request.id)
        _ = try PathClaims(paths: paths).claim(pattern: "Docs/**", label: "codex", project: here, intent: "other")

        _ = try RequestActions.perform(action: "done", id: request.id, by: "codex", result: "ok", paths: paths)

        let live = PathClaims(paths: paths).live(project: here)
        XCTAssertEqual(live.map(\.pattern), ["Docs/**"])
        XCTAssertNil(live.first?.requestID)
    }

    func testPendingRequestsRepeatAndRequesterSeesStateOnlyChanges() async throws {
        let r = try bus.delegate(from: "claude", fromVerified: false, to: "codex", projectPath: here,
            title: "work", spec: "work", inputs: [], expectedOutput: nil, mayTouch: [], budgetMinutes: 10)
        for _ in 0..<2 {
            XCTAssertTrue(bus.briefing(sessionID: "recipient", me: "codex", project: here, mode: .delta)?.contains("Requests for you") == true)
        }
        _ = bus.briefing(sessionID: "sender", me: "claude", project: here, mode: .delta)
        _ = try RequestActions.perform(action: "accept", id: r.id, by: "codex", result: nil, paths: paths)
        XCTAssertTrue(bus.briefing(sessionID: "sender", me: "claude", project: here, mode: .delta)?.contains("in_progress") == true)
        XCTAssertNil(bus.briefing(sessionID: "sender", me: "claude", project: here, mode: .delta))
    }

    func testTruncatedRequestUpdateRemainsPendingUntilDelivered() async throws {
        var request = AgentRequest(from: "claude", fromVerified: false, to: "codex",
                                   projectPath: here, title: "work", spec: "work")
        request.state = .inProgress
        try Requests(paths: paths).save(request)
        // Preceding claims consume the delta budget, hiding the update. One
        // long line is not enough: peer lines are capped at 500 chars, so the
        // filler is many claims, the way a busy project actually looks.
        for letter in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"] {
            _ = try PathClaims(paths: paths).claim(pattern: "mod-\(letter)/**", label: "other-\(letter)",
                project: here, intent: String(repeating: "busy ", count: 20))
        }
        let session = "truncated-request"
        let first = try XCTUnwrap(bus.briefing(sessionID: session, me: "claude", project: here, mode: .delta))
        XCTAssertFalse(first.contains("[\(request.id)]"))
        XCTAssertNil(BriefingCursorStore(paths: paths).load(sessionID: session).seenRequestStates[request.id])
        let next = try XCTUnwrap(bus.briefing(sessionID: session, me: "claude", project: here, mode: .delta))
        XCTAssertTrue(next.contains("[\(request.id)] in_progress"))
        XCTAssertEqual(BriefingCursorStore(paths: paths).load(sessionID: session).seenRequestStates[request.id], "in_progress")
        XCTAssertNil(bus.briefing(sessionID: session, me: "claude", project: here, mode: .delta))
    }

    func testRequestIDsCannotEscapeStorage() async throws {
        let store = Requests(paths: paths)
        let bad = AgentRequest(id: "../outside", from: "a", fromVerified: false, to: "b", projectPath: here, title: "x", spec: "x")
        XCTAssertThrowsError(try store.save(bad))
        XCTAssertNil(store.load("../outside"))
        XCTAssertThrowsError(try store.transition("../outside", to: .assigned, by: "b", result: nil))
    }

    func testRequestReservationDoesNotReplaceAnIndependentClaim() async throws {
        let claims = PathClaims(paths: paths)
        _ = try claims.claim(pattern: "Sources/**", label: "codex", project: here, intent: "independent")
        let r = try bus.delegate(from: "claude", fromVerified: false, to: "codex", projectPath: here,
                                 title: "work", spec: "work", inputs: [], expectedOutput: nil,
                                 mayTouch: ["Sources/**"], budgetMinutes: 10)
        _ = try RequestActions.perform(action: "reject", id: r.id, by: "codex", result: nil, paths: paths)
        XCTAssertEqual(claims.live(project: here).count, 1)
        XCTAssertNil(claims.live(project: here).first?.requestID)
    }

    func testRejectsInvalidBudgetAndScrubsStoredInputs() async throws {
        XCTAssertThrowsError(try bus.delegate(from: "a", fromVerified: false, to: "b", projectPath: here,
            title: "work", spec: "work", inputs: [], expectedOutput: nil, mayTouch: [], budgetMinutes: 0))
        let secret = "sk-TEST0000000000000000FAKE"
        let r = try bus.delegate(from: "a", fromVerified: false, to: "b", projectPath: here,
            title: "work", spec: "work", inputs: [secret], expectedOutput: nil, mayTouch: [], budgetMinutes: 10)
        XCTAssertFalse(try String(contentsOf: Requests(paths: paths).url(r.id), encoding: .utf8).contains(secret))
    }

    func testForgivingDecodeTreatsUnknownStateAsQueued() async throws {
        let json = """
        {"id":"req-test","from":"a","to":"b","projectPath":"/p","title":"t","state":"teleported"}
        """
        let request = try JSONCoding.decoder().decode(AgentRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.state, .queued)
        XCTAssertFalse(request.fromVerified)
    }

    func testPrecommitBlocksPathsOutsideActiveRequestMayTouch() async {
        var request = AgentRequest(
            id: "req-active",
            from: "claude",
            fromVerified: true,
            to: "codex",
            projectPath: "/p",
            title: "assets",
            spec: "only assets",
            mayTouch: ["assets/**"]
        )
        request.resolvedTo = "codex"
        request.state = .inProgress

        let violations = PrecommitGate.evaluate(
            staged: ["lib/x.dart"],
            me: "codex",
            claims: [],
            ownership: Ownership(rules: []),
            activeRequest: request
        )
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations[0].reason.contains("req-active"))
        XCTAssertTrue(violations[0].blocking)
    }
}
