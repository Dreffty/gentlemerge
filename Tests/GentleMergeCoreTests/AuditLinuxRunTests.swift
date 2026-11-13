import Foundation
import XCTest
@testable import GentleMergeCore

// What the first full run of this suite on Linux turned up (audit 2026-11-13),
// and what a pass over the command line with blank and half-given arguments did.

/// A claim outlives a dead sibling of its owner.
final class ReapingSeveralMarksTests: XCTestCase {
    private let now = Date()
    private func claim(_ label: String) -> PathClaim {
        PathClaim(label: label, projectPath: "/p", pattern: "lib/**", intent: nil,
                  since: now, expires: now.addingTimeInterval(600), implicit: false)
    }
    private func mark(_ label: String, pid: Int?, branch: String? = nil,
                      updatedMinutesAgo: Double = 0) -> Presence.PresenceMark {
        Presence.PresenceMark(label: label, projectPath: "/p", branch: branch,
            updatedAt: now.addingTimeInterval(-updatedMinutesAgo * 60),
            pid: pid, task: nil, capabilities: [])
    }
    /// pid 1 is alive, pid 9 is dead, anything else is unknown.
    private let liveness: @Sendable (Int, Date) -> Bool? = { pid, _ in pid == 1 ? true : (pid == 9 ? false : nil) }

    /// One label, two worktrees, one of them fell over: the survivor's claim
    /// was reaped on the strength of the other's dead pid.
    func testALiveSessionKeepsItsClaimWhenAnotherUnderTheSameLabelDied() {
        let (live, reaped) = PathClaims.reap(
            [claim("claude")],
            presence: [mark("claude", pid: 9, branch: "agent/a"), mark("claude", pid: 1, branch: "agent/b")],
            isPIDAlive: liveness, now: now)
        XCTAssertEqual(live.count, 1, "a dead sibling unlocked the paths of the session still editing them")
        XCTAssertTrue(reaped.isEmpty)
    }

    /// An executor that finished is not its parent dying.
    func testAFinishedSubagentDoesNotReapItsLiveParentsClaim() {
        let (live, reaped) = PathClaims.reap(
            [claim("claude")],
            presence: [mark("claude#exec1", pid: 9), mark("claude", pid: 1)],
            isPIDAlive: liveness, now: now)
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(reaped.isEmpty)
    }

    /// The subagent's own claim still goes with the subagent: its own mark
    /// says more about it than its parent's does.
    func testADeadSubagentsOwnClaimIsStillReaped() {
        let (live, reaped) = PathClaims.reap(
            [claim("claude#exec1")],
            presence: [mark("claude#exec1", pid: 9), mark("claude", pid: 1)],
            isPIDAlive: liveness, now: now)
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(reaped.count, 1)
    }

    /// And nothing changed for a label whose every mark is dead or stale.
    func testEveryMarkDeadStillReaps() {
        let (live, reaped) = PathClaims.reap(
            [claim("claude")],
            presence: [mark("claude", pid: 9, branch: "agent/a"),
                       mark("claude", pid: nil, branch: "agent/b", updatedMinutesAgo: 90)],
            isPIDAlive: liveness, now: now)
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(reaped.count, 1)
    }
}

final class ClaimRefusalWordingTests: XCTestCase {
    /// One holder with two claims in the way printed the same plan twice.
    func testTheSamePlanIsNotPrintedOncePerClaimInTheWay() {
        let now = Date()
        func held(_ pattern: String) -> PathClaim {
            PathClaim(label: "claude", projectPath: "/p", pattern: pattern, intent: nil,
                      since: now, expires: now.addingTimeInterval(1790), implicit: false)
        }
        let conflict = PathClaimConflict(pattern: "lib/store/s.dart",
                                         holders: [held("lib/store/**"), held("lib/store/s.dart")])
        XCTAssertEqual(conflict.description.split(separator: "\n").count, 1, conflict.description)
    }

    /// Two different holders are still two lines.
    func testTwoHoldersAreStillNamedSeparately() {
        let now = Date()
        let holders = ["claude", "codex"].map {
            PathClaim(label: $0, projectPath: "/p", pattern: "lib/**", intent: nil,
                      since: now, expires: now.addingTimeInterval(1790), implicit: false)
        }
        let text = PathClaimConflict(pattern: "lib/a.swift", holders: holders).description
        XCTAssertEqual(text.split(separator: "\n").count, 2, text)
    }
}

/// The review says "it builds" only about something that was built.
final class ReviewBuildClaimTests: XCTestCase {
    private let work = WorkSummary(projectPath: "/tmp/p", isRepository: true, baseline: "a", baselineIsHead: true)
    private func result(_ kind: Check.Kind, _ status: CheckResult.Status) -> CheckResult {
        CheckResult(name: "\(kind)", command: "x", kind: kind, status: status)
    }
    private func line(_ checks: [CheckResult]) -> String {
        WorkInspector.openQuestions(for: work, checks: checks)
            .first { $0.contains("nothing confirmed behaviour") } ?? ""
    }

    func testWithNoChecksAtAllNothingIsSaidToBuild() {
        XCTAssertFalse(line([]).isEmpty)
        XCTAssertFalse(line([]).contains("builds"), line([]))
    }

    func testAFailedBuildIsNotSaidToBuild() {
        XCTAssertFalse(line([result(.build, .failed)]).contains("builds"))
    }

    func testAPassingBuildStillSaysThatIsAllItIs() {
        XCTAssertTrue(line([result(.build, .passed)]).contains("only that it builds"))
    }

    func testATestSuiteThatFailedIsNotSaidNotToHaveRun() {
        let text = line([result(.build, .passed), result(.test, .failed)])
        XCTAssertTrue(text.contains("No test suite passed"), text)
    }

    func testAPassingTestSuiteLeavesTheLineOut() {
        XCTAssertTrue(line([result(.test, .passed)]).isEmpty)
    }
}

/// Blank and half-given arguments on the command line.
final class BlankArgumentCLITests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("blank-args-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.email", "t@example.com"], in: root)
        try git(["config", "user.name", "t"], in: root)
        try "seed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: root); try git(["commit", "-qm", "seed"], in: root)
        XCTAssertTrue(run(["project", "init", "--label", "claude"]).succeeded)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> Shell.Output {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: dir, timeout: 60)
        guard out.succeeded else {
            throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr])
        }
        return out
    }

    private func run(_ args: [String], in dir: URL? = nil) -> Shell.Output {
        Shell.run(binary, args, in: dir ?? root, environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
    }

    private func worktree(_ name: String, label: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try git(["worktree", "add", "-q", url.path, "-b", "agent/\(name)"], in: root)
        XCTAssertTrue(run(["project", "init", "--label", label], in: url).succeeded)
        return url
    }

    private func taskList() -> String { run(["task", "list"]).stdout }

    /// `task rm " "` matched the first task with a space in it and removed it.
    func testABlankSelectorTouchesNoTask() {
        XCTAssertTrue(run(["task", "add", "first thing to do", "--step", "one point"]).succeeded)
        XCTAssertTrue(run(["task", "add", "second thing to do"]).succeeded)
        let before = taskList()

        for action in ["rm", "done", "claim"] {
            for blank in [" ", "   ", "\t"] {
                let out = run(["task", action, blank])
                XCTAssertEqual(out.status, 1, "task \(action) \"\(blank)\" acted: \(out.stdout)")
            }
        }
        XCTAssertEqual(run(["task", "step", "done", "0", " "]).status, 1)
        XCTAssertEqual(taskList(), before)

        // What a selector is for still works.
        XCTAssertEqual(run(["task", "done", "second thing"]).status, 0)
        XCTAssertEqual(run(["task", "step", "done", "0", "one"]).status, 0)
    }

    func testAnEmptyStepIsRefusedNotCalledADuplicate() {
        XCTAssertTrue(run(["task", "add", "a task"]).succeeded)
        let out = run(["task", "step", "add", "0", ""])
        XCTAssertEqual(out.status, 64, out.stdout)
        XCTAssertFalse(out.stdout.contains("already on the list"), out.stdout)
    }

    /// `release --paths ""` was read as a bare `release`: everything went.
    func testAnEmptyPathsListReleasesNothing() {
        XCTAssertEqual(run(["claim", "--paths", "lib/a/**,lib/b/**"]).status, 0)
        for empty in ["", " ", ",,"] {
            let out = run(["release", "--paths", empty])
            XCTAssertEqual(out.status, 64, "--paths \"\(empty)\" released: \(out.stdout)")
        }
        XCTAssertEqual(run(["release", "--paths"]).status, 64)
        let held = run(["claims"]).stdout
        XCTAssertTrue(held.contains("lib/a/**") && held.contains("lib/b/**"), held)

        XCTAssertEqual(run(["release", "--paths", "lib/a/**"]).status, 0)
        XCTAssertFalse(run(["claims"]).stdout.contains("lib/a/**"))
        XCTAssertEqual(run(["release"]).status, 0)
        XCTAssertTrue(run(["claims"]).stdout.contains("No live path claims"))
    }

    /// What `--paths a,b` left you holding depended on the order you wrote them in.
    func testEveryPatternOfAClaimGetsItsAnswer() throws {
        let hermes = try worktree("wt-hermes", label: "hermes")
        XCTAssertEqual(run(["claim", "--paths", "lib/store/**"]).status, 0)

        let out = run(["claim", "--paths", "lib/store/x.dart,lib/data/**"], in: hermes)
        XCTAssertEqual(out.status, 1, "a refused pattern must still be an error")
        XCTAssertTrue(out.stderr.contains("claimed by claude"), out.stderr)
        XCTAssertTrue(out.stdout.contains("Claimed lib/data/**"), "the pattern after the refused one was never tried: \(out.stdout)")
        XCTAssertTrue(run(["claims"]).stdout.contains("hermes: `lib/data/**`"))
    }

    /// The MCP tool refused these; the command line created the request.
    func testDelegateRefusesAnEmptyTitleOrSpecAndABudgetThatIsNotANumber() {
        let refused: [[String]] = [
            ["delegate", "--to", "hermes", "--title", "", "--spec", "do it"],
            ["delegate", "--to", "hermes", "--title", "a title", "--spec", "  "],
            ["delegate", "--to", "hermes", "--title", "a title", "--spec", "do it", "--budget", "abc"],
            ["delegate", "--to", "hermes", "--title", "a title", "--spec", "do it", "--budget", "1.5"],
            ["delegate", "--to", "hermes", "--title", "a title", "--spec", "do it", "--budget"],
        ]
        for arguments in refused {
            let out = run(arguments)
            XCTAssertEqual(out.status, 64, "\(arguments) was accepted: \(out.stdout)")
        }
        XCTAssertEqual(run(["request", "list"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").filter { $0.contains("req-") }.count, 0)

        let made = run(["delegate", "--to", "hermes", "--title", "a title", "--spec", "do it", "--budget", "15"])
        XCTAssertEqual(made.status, 0, made.stderr)
        XCTAssertTrue(made.stdout.contains("req-"), made.stdout)
    }

    /// `claim --help` printed the whole manual, which did not mention `claim`.
    func testTheHelpNamesTheCommandsTheReadmeLeadsWith() {
        for command in ["claim", "release", "claims", "delegate", "request", "presence", "mcp"] {
            let out = run([command, "--help"])
            XCTAssertEqual(out.status, 0)
            XCTAssertTrue(out.stdout.contains("gentlemerge \(command)"), "no help for \(command)")
            XCTAssertFalse(out.stdout.contains("gentlemerge install"), "\(command) --help fell back to the whole manual")
        }
    }
}

/// One absurd number in a shared file must not take every reader down with it.
final class AbsurdDateTests: XCTestCase {
    private struct Row: Codable { var at: Date }
    private func decode(_ json: String) throws -> Date {
        try JSONCoding.decoder().decode(Row.self, from: Data(json.utf8)).at
    }

    /// `Int(date.timeIntervalSinceNow / 60)` is how every "minutes left" is
    /// worked out, and it traps on a date too far away to count.
    func testANumberTooBigToBeADateStillComesBackCountable() throws {
        for json in [#"{"at":1e300}"#, #"{"at":-1e300}"#, #"{"at":"1e300"}"#, #"{"at":9223372036854775807}"#] {
            let interval = try decode(json).timeIntervalSinceNow
            XCTAssertTrue(interval.isFinite)
            XCTAssertLessThan(abs(interval), Double(Int.max) / 2, json)
        }
    }

    func testNotANumberIsNotADate() {
        for json in [#"{"at":"nan"}"#, #"{"at":"inf"}"#, #"{"at":"-infinity"}"#] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testOrdinaryDatesAreReadAsBefore() throws {
        XCTAssertEqual(try decode(#"{"at":"2026-11-13T21:00:00Z"}"#).timeIntervalSince1970, 1_794_603_600)
        XCTAssertEqual(try decode(#"{"at":1794603600}"#).timeIntervalSince1970, 1_794_603_600)
        XCTAssertEqual(try decode(#"{"at":"1794603600.5"}"#).timeIntervalSince1970, 1_794_603_600.5)
    }

    /// The whole path: a claim written by some other tool with a number where
    /// the date goes. `gentlemerge claims` and every `brief` died on it.
    func testAClaimWithAnAbsurdExpiryIsListedNotFatal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("absurd-date-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        let rows = """
            [{"id":"a","label":"hermes","projectPath":"/p","pattern":"lib/**","since":"2026-11-13T21:00:00Z","expires":1e300,"implicit":false},
             {"id":"b","label":"codex","projectPath":"/p","pattern":"docs/**","since":"2026-11-13T21:00:00Z","expires":-1e300,"implicit":false}]
            """
        try Data(rows.utf8).write(to: paths.pathClaims)

        let live = PathClaims(paths: paths).live(project: "/p")
        XCTAssertEqual(live.map(\.label), ["hermes"], "the far-future row stands, the far-past one has lapsed")
        let holder = try XCTUnwrap(live.first)
        XCTAssertFalse(ClaimRejection.plan(holder: holder, path: "lib/a.swift").isEmpty)
        let blocked = PrecommitGate.evaluate(staged: ["lib/a.swift"], me: "claude", claims: live, ownership: Ownership(rules: []))
        XCTAssertEqual(blocked.count, 1, "and it still blocks, as a live claim does")
    }
}

/// Running a command costs no descriptors once it has returned.
final class ShellDescriptorTests: XCTestCase {
    /// `/dev/fd` lists this process's open descriptors on macOS and Linux alike.
    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    /// Two were lost per call on Linux — the read ends of the two pipes. The
    /// first CI run of this suite there reached 1,300 open pipes and crashed
    /// inside Foundation's next spawn; an MCP server, which runs git on every
    /// tool call, would have met the descriptor limit instead.
    func testFortyCommandsLeaveNoDescriptorsBehind() throws {
        // The first call may start machinery that stays (a monitor thread and
        // its sockets); it is the growth per call after that which is a leak.
        _ = Shell.run("/bin/echo", ["warm up"], timeout: 10)
        let before = openDescriptors()
        try XCTSkipIf(before == 0, "no /dev/fd here to count with")

        for round in 0..<40 {
            let output = Shell.run("/bin/echo", ["\(round)"], timeout: 10)
            XCTAssertEqual(output.stdout, "\(round)\n")
        }
        // A reader thread closes its handle just after the call returns.
        var after = openDescriptors()
        for _ in 0..<20 where after > before + 4 {
            Thread.sleep(forTimeInterval: 0.05)
            after = openDescriptors()
        }
        XCTAssertLessThanOrEqual(after, before + 4, "\(after - before) descriptors still open after 40 commands")
    }
}
