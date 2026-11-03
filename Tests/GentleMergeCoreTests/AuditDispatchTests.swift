import XCTest
@testable import GentleMergeCore

/// One delegated request used to start the headless agent once per *process* that
/// drained the spool: three read commands, three children, three charges against the
/// daily budget.
@MainActor
final class DispatchOncePerRequestTests: XCTestCase {
    private var paths: Paths!
    private var marker: URL!

    override func setUp() async throws {
        try await MainActor.run { try prepare() }
    }

    private func prepare() throws {
        paths = Paths(home: FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-once-\(UUID())"))
        try paths.createDirectories()
        marker = paths.home.appendingPathComponent("child-ran")
        var config = AppConfig()
        config.allowDispatch = true
        config.dispatchAutoApproveTiers = ["cheap"]
        config.agents = [AgentTarget(
            label: "worker",
            command: ["/bin/sh", "-c", "echo ran >> '\(marker.path)'"],
            costTier: "cheap")]
        try config.save(to: paths.config)
        var request = AgentRequest(id: "req-once", from: "planner", fromVerified: true, to: "worker",
            projectPath: paths.home.path, title: "Do it", spec: "once", budgetMinutes: 5, state: .assigned)
        request.resolvedTo = "worker"
        try Requests(paths: paths).save(request)
    }

    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: paths.home) }
    }

    private func startedLines() -> Int {
        InboxModel(paths: paths).ledgerEntries(limit: 500).filter { $0.title == "dispatch.start" }.count
    }

    /// The CLI and the MCP server drain before every read, in a process that exits at
    /// once. Starting an agent there left it with nobody to record how it ended.
    func testAOneShotDrainNeverStartsAHeadlessAgent() throws {
        for _ in 0..<3 { InboxModel.drainHeadless(paths: paths) }
        XCTAssertEqual(startedLines(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.dispatch.appendingPathComponent("req-once.started").path))
    }

    /// And the app itself, restarted (or a second app), must not start it again.
    func testASecondModelOverTheSameHomeDoesNotRestartTheRequest() throws {
        var launched: [String] = []
        let first = InboxModel(paths: paths)
        first.runDispatch = { request, _ in launched.append(request.id); return Task {} }
        first.refreshBus()
        XCTAssertEqual(launched, ["req-once"])

        let second = InboxModel(paths: paths)
        second.runDispatch = { request, _ in launched.append(request.id); return Task {} }
        second.refreshBus()
        second.refreshBus()
        XCTAssertEqual(launched, ["req-once"], "the request was started again by another process")
    }

    func testTheMarkerIsTakenExactlyOnce() {
        let dispatcher = Dispatcher(paths: paths)
        XCTAssertTrue(dispatcher.claimStart(of: "req-x"))
        XCTAssertFalse(dispatcher.claimStart(of: "req-x"))
        XCTAssertFalse(dispatcher.claimStart(of: "../escape"), "ids are validated before they reach a path")
    }

    func testOldMarkersAreSweptWithTheOtherDispatchDebris() throws {
        _ = Dispatcher(paths: paths).claimStart(of: "req-old")
        let url = paths.dispatch.appendingPathComponent("req-old.started")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)],
                                              ofItemAtPath: url.path)
        XCTAssertEqual(Retention.pruneDispatch(paths: paths, olderThanDays: 30), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class DispatchModeOffTests: XCTestCase {
    /// "off" is offered by the CLI, the Settings picker and the docs; the gate called
    /// it an unknown mode.
    func testOffIsARealModeAndSaysSo() {
        var config = AppConfig()
        config.allowDispatch = true
        config.dispatchMode = "off"
        config.agents = [AgentTarget(label: "w", command: ["x"], costTier: "cheap")]
        var request = AgentRequest(id: "req-1", from: "p", fromVerified: true, to: "w",
            projectPath: "/p", title: "t", spec: "s", budgetMinutes: 5, state: .assigned)
        request.resolvedTo = "w"
        let decision = DispatchGate.decide(request: request, config: config, liveLabels: [],
                                           lastDispatched: [:], approved: true)
        XCTAssertEqual(decision, .skip(reason: "dispatch mode is off"))
    }
}
