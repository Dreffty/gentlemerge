import XCTest
@testable import GentleMergeCore

/// "Avísame antes de tocar X" was a convention held up by good faith. These are
/// the properties that turn it into something an agent can actually check —
/// without any of them turning into a lock.
final class TaskClaimsTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var paths: Paths!
    private var claims: TaskClaims!
    private var bus: AgentBus!

    private let translate = TaskItem(text: "Translate constants to EN", addedBy: "you")
    private let rewards = TaskItem(text: "Fix broken tree rewards", addedBy: "you")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-claims-\(UUID().uuidString)")
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-claimed-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        paths = Paths(home: root)
        try paths.createDirectories()
        claims = TaskClaims(paths: paths)
        bus = AgentBus(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: project)
    }

    private var here: String { project.path }

    /// A pid nothing is behind any more — real, because a number picked out of
    /// the air could belong to somebody else's live process.
    private func pidOfAProcessThatIsGone() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let pid = Int(process.processIdentifier)
        process.waitUntilExit()
        return pid
    }

    // MARK: - Taking a task and giving it back

    func testClaimingATaskAndGivingItBack() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "claude"))

        let held = try XCTUnwrap(claims.active(for: here)[translate.id])
        XCTAssertEqual(held.claimedBy, "claude")
        XCTAssertEqual(held.projectPath, here)

        XCTAssertNotNil(try claims.release(translate.id, in: here, by: "claude"))
        XCTAssertTrue(claims.active(for: here).isEmpty)

        // And now it is somebody else's to take.
        XCTAssertNil(try claims.claim(translate, in: here, by: "codex"))
        XCTAssertEqual(claims.active(for: here)[translate.id]?.claimedBy, "codex")
    }

    func testTheSecondAgentIsToldWhoHasItAndSinceWhen() throws {
        let ago = Date().addingTimeInterval(-40 * 60)
        XCTAssertNil(try claims.claim(translate, in: here, by: "codex", now: ago))

        let blocking = try XCTUnwrap(
            try claims.claim(translate, in: here, by: "claude"),
            "a task somebody live is on is not free to take"
        )
        XCTAssertEqual(blocking.claimedBy, "codex")
        XCTAssertTrue(blocking.conflictLine().contains("claimed by codex 40m ago"))
        XCTAssertTrue(blocking.conflictLine().contains("talk to them or wait"))

        // The loser of the race changed nothing: codex still has it.
        XCTAssertEqual(claims.active(for: here)[translate.id]?.claimedBy, "codex")
    }

    func testTwoAgentsOnDifferentTasksNeverCollide() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "claude"))
        XCTAssertNil(try claims.claim(rewards, in: here, by: "codex"))
        XCTAssertEqual(claims.claims(for: here).count, 2)
    }

    func testTheSameTaskInAnotherProjectIsAnotherTaskEntirely() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "claude"))
        XCTAssertNil(try claims.claim(translate, in: "/tmp/clipapp", by: "codex"))
        XCTAssertEqual(claims.active(for: here)[translate.id]?.claimedBy, "claude")
    }

    func testReclaimingYourOwnRefreshesTheClockInsteadOfConflicting() throws {
        let ago = Date().addingTimeInterval(-90 * 60)
        XCTAssertNil(try claims.claim(translate, in: here, by: "claude", now: ago))
        XCTAssertNil(
            try claims.claim(translate, in: here, by: "claude"),
            "an agent still working at the ninety minute mark must not be told it lost its own task"
        )
        XCTAssertEqual(claims.claims(for: here).count, 1)
        XCTAssertGreaterThan(claims.claims(for: here)[0].claimedAt, ago)
    }

    func testASubagentSharesItsParentsClaim() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "claude"))
        XCTAssertNil(
            try claims.claim(translate, in: here, by: "claude#exec1"),
            "a subagent works on its parent's behalf; making them fight over a task would be a bug"
        )
    }

    func testReleasingSomebodyElsesClaimDoesNothing() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "codex"))
        XCTAssertNil(try claims.release(translate.id, in: here, by: "claude"))
        XCTAssertEqual(claims.active(for: here)[translate.id]?.claimedBy, "codex")
    }

    func testFinishingATaskEndsEveryClaimOnIt() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "codex"))
        XCTAssertEqual(try claims.releaseAll(translate.id, in: here).count, 1)
        XCTAssertTrue(claims.active(for: here).isEmpty)
    }

    // MARK: - Lapsing

    func testAClaimLapsesAfterTwoHours() throws {
        let old = Date().addingTimeInterval(-(TaskClaims.lifetime + 60))
        XCTAssertNil(try claims.claim(translate, in: here, by: "codex", now: old))

        XCTAssertTrue(claims.isStale(claims.claims(for: here)[0], bus: bus))
        XCTAssertTrue(claims.active(for: here).isEmpty, "a lapsed claim is not annotated anywhere")
        XCTAssertNil(
            try claims.claim(translate, in: here, by: "claude"),
            "nobody has to clean up after an agent that walked away"
        )
    }

    func testAClaimDiesWithTheSessionThatMadeIt() throws {
        var session = AgentActivity(id: "claude-1", provider: .claudeCode, projectPath: here)
        session.pid = try pidOfAProcessThatIsGone()
        bus.save([session])

        // Made seconds ago: the clock says it stands, the kernel says otherwise.
        XCTAssertNil(try claims.claim(translate, in: here, by: "claude", sessionID: "claude-1"))
        XCTAssertTrue(claims.isStale(claims.claims(for: here)[0], bus: bus))
        XCTAssertTrue(claims.active(for: here).isEmpty)
        XCTAssertNil(
            try claims.claim(translate, in: here, by: "codex"),
            "a session killed by a 529 cannot hold a task hostage"
        )
        XCTAssertEqual(claims.active(for: here)[translate.id]?.claimedBy, "codex")
    }

    func testALiveSessionKeepsItsClaimPastTheTwoHours() throws {
        var session = AgentActivity(id: "claude-1", provider: .claudeCode, projectPath: here)
        session.pid = Int(getpid())
        bus.save([session])

        let old = Date().addingTimeInterval(-(TaskClaims.lifetime + 3600))
        XCTAssertNil(
            try claims.claim(translate, in: here, by: "claude", sessionID: "claude-1", now: old)
        )
        XCTAssertFalse(
            claims.isStale(claims.claims(for: here)[0], bus: bus),
            "three hours on one task is a long piece of work, not an abandoned one"
        )
        XCTAssertEqual(
            try claims.claim(translate, in: here, by: "codex")?.claimedBy,
            "claude"
        )
    }

    func testASessionWeKnowNothingAboutOnlyEverLapsesOnTheClock() throws {
        // Hermes is one-shot and leaves no activity behind. Not knowing whether
        // it is alive must never be read as knowing it is dead.
        XCTAssertNil(try claims.claim(translate, in: here, by: "hermes"))
        XCTAssertFalse(claims.isStale(claims.claims(for: here)[0], bus: bus))
    }

    // MARK: - The announcement

    func testAGrantedClaimIsAnnouncedInTheProjectItWasMadeIn() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "claude"))

        let posted = try XCTUnwrap(bus.messages().last)
        XCTAssertEqual(posted.from, "claude")
        XCTAssertEqual(posted.projectPath, here, "the agents in other projects must not pay for this")
        XCTAssertEqual(posted.effectiveKind, .update)
        XCTAssertEqual(posted.text, "claimed: Translate constants to EN")

        // An agent in another project hears nothing about it.
        XCTAssertNil(bus.briefing(sessionID: "codex-1", me: "codex", project: "/tmp/clipapp"))
    }

    func testALostRaceIsNotAnnounced() throws {
        XCTAssertNil(try claims.claim(translate, in: here, by: "codex"))
        XCTAssertNotNil(try claims.claim(translate, in: here, by: "claude"))
        XCTAssertEqual(bus.messages().count, 1, "only the agent that got it says so")
    }

    // MARK: - What must not change

    /// The golden one. Claims stay out of the handoff because a metadata suffix
    /// an older binary does not recognise stays inside the task text — and the
    /// id is derived from that text, so the task would come back as two.
    func testTheHandoffFileIsByteIdenticalAfterAClaim() throws {
        var handoff = ProjectHandoff(projectPath: here, projectName: "gameapp")
        handoff.tasks = [translate, rewards]
        XCTAssertTrue(ProjectRegistry.save(handoff))

        let fileURL = ProjectHandoff.fileURL(for: here)
        let before = try Data(contentsOf: fileURL)

        XCTAssertNil(try claims.claim(translate, in: here, by: "claude"))
        XCTAssertNotNil(try claims.release(translate.id, in: here, by: "claude"))

        XCTAssertEqual(try Data(contentsOf: fileURL), before)

        // And the task list read back is still two tasks with the same ids.
        let reread = ProjectRegistry.handoff(for: here, refreshingCommits: false)
        XCTAssertEqual(reread.tasks.map(\.id), [translate.id, rewards.id])
    }

    func testNoClaimsFileMeansNobodyHasClaimedAnything() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.claims.path))
        XCTAssertTrue(claims.claims(for: here).isEmpty)
        XCTAssertTrue(claims.active(for: here).isEmpty)
    }

    // MARK: - Where an agent actually reads it

    func testTheBriefingSaysWhoIsAlreadyOnATask() throws {
        var handoff = ProjectHandoff(projectPath: here, projectName: "gameapp")
        handoff.tasks = [translate, rewards]
        XCTAssertTrue(ProjectRegistry.save(handoff))

        XCTAssertNil(try claims.claim(translate, in: here, by: "codex", now: Date().addingTimeInterval(-2400)))

        let context = try XCTUnwrap(
            ProjectRegistry.sessionContext(
                for: here,
                refreshingMap: false,
                claims: claims.active(for: here)
            )
        )
        XCTAssertTrue(context.contains("- Translate constants to EN (from you) · claimed by codex (40m)"))
        XCTAssertFalse(context.contains("Fix broken tree rewards · claimed"))
        XCTAssertTrue(context.contains("talk to them rather than doubling up"))
    }

    func testABriefingWithNothingClaimedSaysNothingAboutClaims() throws {
        var handoff = ProjectHandoff(projectPath: here, projectName: "gameapp")
        handoff.tasks = [translate]
        XCTAssertTrue(ProjectRegistry.save(handoff))

        let context = try XCTUnwrap(
            ProjectRegistry.sessionContext(for: here, refreshingMap: false, claims: claims.active(for: here))
        )
        XCTAssertFalse(context.contains("claimed"), "a rule nobody needs today teaches the reader to skim")
    }
}
