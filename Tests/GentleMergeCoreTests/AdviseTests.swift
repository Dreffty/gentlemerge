import XCTest
@testable import GentleMergeCore

/// The PreToolUse answer decides before the edit lands, with the same rules
/// as the commit-time gate: a surprise at commit time is twenty minutes of
/// wasted work. Pure matrix, no disk.
final class AdviseTests: XCTestCase {
    private let now = Date()
    private let ownership = Ownership(rules: [.init(pattern: "assets/**", owner: "codex")])

    private func claim(_ label: String, _ pattern: String, implicit: Bool = false,
                       ttl: TimeInterval = 600) -> PathClaim {
        PathClaim(label: label, projectPath: "/p", pattern: pattern, intent: "migrating",
                  since: now, expires: now.addingTimeInterval(ttl), implicit: implicit)
    }

    private func mark(_ label: String, pid: Int? = nil, updatedMinutesAgo: Double = 0) -> Presence.PresenceMark {
        Presence.PresenceMark(label: label, projectPath: "/p", branch: nil,
            updatedAt: now.addingTimeInterval(-updatedMinutesAgo * 60),
            pid: pid, task: nil, capabilities: [])
    }

    private func request(mayTouch: [String]) -> AgentRequest {
        AgentRequest(id: "req-test", from: "claude", fromVerified: true, to: "codex",
            projectPath: "/p", title: "t", spec: "s", mayTouch: mayTouch)
    }

    func testAnotherAgentsClaimWarnsWithACoordinateLine() {
        let notes = Advise.check(path: "lib/a.swift", me: "codex",
            claims: [claim("claude", "lib/**")], ownership: ownership, now: now)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].denies)
        XCTAssertTrue(notes[0].text.contains("claude"), notes[0].text)
        XCTAssertTrue(notes[0].text.contains("say --to claude"), notes[0].text)
    }

    func testADeadOwnersClaimIsSilent() {
        let notes = Advise.check(path: "lib/a.swift", me: "codex",
            claims: [claim("claude", "lib/**")], ownership: ownership, now: now,
            presence: [mark("claude", pid: 9)], isPIDAlive: { _ in false })
        XCTAssertTrue(notes.isEmpty, "reaped before the edit, not at the commit")
    }

    func testAnUnknownOwnerKeepsTheWarning() {
        let notes = Advise.check(path: "lib/a.swift", me: "codex",
            claims: [claim("claude", "lib/**")], ownership: ownership, now: now,
            presence: [], isPIDAlive: { _ in nil })
        XCTAssertEqual(notes.count, 1, "unknown is never dead")
    }

    func testAnOwnershipZoneWithoutAClaimOnlyWarns() {
        let notes = Advise.check(path: "assets/x.png", me: "claude",
            claims: [], ownership: ownership, now: now)
        XCTAssertEqual(notes.count, 1)
        XCTAssertFalse(notes[0].denies, "a zone is a default, not a decision")
    }

    func testMyExplicitClaimSilencesTheZone() {
        let notes = Advise.check(path: "assets/x.png", me: "claude",
            claims: [claim("claude", "assets/**")], ownership: ownership, now: now)
        XCTAssertTrue(notes.isEmpty)
    }

    func testMyImplicitClaimDoesNotSilenceTheZone() {
        let notes = Advise.check(path: "assets/x.png", me: "claude",
            claims: [claim("claude", "assets/**", implicit: true)], ownership: ownership, now: now)
        XCTAssertEqual(notes.count, 1, "history is not a decision")
    }

    func testOutsideTheDelegatedScopeDenies() {
        let notes = Advise.check(path: "lib/a.swift", me: "codex",
            claims: [], ownership: ownership, activeRequest: request(mayTouch: ["docs/**"]), now: now)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].denies)
        XCTAssertTrue(notes[0].text.contains("req-test"), notes[0].text)
    }

    func testInsideTheDelegatedScopeIsSilent() {
        let notes = Advise.check(path: "docs/a.md", me: "codex",
            claims: [], ownership: ownership, activeRequest: request(mayTouch: ["docs/**"]), now: now)
        XCTAssertTrue(notes.isEmpty)
    }

    func testAnUnscopedRequestConstrainsNothing() {
        let notes = Advise.check(path: "lib/a.swift", me: "codex",
            claims: [], ownership: ownership, activeRequest: request(mayTouch: []), now: now)
        XCTAssertTrue(notes.isEmpty)
    }

    func testAnExpiredClaimIsSilent() {
        let notes = Advise.check(path: "lib/a.swift", me: "codex",
            claims: [claim("claude", "lib/**", ttl: -1)], ownership: ownership, now: now)
        XCTAssertTrue(notes.isEmpty)
    }

    // MARK: - The rejection is a plan, not a complaint

    func testARejectionNamesHolderExpiryAndThreeMoves() {
        let holder = claim("hermes", "lib/**")
        let plan = ClaimRejection.plan(holder: holder, path: "lib/a.swift", now: now)
        XCTAssertTrue(plan.contains("lib/a.swift"), plan)
        XCTAssertTrue(plan.contains("hermes"), plan)
        XCTAssertTrue(plan.contains("10m"), plan) // 600s TTL
        XCTAssertTrue(plan.contains("(a)"), plan)
        XCTAssertTrue(plan.contains("git reset lib/a.swift"), plan)
        XCTAssertTrue(plan.contains("(c)"), plan)
    }

    func testARejectionWithoutIntentStillReads() {
        var holder = claim("hermes", "lib/**")
        holder.intent = nil
        let plan = ClaimRejection.plan(holder: holder, path: "lib/a.swift", now: now)
        XCTAssertTrue(plan.contains("claimed by hermes"), plan)
    }

    func testConflictDescriptionIsTheSamePlan() {
        let conflict = PathClaimConflict(pattern: "lib/**", holders: [claim("hermes", "lib/**")])
        XCTAssertTrue(conflict.description.contains("Next:"), conflict.description)
    }
}
