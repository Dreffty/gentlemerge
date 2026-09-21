import XCTest
@testable import GentleMergeCore

final class DispatchGateTests: XCTestCase {
    func testOnlyEligibleRequestsCanDispatch() {
        let now = Date(timeIntervalSince1970: 1000)
        let target = AgentTarget(label: "b", command: ["/usr/bin/true"], costTier: "cheap")
        let config = AppConfig(allowDispatch: true, agents: [target])
        var r = AgentRequest(from: "a", fromVerified: true, to: "b", projectPath: "/tmp", title: "test", spec: "", budgetMinutes: 15, state: .assigned)
        r.resolvedTo = "b"
        func decide(_ request: AgentRequest, live: Set<String> = [], last: [String: Date] = [:], approved: Bool = false) -> DispatchGate.Decision {
            DispatchGate.decide(request: request, config: config, liveLabels: live, lastDispatched: last, approved: approved, now: now)
        }
        XCTAssertEqual(decide(r), .dispatch(target))
        XCTAssertEqual(decide(r, live: ["b"], approved: true), .skip(reason: "b has a live session; briefing/nudge will deliver"))
        XCTAssertEqual(decide(r, last: ["b": now]), .skip(reason: "quiet period for b"))
        XCTAssertEqual(decide(r, last: ["b": now.addingTimeInterval(-300)]), .dispatch(target))
        r.fromVerified = false
        XCTAssertEqual(decide(r, approved: true), .skip(reason: "unverified requester"))
        r.fromVerified = true
        r.state = .done
        XCTAssertEqual(decide(r, approved: true), .skip(reason: "state done"))
        r.state = .assigned
        r.resolvedTo = nil
        XCTAssertEqual(decide(r), .skip(reason: "unrouted"))
        r.resolvedTo = "unknown"
        XCTAssertEqual(decide(r), .skip(reason: "no headless command for unknown"))
        r.resolvedTo = "b"
        r.budgetMinutes = 16
        XCTAssertEqual(decide(r), .needsApproval(target, reason: "budget 16m / tier cheap"))
        XCTAssertEqual(decide(r, approved: true), .dispatch(target))
    }

    func testDispatchIsOptInEvenWithApproval() {
        let request = AgentRequest(from: "a", fromVerified: true, to: "b", projectPath: "/tmp", title: "test", spec: "")
        XCTAssertEqual(DispatchGate.decide(request: request, config: AppConfig(), liveLabels: [], lastDispatched: [:], approved: true), .skip(reason: "dispatch disabled"))
    }

    func testStrictModeOnlyRunsHumanCreatedRequests() {
        let target = AgentTarget(label: "b", command: ["/usr/bin/true"], costTier: "cheap")
        let config = AppConfig(allowDispatch: true, agents: [target], dispatchMode: "strict")
        var r = AgentRequest(from: "a", fromVerified: true, to: "b", projectPath: "/tmp", title: "test", spec: "", budgetMinutes: 15, state: .assigned)
        r.resolvedTo = "b"
        XCTAssertEqual(
            DispatchGate.decide(request: r, config: config, liveLabels: [], lastDispatched: [:], approved: false),
            .needsApproval(target, reason: "strict mode: human-created or approved only")
        )
        r.from = "you"
        XCTAssertEqual(
            DispatchGate.decide(request: r, config: config, liveLabels: [], lastDispatched: [:], approved: false),
            .dispatch(target)
        )
    }

    func testDailyBudgetParksOverflowForApproval() {
        let target = AgentTarget(label: "b", command: ["/usr/bin/true"], costTier: "cheap")
        let config = AppConfig(allowDispatch: true, agents: [target], dispatchDailyBudgetMinutes: 120)
        var r = AgentRequest(from: "a", fromVerified: true, to: "b", projectPath: "/tmp", title: "test", spec: "", budgetMinutes: 15, state: .assigned)
        r.resolvedTo = "b"
        XCTAssertEqual(
            DispatchGate.decide(request: r, config: config, liveLabels: [], lastDispatched: [:], approved: false, spentTodayMinutes: 100),
            .dispatch(target)
        )
        XCTAssertEqual(
            DispatchGate.decide(request: r, config: config, liveLabels: [], lastDispatched: [:], approved: false, spentTodayMinutes: 110),
            .needsApproval(target, reason: "daily budget 120m exhausted (110m spent)")
        )
    }

    func testUnknownModeSkipsLoudly() {
        let target = AgentTarget(label: "b", command: ["/usr/bin/true"], costTier: "cheap")
        let config = AppConfig(allowDispatch: true, agents: [target], dispatchMode: "turbo")
        var r = AgentRequest(from: "a", fromVerified: true, to: "b", projectPath: "/tmp", title: "test", spec: "", budgetMinutes: 15, state: .assigned)
        r.resolvedTo = "b"
        XCTAssertEqual(
            DispatchGate.decide(request: r, config: config, liveLabels: [], lastDispatched: [:], approved: true),
            .skip(reason: "unknown dispatch mode \"turbo\" — want off, delegated or strict")
        )
    }
}
