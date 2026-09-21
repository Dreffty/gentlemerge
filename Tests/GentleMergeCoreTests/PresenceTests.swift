import XCTest
@testable import GentleMergeCore

/// `who` said "No agent sessions running." while five of them were mid-turn,
/// because presence was only ever written by the menu bar app and the app had
/// not been opened in five days. Nothing errored; the list was simply empty,
/// which is the worst way for a collision channel to be wrong.
final class PresenceTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var bus: AgentBus!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-presence-\(UUID().uuidString)")
        paths = Paths(home: root)
        try paths.createDirectories()
        bus = AgentBus(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeMark(_ mark: Presence.Mark) throws {
        try FileManager.default.createDirectory(at: paths.presence, withIntermediateDirectories: true)
        try AtomicFile.write(
            try JSONCoding.encoder().encode(mark),
            to: Presence.fileURL(for: mark, in: paths)
        )
    }

    /// A pid that certainly belongs to nobody: run something, wait for it to
    /// finish, and keep the number it used.
    private func deadPID() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["gone"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return Int(process.processIdentifier)
    }

    // MARK: - The failure itself

    func testAnAgentThatLeftAMarkIsVisibleWithNoAppRunning() {
        Presence.record(label: "claude", project: "/tmp/gameapp", branch: "feature/x", paths: paths)

        let live = bus.activities().filter(\.isLive)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.projectName, "gameapp")
        XCTAssertEqual(live.first?.currentTask, "on feature/x")
    }

    func testWithoutAMarkNobodyIsClaimedToBeWorking() {
        XCTAssertTrue(bus.activities().isEmpty)
    }

    // MARK: - What a mark is worth

    func testAMarkFromLastNightIsNotSomebodyWorkingThisMorning() throws {
        try writeMark(
            Presence.Mark(
                label: "claude",
                projectPath: "/tmp/gameapp",
                branch: "main",
                updatedAt: Date().addingTimeInterval(-Presence.timeToLive - 60),
                pid: Int(getpid()),
                task: nil
            )
        )
        XCTAssertTrue(Presence.live(paths: paths).isEmpty)
    }

    func testAMarkWhoseProcessIsGoneIsNotSomebodyWorking() throws {
        try writeMark(
            Presence.Mark(
                label: "claude",
                projectPath: "/tmp/gameapp",
                branch: "main",
                updatedAt: Date(),
                pid: try deadPID(),
                task: nil
            )
        )
        XCTAssertTrue(Presence.live(paths: paths).isEmpty)
    }

    /// The regression that made the first version of this useless: the CLI runs
    /// from a tool call, its parent shell exits the instant the command returns,
    /// and recording that shell as "the agent" buried every mark within a
    /// second of writing it. `who` then answered "nobody is working" — the
    /// exact failure this file exists to fix, reintroduced from the other side.
    func testAMarkOutlivesTheShellThatWroteIt() throws {
        Presence.record(
            label: "claude",
            project: "/tmp/gameapp",
            branch: "main",
            paths: paths,
            environment: [:]
        )
        let mark = try XCTUnwrap(Presence.live(paths: paths).first)
        XCTAssertNil(mark.pid, "nothing here knows the agent's pid, and guessing is how it broke")
        XCTAssertEqual(Presence.live(paths: paths).count, 1)
    }

    /// A caller that genuinely knows — the hook, whose parent really is the
    /// agent — says so, and then the check is worth making.
    func testACallerThatKnowsThePidHasItRecorded() throws {
        Presence.record(
            label: "claude",
            project: "/tmp/gameapp",
            branch: "main",
            paths: paths,
            environment: [Presence.pidEnvironmentKey: String(getpid())]
        )
        XCTAssertEqual(Presence.live(paths: paths).first?.pid, Int(getpid()))
    }

    /// nil is "we cannot tell", and burying somebody on that would put us back
    /// where we started.
    func testAMarkWithNoProcessToCheckIsBelieved() throws {
        try writeMark(
            Presence.Mark(
                label: "hermes",
                projectPath: "/tmp/gameapp",
                branch: nil,
                updatedAt: Date(),
                pid: nil,
                task: "traduciendo"
            )
        )
        XCTAssertEqual(Presence.live(paths: paths).count, 1)
    }

    // MARK: - Identity

    func testTheSameAgentOnTheSameBranchIsOneEntryHoweverOftenItSpeaks() {
        for _ in 0..<5 {
            Presence.record(label: "claude", project: "/tmp/gameapp", branch: "main", paths: paths)
        }
        XCTAssertEqual(Presence.live(paths: paths).count, 1)
    }

    /// The reason this is keyed on the branch: since every worktree of a
    /// repository became one project, the branch is what tells two agents apart.
    func testTwoWorktreesOfOneProjectAreTwoAgents() {
        Presence.record(label: "claude", project: "/tmp/gameapp", branch: "main", paths: paths)
        Presence.record(label: "claude", project: "/tmp/gameapp", branch: "feature/x", paths: paths)

        XCTAssertEqual(Presence.live(paths: paths).count, 2)
    }

    func testTwoModelsInOneProjectAreTwoAgents() {
        Presence.record(label: "claude", project: "/tmp/gameapp", branch: "main", paths: paths)
        Presence.record(label: "codex", project: "/tmp/gameapp", branch: "main", paths: paths)

        XCTAssertEqual(Presence.live(paths: paths).count, 2)
    }

    // MARK: - Living alongside the app

    /// The app sees every hook event, so it knows about waiting and ended while
    /// a mark only ever says "working". Where both describe the same agent, the
    /// app is the better witness.
    func testTheAppsRecordWinsOverAMarkForTheSameAgent() {
        Presence.record(label: "claude", project: "/tmp/gameapp", branch: "main", paths: paths)
        let mine = try? XCTUnwrap(Presence.live(paths: paths).first)
        guard let id = mine?.id else { return XCTFail("no mark") }

        bus.save([
            AgentActivity(
                id: id,
                provider: .claudeCode,
                projectPath: "/tmp/gameapp",
                currentTask: "lo que dice la app",
                state: .waiting
            )
        ])

        let live = bus.activities().filter(\.isLive)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.state, .waiting)
        XCTAssertEqual(live.first?.currentTask, "lo que dice la app")
    }

    func testAnAgentTheAppNeverSawIsAddedRatherThanReplacing() {
        bus.save([
            AgentActivity(id: "app-1", provider: .codex, projectPath: "/tmp/gameapp", currentTask: "migración")
        ])
        Presence.record(label: "claude", project: "/tmp/gameapp", branch: "main", paths: paths)

        let live = bus.activities().filter(\.isLive)
        XCTAssertEqual(live.count, 2)
        XCTAssertTrue(live.contains { $0.currentTask == "migración" })
        XCTAssertTrue(live.contains { $0.currentTask == "on main" })
    }
}
