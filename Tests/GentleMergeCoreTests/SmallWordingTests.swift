import XCTest
@testable import GentleMergeCore

/// Small things a person reads every day.
final class SmallWordingTests: XCTestCase {
    /// GM-11: "1 briefings".
    func testOneBriefingIsSingular() {
        XCTAssertEqual(Stats.Summary(turns: 1, nonEmpty: 1, chars: 400).costLine, "1 briefing · ≈100 tokens (estimate)")
        XCTAssertEqual(Stats.Summary(turns: 3, nonEmpty: 3, chars: 1200).costLine, "3 briefings · ≈300 tokens (estimate)")
    }

    /// GM-12: the branch came out in the quotation marks that mean "what you asked
    /// this session for": “on main”, as if somebody had typed it.
    func testABranchIsNotQuotedAsIfSomebodySaidIt() {
        let quiet = AgentActivity(id: "a", provider: .claudeCode, projectPath: "/x/repo", label: "claude", branch: "main")
        let line = quiet.briefingLine()
        XCTAssertFalse(line.contains("“on main”"), line)
        XCTAssertTrue(line.contains("on main"), line)

        var busy = quiet
        busy.currentTask = "arregla el parser"
        XCTAssertTrue(busy.briefingLine().contains("on main — “arregla el parser”"), busy.briefingLine())
    }

    func testAMarkKeepsTheBranchApartFromTheTask() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try paths.createDirectories()
        Presence.record(label: "codex", project: "/x/repo", branch: "agent/codex", task: nil,
                        pid: Int(ProcessInfo.processInfo.processIdentifier), paths: paths)

        let activity = try XCTUnwrap(AgentBus(paths: paths).activities().first { $0.isLive })
        XCTAssertNil(activity.currentTask)
        XCTAssertEqual(activity.branch, "agent/codex")
    }
}
