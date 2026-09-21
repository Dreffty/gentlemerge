import XCTest
@testable import GentleMergeCore

@MainActor
final class InboxDispatchModelTests: XCTestCase {
    private var paths: Paths!
    private var model: InboxModel!
    private var launched: [String] = []

    override func setUp() async throws {
        try await MainActor.run { try prepare() }
    }

    private func prepare() throws {
        paths = Paths(home: FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-model-\(UUID())"))
        try paths.createDirectories()
        model = InboxModel(paths: paths)
        launched = []
        model.runDispatch = { [unowned self] request, _ in
            self.launched.append(request.id)
            return Task {}
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            try? FileManager.default.removeItem(at: paths.home)
        }
    }

    private func request(_ id: String = "req-test", tier: String = "expensive") throws -> AgentRequest {
        model.config.agents = [AgentTarget(label: "worker", command: ["never-execute-this"], costTier: tier)]
        var request = AgentRequest(id: id, from: "planner", fromVerified: true, to: "worker",
            projectPath: paths.home.path, title: "Review", spec: "Review only", budgetMinutes: 5, state: .assigned)
        request.resolvedTo = "worker"
        try Requests(paths: paths).save(request)
        return request
    }

    func testDisabledDefaultDoesNotLaunchAndDeduplicatesSkipLedger() async throws {
        _ = try request(tier: "cheap")
        model.refreshBus()
        model.refreshBus()
        XCTAssertFalse(model.config.allowDispatch)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertEqual(model.ledgerEntries().filter { $0.title == "dispatch.skipped" }.count, 1)
    }

    func testApprovalPersistsAndNextDrainDispatchesOnlyOnce() async throws {
        let request = try request()
        model.config.allowDispatch = true
        var notices = 0
        model.onDispatchApproval = { _, _, _ in notices += 1 }
        model.refreshBus()
        model.refreshBus()
        XCTAssertEqual(notices, 1)
        XCTAssertNotNil(model.pendingApprovals[request.id])
        model.approve(request.id)
        let data = try Data(contentsOf: paths.home.appendingPathComponent("dispatch-approvals.json"))
        XCTAssertEqual(try JSONCoding.decoder().decode([String].self, from: data), [request.id])
        XCTAssertTrue(launched.isEmpty, "Approval queues; it does not bypass the gate")
        model.drainNow()
        model.refreshBus()
        XCTAssertEqual(launched, [request.id])
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertFalse(model.approvedRequestIDs.contains(request.id))
    }

    func testExternalApprovalReadAndConsumed() async throws {
        let request = try request()
        model.config.allowDispatch = true
        try AtomicFile.write(try JSONCoding.encoder().encode([request.id]),
            to: paths.home.appendingPathComponent("dispatch-approvals.json"))
        model.refreshBus()
        XCTAssertEqual(launched, [request.id])
        let data = try Data(contentsOf: paths.home.appendingPathComponent("dispatch-approvals.json"))
        XCTAssertEqual(try JSONCoding.decoder().decode([String].self, from: data), [])
    }

    func testDenyRejectsAndClearsPendingAndApproval() async throws {
        let request = try request()
        model.config.allowDispatch = true
        model.refreshBus()
        model.approve(request.id)
        model.deny(request.id)
        model.drainNow()
        XCTAssertEqual(Requests(paths: paths).load(request.id)?.state, .rejected)
        XCTAssertEqual(Requests(paths: paths).load(request.id)?.result, "denied by human")
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertTrue(model.approvedRequestIDs.isEmpty)
        XCTAssertTrue(launched.isEmpty)
    }

    func testLivePresenceBlocksEvenApprovedDispatch() async throws {
        let request = try request()
        model.config.allowDispatch = true
        Presence.record(label: "worker", project: paths.home.path, branch: nil, paths: paths, environment: [:])
        model.approve(request.id)
        model.refreshBus()
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertTrue(model.approvedRequestIDs.contains(request.id))
    }

    func testTerminalRequestDisappearsFromApprovals() async throws {
        let request = try request()
        model.config.allowDispatch = true
        model.refreshBus()
        _ = try Requests(paths: paths).transition(request.id, to: .rejected, by: "you", result: "external denial")
        model.refreshBus()
        XCTAssertTrue(model.pendingApprovals.isEmpty)
        XCTAssertTrue(launched.isEmpty)
    }

    func testMalformedApprovalStoreFailsClosedWithoutOverwritingData() async throws {
        let request = try request(tier: "cheap")
        model.config.allowDispatch = true
        let url = paths.home.appendingPathComponent("dispatch-approvals.json")
        let data = Data("not JSON".utf8)
        try data.write(to: url)
        model.refreshBus()
        model.approve(request.id)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(model.approvedRequestIDs.isEmpty)
        XCTAssertNotNil(model.lastMessage)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testRequestLogOnlyExposedWhenFileExists() async throws {
        let request = try request()
        XCTAssertNil(model.requestLogURL(for: request))
        try FileManager.default.createDirectory(at: paths.dispatch, withIntermediateDirectories: true)
        let log = paths.dispatch.appendingPathComponent("\(request.id).log")
        try Data("log".utf8).write(to: log)
        XCTAssertEqual(model.requestLogURL(for: request), log)
    }
}
