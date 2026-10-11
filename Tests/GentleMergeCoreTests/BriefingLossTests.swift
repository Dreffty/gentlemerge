import XCTest
@testable import GentleMergeCore

/// The briefing is what an agent pays for every single turn, and what tells it
/// what the *other* agents are doing. Three ways it lost that, all silent, and
/// none reachable from the suite's existing inputs — a flood of ~18-char
/// messages from one sender with no peers never grows the kept prefix, never
/// emits a truncation notice, and never produces a claim (audit 2026-10-07).
final class BriefingLossTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var bus: AgentBus!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("briefloss-\(UUID())")
        paths = Paths(home: root.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bus = AgentBus(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func flood(_ count: Int, size: Int) {
        for i in 0..<count {
            bus.post(AgentMessage(
                from: "peer\(i % 3)",
                text: String(format: "m%03d-", i) + String(repeating: "x", count: size),
                kind: .update
            ))
        }
    }

    /// A message whose text ends in a newline leaves "" as the last physical
    /// line of its rendered block. `deliveredLines` contains "" for *any*
    /// output with a blank separator, so the survival check passed
    /// unconditionally and the message was recorded delivered although the cap
    /// had cut its body — never to be seen again.
    func testAMessageEndingInANewlineIsNotLostWhenTheCapCutsIt() {
        // A big body plus a trailing newline, then enough backlog to force a cut.
        bus.post(AgentMessage(from: "peer", text: String(repeating: "y", count: 900) + "\n", kind: .update))
        flood(6, size: 490)

        var appeared = false
        var turns = 0
        while let out = bus.briefing(sessionID: "nl", me: "reader", project: root.path, mode: .delta) {
            turns += 1
            if out.contains(String(repeating: "y", count: 200)) { appeared = true; break }
            if turns > 30 { break }
        }

        XCTAssertTrue(appeared, "a block the cap cut must stay pending, not be marked delivered and dropped")
    }

    /// The primitive behind it, in isolation: the last line used to decide
    /// survival must be a line with ink on it.
    func testTheSurvivalProbeIgnoresTrailingBlankLines() {
        XCTAssertEqual(AgentBus.lastMeaningfulLine(["body", ""]), "body")
        XCTAssertEqual(AgentBus.lastMeaningfulLine(["a", "b\n"]), "b")
        XCTAssertEqual(AgentBus.lastMeaningfulLine(["", "  ", "x"]), "x")
        XCTAssertNil(AgentBus.lastMeaningfulLine(["", "   "]))
        XCTAssertNil(AgentBus.lastMeaningfulLine([]))
    }

    /// The kept prefix — urgent head, peer lines, leading blocks — used to be
    /// exempt from the cut with no upper bound, so a turn cost 5864 chars
    /// against a cap of 1200. The guarantee the README sells is a per-turn one.
    func testNoTurnExceedsTheDeltaBudgetEvenWhenThePrefixIsOversize() {
        // Multi-line bodies, which is the trigger: `quote` caps each *line* at
        // maxCharsPerLine but nothing caps the block, so one oversize block
        // enters `keeping` whole and the peers stack up behind it.
        for i in 0..<8 {
            bus.post(AgentMessage(
                from: "peer\(i % 4)",
                text: (0..<8).map { String(format: "line%02d-", $0) + String(repeating: "z", count: 55) }.joined(separator: "\n"),
                kind: .update
            ))
        }

        var worst = 0
        var turns = 0
        while let out = bus.briefing(sessionID: "budget", me: "reader", project: root.path, mode: .delta) {
            turns += 1
            worst = max(worst, out.count)
            if turns > 40 { break }
        }

        XCTAssertGreaterThan(worst, 0, "sanity: something was actually delivered")
        XCTAssertLessThanOrEqual(
            worst, BriefingBudget.deltaMaxChars + 200,
            "a turn cost \(worst) chars; the prefix must not be exempt from the cap"
        )
    }

    /// And nothing may be lost in exchange for the bound: whatever did not make
    /// it must still arrive on a later turn.
    func testBoundingTheTurnDoesNotLoseTheOverflow() {
        let bodies = (0..<10).map { i in
            String(format: "keep%02d-", i) + String(repeating: "q", count: 400)
        }
        for body in bodies { bus.post(AgentMessage(from: "peer", text: body, kind: .update)) }

        var seen: Set<String> = []
        var turns = 0
        while let out = bus.briefing(sessionID: "lossless", me: "reader", project: root.path, mode: .delta) {
            turns += 1
            for i in 0..<10 where out.contains(String(format: "keep%02d-", i)) { seen.insert("keep\(i)") }
            if turns > 40 { break }
        }

        XCTAssertEqual(seen.count, 10, "every message must arrive exactly once across turns, got \(seen.sorted())")
    }

    /// A peer claiming a path used to be recorded as seen *before* the cap ran,
    /// so when the cap cut the claims section the announcement was gone for
    /// good — and because a seen claim is never re-shown, `brief --as` and a
    /// later full briefing did not recover it either.
    func testAPeerClaimTheBudgetCutsIsAnnouncedOnALaterTurn() throws {
        // Backlog big enough that the claims section gets cut off.
        flood(10, size: 480)
        try PathClaims(paths: paths).claim(
            pattern: "lib/store/cart/**", label: "hermes", project: root.path, intent: "cart work"
        )

        var announced = false
        var turns = 0
        while let out = bus.briefing(sessionID: "claimlost", me: "reader", project: root.path, mode: .delta) {
            turns += 1
            if out.contains("lib/store/cart/**") { announced = true; break }
            if turns > 40 { break }
        }

        XCTAssertTrue(announced, "a claim the budget cut must be announced next turn, not marked seen and dropped")
    }
}