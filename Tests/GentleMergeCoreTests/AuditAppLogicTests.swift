import XCTest
@testable import GentleMergeCore

/// The logic behind what the window shows, kept in Core so it can be tested.
final class WindowRequestListTests: XCTestCase {
    private func request(_ state: RequestState, from: String) -> AgentRequest {
        AgentRequest(id: "req-\(UUID().uuidString.prefix(6))", from: from, fromVerified: true, to: "w",
                     projectPath: "/p", title: "t", spec: "s", budgetMinutes: 5, state: state)
    }

    func testFinishedWorkOfOtherAgentsIsNotCountedAsOpen() {
        XCTAssertTrue(request(.inProgress, from: "claude").isOpenInTheWindow)
        XCTAssertTrue(request(.assigned, from: "claude").isOpenInTheWindow)
        XCTAssertFalse(request(.done, from: "claude").isOpenInTheWindow, "done work somebody else delegated")
        XCTAssertFalse(request(.failed, from: "claude").isOpenInTheWindow)
        XCTAssertFalse(request(.acked, from: "you").isOpenInTheWindow)
    }

    func testAResultForThePersonAtTheKeyboardStaysUntilAcknowledged() {
        XCTAssertTrue(request(.done, from: "you").isOpenInTheWindow)
        XCTAssertTrue(request(.failed, from: "you").isOpenInTheWindow)
    }
}

final class ReviewHistorySymbolTests: XCTestCase {
    private func review(_ checks: [CheckResult], finished: Bool = true) -> Review {
        Review(projectPath: "/p", finishedAt: finished ? Date() : nil,
               work: WorkSummary(projectPath: "/p", isRepository: true), checks: checks)
    }
    private func check(_ status: CheckResult.Status) -> CheckResult {
        CheckResult(name: "c", command: "c", kind: .test, status: status)
    }

    /// "Nothing could be checked" is not a pass, and used to wear the pass's check mark.
    func testOnlyAReviewThatPassedGetsTheCheckMark() {
        XCTAssertEqual(review([check(.passed)]).historySymbol, "checkmark.circle")
        XCTAssertEqual(review([check(.failed)]).historySymbol, "xmark.circle.fill")
        XCTAssertEqual(review([]).historySymbol, "questionmark.circle")
        XCTAssertEqual(review([check(.skipped)]).historySymbol, "questionmark.circle")
        XCTAssertNotEqual(review([], finished: false).historySymbol, "checkmark.circle")
    }
}

final class SessionOfAWorktreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("session-wt-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: dir, timeout: 30)
        guard out.succeeded else { throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr]) }
        return out.stdout
    }

    /// The window names a project by its canonical root; an agent in a worktree reports the
    /// worktree. The Review button looked its session up by the first and found nothing.
    func testTheNewestSessionOfAProjectIsFoundThroughItsWorktree() throws {
        let repo = root.appendingPathComponent("repo")
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.email", "t@example.com"], in: repo); try git(["config", "user.name", "t"], in: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo); try git(["commit", "-qm", "i"], in: repo)
        let worktree = root.appendingPathComponent("wt")
        try git(["worktree", "add", "-q", worktree.path, "-b", "agent/x"], in: repo)

        var registry = SessionRegistry(url: root.appendingPathComponent("sessions.json"))
        registry.recordBaseline(id: "s-wt", provider: .claudeCode, projectPath: worktree.path, at: Date())

        let canonicalRoot = ProjectRegistry.canonicalPath(for: repo.path)
        let found = try XCTUnwrap(registry.mostRecent(in: canonicalRoot), "the session of the worktree was not found by its project")
        XCTAssertEqual(found.id, "s-wt")
        XCTAssertEqual(found.project, canonicalRoot)
        XCTAssertEqual(found.projectPath, worktree.path, "the checkout stays what the hook reported")
    }
}

@MainActor
final class DispatchApprovalNotificationTests: XCTestCase {
    private var paths: Paths!
    private var model: InboxModel!

    override func setUp() async throws {
        try await MainActor.run {
            paths = Paths(home: FileManager.default.temporaryDirectory.appendingPathComponent("approval-notice-\(UUID())"))
            try paths.createDirectories()
            model = InboxModel(paths: paths)
            model.runDispatch = { _, _ in Task {} }
        }
    }
    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: paths.home) }
    }

    private func pendingRequest() throws -> AgentRequest {
        model.config.allowDispatch = true
        model.config.agents = [AgentTarget(label: "worker", command: ["x"], costTier: "expensive")]
        var request = AgentRequest(id: "req-notice", from: "planner", fromVerified: true, to: "worker",
            projectPath: paths.home.path, title: "t", spec: "s", budgetMinutes: 5, state: .assigned)
        request.resolvedTo = "worker"
        try Requests(paths: paths).save(request)
        model.refreshBus()
        XCTAssertNotNil(model.pendingApprovals[request.id])
        return request
    }

    /// The "Approve dispatch?" banner outlived the decision it asked for.
    func testApprovingTakesTheNotificationBack() throws {
        let request = try pendingRequest()
        var withdrawn: [String] = []
        model.onDispatchResolved = { withdrawn.append($0) }
        model.approve(request.id)
        XCTAssertEqual(withdrawn, [request.id])
    }

    func testDenyingTakesTheNotificationBack() throws {
        let request = try pendingRequest()
        var withdrawn: [String] = []
        model.onDispatchResolved = { withdrawn.append($0) }
        model.deny(request.id)
        XCTAssertEqual(withdrawn, [request.id])
    }
}
