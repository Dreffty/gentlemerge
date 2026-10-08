import XCTest
@testable import GentleMergeCore

/// Two dispatch findings, both about a request that had already been decided
/// and then lost the decision somewhere downstream.
final class DispatchDecisionTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatchdec-\(UUID())")
        paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func config(dailyBudget: Int, autoApprove: Int = 0, tiers: [String] = []) -> AppConfig {
        var config = AppConfig()
        config.allowDispatch = true
        config.dispatchMode = "delegated"
        config.dispatchDailyBudgetMinutes = dailyBudget
        config.dispatchAutoApproveMinutes = autoApprove
        config.dispatchAutoApproveTiers = tiers
        config.agents = [AgentTarget(label: "codex", command: ["true"], costTier: "expensive")]
        return config
    }

    private func request(minutes: Int) -> AgentRequest {
        var request = AgentRequest(
            id: "req-gate", from: "claude", fromVerified: true, to: "codex",
            projectPath: root.path, title: "draw", spec: "…", budgetMinutes: minutes, state: .assigned
        )
        request.resolvedTo = "codex"
        return request
    }

    /// #17 — a human clicking Approve wrote the id, was told "the next drain
    /// will check the dispatch gate", and the gate kept answering
    /// needsApproval because the daily-budget test ran first and approval was
    /// only consulted after it. `approvalNotifiedIDs` then suppressed the
    /// re-notification, so the UI showed a pending approval the user had
    /// already granted and nothing else happened.
    func testAnExplicitApprovalOutranksTheDailyBudget() {
        let spent = 100
        let request = self.request(minutes: 40)
        let config = self.config(dailyBudget: 120)

        // Without approval the budget still gates it.
        let unapproved = DispatchGate.decide(
            request: request, config: config, liveLabels: [],
            lastDispatched: [:], approved: false, spentTodayMinutes: spent
        )
        guard case .needsApproval = unapproved else {
            return XCTFail("without approval the budget must still gate: \(unapproved)")
        }

        // With approval it goes, or the button does nothing.
        let approved = DispatchGate.decide(
            request: request, config: config, liveLabels: [],
            lastDispatched: [:], approved: true, spentTodayMinutes: spent
        )
        guard case .dispatch = approved else {
            return XCTFail("an explicit approval must outrank the daily budget: \(approved)")
        }
    }

    /// And the override is scoped: it must not resurrect a request the gate
    /// refuses for some other reason entirely.
    func testApprovalDoesNotOverrideAnUndispatchableRequest() {
        let request = self.request(minutes: 5)

        XCTAssertEqual(
            DispatchGate.decide(request: request, config: config(dailyBudget: 0), liveLabels: ["codex"],
                lastDispatched: [:], approved: true, spentTodayMinutes: 0),
            .skip(reason: "codex has a live session; briefing/nudge will deliver"),
            "a live delegate means the work is already happening"
        )

        var off = config(dailyBudget: 0)
        off.dispatchMode = "nonsense"
        XCTAssertEqual(
            DispatchGate.decide(request: request, config: off, liveLabels: [],
                lastDispatched: [:], approved: true, spentTodayMinutes: 0),
            .skip(reason: "unknown dispatch mode \"nonsense\" — want off, delegated or strict"),
            "approval must not rescue a request the gate refuses on its own terms"
        )
    }

    /// #18 — the headless dispatcher recorded the end of a request by calling
    /// `Requests.transition` directly. Every other state change goes through
    /// `RequestActions.perform`, which also releases the delegate's `may_touch`
    /// claims, ticks the backing task, and posts a result back to the
    /// delegator. So a delegate that timed out left its claims blocking other
    /// agents until their TTL, its task open, and the requester with nothing.
    func testAHeadlessDispatchThatDiesReleasesClaimsAndTellsTheRequester() throws {
        let store = Requests(paths: paths)
        let bus = AgentBus(paths: paths)
        var request = AgentRequest(
            id: "req-dispatch", from: "claude", fromVerified: true, to: "codex",
            projectPath: root.path, title: "draw", spec: "…",
            budgetMinutes: 5, state: .assigned
        )
        request.resolvedTo = "codex"
        request.mayTouch = ["assets/**"]
        try store.save(request)

        // The delegate reserved its may_touch paths, as Delegate does.
        try PathClaims(paths: paths).claim(
            pattern: "assets/**", label: "codex", project: root.path,
            intent: "drawing", requestID: request.id
        )
        XCTAssertEqual(PathClaims(paths: paths).live(project: root.path).count, 1)

        // What the dispatcher used to do: transition only.
        _ = try store.transition(request.id, to: .inProgress, by: "codex", result: nil)
        _ = try store.transition(
            request.id, to: .failed, by: "codex",
            result: "process failed/timed out (exit 1)"
        )

        // The claim survived, and nothing was said. This is the finding.
        XCTAssertEqual(
            PathClaims(paths: paths).live(project: root.path).count, 1,
            "the direct transition left the delegate's claim alive, blocking everyone else"
        )
        let toldRequester = bus.messages()
            .contains { $0.from == "codex" && $0.to == "claude" && $0.kind == .requestResult }
        XCTAssertFalse(toldRequester, "the direct transition posted no result to the delegator")
    }

    /// The same request through the path the dispatcher now uses.
    func testTheCallbackPathReleasesClaimsAndPostsTheResult() throws {
        let store = Requests(paths: paths)
        let bus = AgentBus(paths: paths)
        var request = AgentRequest(
            id: "req-callback", from: "claude", fromVerified: true, to: "codex",
            projectPath: root.path, title: "draw", spec: "…",
            budgetMinutes: 5, state: .assigned
        )
        request.resolvedTo = "codex"
        request.mayTouch = ["assets/**"]
        try store.save(request)
        try PathClaims(paths: paths).claim(
            pattern: "assets/**", label: "codex", project: root.path,
            intent: "drawing", requestID: request.id
        )
        _ = try store.transition(request.id, to: .inProgress, by: "codex", result: nil)

        _ = try RequestActions.perform(
            action: "fail", id: request.id, by: "codex",
            result: "process failed/timed out (exit 1)", paths: paths
        )

        XCTAssertEqual(
            PathClaims(paths: paths).live(project: root.path).count, 0,
            "the callback path must release the delegate's may_touch claims"
        )
        let result = bus.messages()
            .first { $0.kind == .requestResult }
        XCTAssertNotNil(result, "the delegator must be told")
        XCTAssertEqual(result?.from, "codex")
        XCTAssertEqual(result?.to, "claude")
        XCTAssertEqual(store.all().first { $0.id == request.id }?.state, .failed)
    }
}