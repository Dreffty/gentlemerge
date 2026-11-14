import XCTest
@testable import GentleMergeCore

/// What the window shows first, and how it tells two sessions apart (review D3, D4).
final class WindowOrderTests: XCTestCase {
    private func activity(_ id: String, _ state: AgentActivity.State, ago: TimeInterval = 0,
                          provider: AgentProvider = .claudeCode, branch: String? = nil) -> AgentActivity {
        AgentActivity(id: id, provider: provider, projectPath: "/x/repo",
                      updatedAt: Date(timeIntervalSinceNow: -ago), state: state, label: AgentBus.label(for: provider), branch: branch)
    }

    /// The one that is waiting on you comes first, however long ago it asked.
    func testWhatWaitsOnYouComesFirst() {
        let sorted = [activity("busy", .working), activity("done", .idle, ago: 30), activity("asks", .waiting, ago: 600)]
            .sorted(by: AgentActivity.byUrgency)
        XCTAssertEqual(sorted.map(\.id), ["asks", "done", "busy"])
    }

    func testWithinOneStateTheNewestComesFirst() {
        let sorted = [activity("old", .working, ago: 300), activity("new", .working)].sorted(by: AgentActivity.byUrgency)
        XCTAssertEqual(sorted.map(\.id), ["new", "old"])
    }

    /// Three sessions of Claude Code all read "Claude Code". The branch tells them
    /// apart; with no branch, a number in the order they started.
    func testSessionsWithOneNameAreToldApart() {
        let names = AgentActivity.distinctNames([
            activity("s-111111", .working, branch: "main"),
            activity("s-222222", .working, branch: "agent/ui"),
            activity("s-333333", .working),
            activity("cx", .working, provider: .codex),
        ])
        XCTAssertEqual(names["s-111111"], "Claude Code · on main")
        XCTAssertEqual(names["s-222222"], "Claude Code · on agent/ui")
        XCTAssertEqual(names["s-333333"], "Claude Code · 1")
        XCTAssertEqual(names["cx"], "Codex", "a name nobody shares stays as it is")
    }

    /// Session ids from the hooks can share their first letters ("claude-1",
    /// "claude-2"): the window showed two identical names.
    func testSessionsWhoseIdsLookAlikeAreNumbered() {
        let names = AgentActivity.distinctNames([activity("claude-2", .working, ago: 0),
                                                 activity("claude-1", .waiting, ago: 60)])
        XCTAssertNotEqual(names["claude-1"], names["claude-2"])
    }

    func testTwoOnTheSameBranchStillDiffer() {
        let names = AgentActivity.distinctNames([activity("a-123456", .working, branch: "main"),
                                                 activity("b-654321", .working, branch: "main")])
        XCTAssertNotEqual(names["a-123456"], names["b-654321"])
    }

    @MainActor
    func testTheModelListsThemByUrgency() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try paths.createDirectories()
        AgentBus(paths: paths).save([activity("busy", .working), activity("asks", .waiting, ago: 900)])
        XCTAssertEqual(InboxModel(paths: paths).liveActivities.map(\.id), ["asks", "busy"])
    }
}
