import XCTest
@testable import GentleMergeCore

/// `budgetMinutes` is sold as part of the delegation contract — "a contract with
/// `may_touch` paths, time budget, state machine and automatic callback". Until
/// now nothing in the codebase compared it to the clock. It was advisory
/// everywhere except the headless dispatcher's own `Shell.run` timeout.
///
/// Two consequences, both from the same missing comparison:
///
///  * a request created three days ago with `budget_minutes: 30` could still be
///    accepted and completed at any later date, so the budget bought nothing;
///  * `Requests.pending` has no age filter and no cursor dedup, so that same
///    request was re-injected into **every** briefing, forever — and a
///    non-empty request block also stops the silence fast-path, so the whole
///    project paid per turn for a contract nobody was going to pick up.
final class RequestBudgetTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-\(UUID())")
        paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(
        id: String = "req-budget",
        minutes: Int = 30,
        ageMinutes: Double = 0,
        state: RequestState = .queued
    ) -> AgentRequest {
        var request = AgentRequest(
            id: id, from: "claude", fromVerified: true, to: "codex",
            projectPath: root.path, title: "do the thing", spec: "…",
            budgetMinutes: minutes, state: state
        )
        request.resolvedTo = "codex"
        request.createdAt = Date().addingTimeInterval(-ageMinutes * 60)
        request.updatedAt = request.createdAt
        return request
    }

    func testABudgetThatHasNotRunOutIsNotPastIt() {
        XCTAssertFalse(request(minutes: 30, ageMinutes: 5).isPastBudget())
        XCTAssertFalse(request(minutes: 30, ageMinutes: 29).isPastBudget())
        XCTAssertTrue(request(minutes: 30, ageMinutes: 31).isPastBudget())
        XCTAssertTrue(request(minutes: 30, ageMinutes: 3 * 24 * 60).isPastBudget())
    }

    /// Zero means "no deadline" here, matching how `budgetMinutes` is validated
    /// at creation — it must not silently mean "expired".
    func testZeroBudgetMeansNoDeadline() {
        XCTAssertFalse(request(minutes: 0, ageMinutes: 10_000).isPastBudget())
    }

    /// Measured from `createdAt`: a budget that resets on every state change
    /// would let a request live forever as long as somebody kept touching it.
    func testTheBudgetIsNotRefreshedByTouchingIt() throws {
        let store = Requests(paths: paths)
        var stale = request(minutes: 30, ageMinutes: 120, state: .queued)
        try store.save(stale)
        // A later write with a newer updatedAt must not resurrect it.
        stale = try JSONCoding.decoder().decode(AgentRequest.self, from: try JSONCoding.encoder().encode(stale))
        stale.updatedAt = Date()
        stale.state = .assigned
        try store.save(stale)

        let reloaded = try XCTUnwrap(store.all().first { $0.id == stale.id })
        XCTAssertTrue(reloaded.isPastBudget(), "updatedAt must not reset the budget")
    }

    func testAStaleRequestIsNoLongerPending() throws {
        let store = Requests(paths: paths)
        try store.save(request(id: "req-old", minutes: 30, ageMinutes: 200, state: .assigned))
        try store.save(request(id: "req-fresh", minutes: 30, ageMinutes: 1, state: .assigned))

        let pending = store.pending(for: "codex", project: root.path)

        XCTAssertFalse(pending.contains { $0.id == "req-old" }, "a past-budget request must stop being pending")
        XCTAssertTrue(pending.contains { $0.id == "req-fresh" }, "a live request must stay pending")
    }

    func testAStaleRequestCannotBeStarted() throws {
        let store = Requests(paths: paths)
        let stale = request(minutes: 30, ageMinutes: 200, state: .assigned)
        try store.save(stale)

        XCTAssertThrowsError(try store.transition(stale.id, to: .inProgress, by: "codex", result: nil)) { error in
            guard case RequestError.pastBudget = error else {
                return XCTFail("expected pastBudget, got \(error)")
            }
        }
        // Untouched: it must still be sitting in `assigned`.
        XCTAssertEqual(store.all().first { $0.id == stale.id }?.state, .assigned)
    }

    /// Declining a stale request must still work — that is the way out, and it
    /// is not "starting" anything.
    func testAStaleRequestCanStillBeRejected() throws {
        let store = Requests(paths: paths)
        let stale = request(minutes: 30, ageMinutes: 200, state: .assigned)
        try store.save(stale)

        XCTAssertNoThrow(try store.transition(stale.id, to: .rejected, by: "codex", result: "too late"))
        XCTAssertEqual(store.all().first { $0.id == stale.id }?.state, .rejected)
    }

    /// Work already in progress is deliberately exempt. The budget is for
    /// picking the task up; killing a delegate mid-flight would strand the edits
    /// it has already made, and a delegate that goes quiet is handled by its own
    /// timeout.
    func testWorkInProgressIsNotKilledByTheBudget() throws {
        let store = Requests(paths: paths)
        let running = request(minutes: 30, ageMinutes: 500, state: .inProgress)
        try store.save(running)

        XCTAssertNoThrow(try store.transition(running.id, to: .done, by: "codex", result: "ok"))
        XCTAssertTrue(store.pending(for: "codex", project: root.path).isEmpty)
    }
}