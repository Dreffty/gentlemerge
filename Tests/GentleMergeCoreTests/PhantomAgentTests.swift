import XCTest
@testable import GentleMergeCore

/// "Other agents you have running right now" listed agents that were not
/// there (2026-10-21), four different ways. Each test is one of them, built
/// from the mark that was actually on disk that day.
final class PhantomAgentTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var bus: AgentBus!
    private let project = "/tmp/side-projects"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-phantom-\(UUID().uuidString)")
        paths = Paths(home: root)
        try paths.createDirectories()
        bus = AgentBus(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeMark(_ mark: Presence.Mark) throws {
        try FileManager.default.createDirectory(at: paths.presence, withIntermediateDirectories: true)
        try AtomicFile.write(try JSONCoding.encoder().encode(mark), to: Presence.fileURL(for: mark, in: paths))
    }

    /// A process that is certainly alive for the length of the test and is not
    /// this one — standing in for a second agent.
    private func otherLivePID() throws -> (pid: Int, stop: () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return (Int(process.processIdentifier), { process.terminate(); process.waitUntilExit() })
    }

    // MARK: 1 — the session reading the briefing is listed as somebody else

    /// The mark on disk had the reader's own pid and its label was not the one
    /// the reader resolved to, so the label check let it through:
    /// "Claude Code · Side Projects (just now, working)" — itself.
    func testTheReaderIsNotListedByItsOwnPid() {
        let me = Int(getpid())
        Presence.record(label: "claude", project: project, branch: nil, pid: me,
                        paths: paths, environment: [:])

        let (here, elsewhere) = bus.peers(excluding: "session-a", project: project,
                                          me: "claude-worktree", selfPID: me)
        XCTAssertTrue(here.isEmpty, "the reader was told about itself: \(here.map(\.id))")
        XCTAssertEqual(elsewhere, 0)
    }

    func testTheReaderIsNotListedByItsOwnSessionID() {
        Presence.record(label: "claude", project: project, branch: nil, sessionID: "session-a",
                        paths: paths, environment: [:])

        let (here, _) = bus.peers(excluding: "session-a", project: project, me: "someone-else")
        XCTAssertTrue(here.isEmpty, "the reader was told about itself: \(here.map(\.id))")
    }

    /// The other half of the same fix: a second session sharing the label is
    /// not the reader, and the pids prove it.
    func testAnotherSessionWithTheSameLabelIsStillListed() throws {
        let other = try otherLivePID()
        defer { other.stop() }
        Presence.record(label: "claude", project: project, branch: nil, pid: other.pid,
                        paths: paths, environment: [:])

        let (here, _) = bus.peers(excluding: "session-a", project: project,
                                  me: "claude", selfPID: Int(getpid()))
        XCTAssertEqual(here.map(\.pid), [other.pid])
    }

    /// End to end through the briefing, as the hook calls it.
    func testTheBriefingDoesNotListTheSessionReadingIt() {
        let me = Int(getpid())
        Presence.record(label: "claude", project: project, branch: nil, pid: me,
                        sessionID: "session-a", paths: paths, environment: [:])

        let text = bus.briefing(sessionID: "session-a", me: "claude-other", project: project,
                                persistCursor: false, selfPID: me) ?? ""
        XCTAssertFalse(text.contains("Other agents you have running right now"), text)
    }

    /// A session's own tool calls know neither its pid nor (outside Claude
    /// Code) its session — and must not knock out what the hook recorded.
    func testAToolCallKeepsThePidItsHookRecorded() throws {
        let me = Int(getpid())
        Presence.record(label: "claude", project: project, branch: nil, pid: me,
                        paths: paths, environment: [:])
        Presence.record(label: "claude", project: project, branch: nil,
                        paths: paths, environment: [:])

        XCTAssertEqual(Presence.marks(paths: paths).map(\.pid), [me])
    }

    // MARK: 2 — a one-off CLI command counts as an agent working

    /// `say` / `task add` from a shell left a mark with no pid and no session,
    /// and it was "working" in every briefing for half an hour.
    func testAOneOffCommandIsForgottenWithinMinutes() throws {
        Presence.record(label: "you", project: project, branch: "claude/auditoria",
                        paths: paths, environment: [:],
                        now: Date().addingTimeInterval(-Presence.looseTimeToLive - 1))
        XCTAssertTrue(Presence.live(paths: paths).isEmpty)
        XCTAssertTrue(bus.peers(excluding: nil, project: nil).here.isEmpty)
    }

    func testAOneOffCommandMarkIsPrunedNotJustHidden() throws {
        try writeMark(Presence.Mark(label: "you", projectPath: project, branch: "main",
                                    updatedAt: Date().addingTimeInterval(-Presence.looseTimeToLive - 1),
                                    pid: nil, task: nil))
        XCTAssertEqual(Presence.prune(paths: paths), 1)
    }

    /// A session's mark is still believed for the full half hour.
    func testASessionMarkKeepsTheFullWindow() throws {
        try writeMark(Presence.Mark(label: "claude", projectPath: project, branch: nil,
                                    updatedAt: Date().addingTimeInterval(-10 * 60),
                                    pid: nil, task: nil, sessionID: "session-b"))
        XCTAssertEqual(Presence.live(paths: paths).count, 1)
    }

    // MARK: 3 — an app idling in `/` or the home folder

    func testAMarkInTheRootFolderIsNobodyWorking() throws {
        try writeMark(Presence.Mark(label: "codex", projectPath: "/", branch: nil,
                                    updatedAt: Date(), pid: nil, task: nil, sessionID: "codex-app"))
        XCTAssertTrue(Presence.live(paths: paths).isEmpty)
    }

    func testAMarkInTheHomeFolderIsNobodyWorking() throws {
        try writeMark(Presence.Mark(label: "codex", projectPath: NSHomeDirectory(), branch: nil,
                                    updatedAt: Date(), pid: nil, task: nil, sessionID: "codex-app"))
        XCTAssertTrue(Presence.live(paths: paths).isEmpty)
    }

    func testNoMarkIsEvenWrittenForTheRootFolder() {
        Presence.record(label: "codex", project: "/", branch: nil, paths: paths)
        XCTAssertTrue(Presence.marks(paths: paths).isEmpty)
    }

    /// The app's own record of a session in `/` is filtered the same way.
    func testAnActivityInTheRootFolderIsNotAPeer() {
        bus.save([AgentActivity(id: "codex-app", provider: .codex, projectPath: "/")])
        XCTAssertTrue(bus.others(excluding: nil).isEmpty)
    }

    func testOnlyRootAndHomeCountAsNoProject() {
        XCTAssertTrue(Presence.isNoProject("/"))
        XCTAssertTrue(Presence.isNoProject("/Users/luis", home: "/Users/luis"))
        XCTAssertTrue(Presence.isNoProject("/Users/luis/", home: "/Users/luis"))
        XCTAssertFalse(Presence.isNoProject("/Users/luis/app", home: "/Users/luis"))
        XCTAssertFalse(Presence.isNoProject(nil))
    }

    // MARK: 4 — marks from September still on disk

    /// Reads ignored them, but nothing ever deleted them unless somebody ran
    /// `compact` by hand. Every write now sweeps the directory.
    func testRecordingSweepsMarksPastTheirTTL() throws {
        try writeMark(Presence.Mark(label: "claude", projectPath: "/tmp/rpg", branch: "feature/tipos-habito",
                                    updatedAt: Date().addingTimeInterval(-40 * 86_400),
                                    pid: nil, task: nil))
        Presence.record(label: "claude", project: project, branch: nil, paths: paths)

        XCTAssertEqual(Presence.marks(paths: paths).map(\.projectPath), [project])
    }

    func testLeftoverTempFilesAreSwept() throws {
        try FileManager.default.createDirectory(at: paths.presence, withIntermediateDirectories: true)
        let leftover = paths.presence.appendingPathComponent(".tmp-0ECBFC9A")
        try Data("{".utf8).write(to: leftover)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-22 * 86_400)], ofItemAtPath: leftover.path)

        XCTAssertEqual(Presence.prune(paths: paths), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }
}
