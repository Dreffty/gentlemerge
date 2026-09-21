import XCTest
@testable import GentleMergeCore

/// Coordination cost, counted off the ledger's briefing.injected lines.
final class StatsTests: XCTestCase {
    private var root: URL!

    private var paths: Paths { Paths(home: root.appendingPathComponent("home")) }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeLedger(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: paths.ledger)
    }

    private func injected(session: String, mode: String, chars: Int) -> String {
        let entry = LedgerEntry(
            at: Date(timeIntervalSince1970: 1_770_000_000),
            kind: .note,
            sessionID: session,
            title: Stats.eventTitle,
            mode: mode,
            chars: chars
        )
        return String(decoding: try! JSONCoding.encoder().encode(entry), as: UTF8.self)
    }

    private func noted(_ title: String, _ summary: String) -> String {
        let entry = LedgerEntry(at: Date(timeIntervalSince1970: 1_770_000_000), kind: .note, title: title, summary: summary)
        return String(decoding: try! JSONCoding.encoder().encode(entry), as: UTF8.self)
    }

    func testValueCountsWhatTheCoordinationSaved() throws {
        try writeLedger([
            noted("precommit.blocked", "codex: 2 violation(s)"),
            noted("precommit.blocked", "codex: 1 violation(s)"),
            noted("radar.conflict", "agent/a ↔ agent/b: 1 file(s) (f.txt)"),
            noted("advise", "lib/a.swift: 1 note(s), policy warn"),
            noted("claim.reaped", "hermes:Docs/**"),
            noted("claim.released", "alice: 2 path(s) landed"),
            noted("land.ok", "agent/a -> main @ abc1234: 3 file(s), 1 claim(s) released"),
            noted("say", "hello"),
            "this is not json",
        ])

        let value = Stats.value(paths: paths)
        XCTAssertEqual(value.blockedCommits, 2)
        XCTAssertEqual(value.violations, 3)
        XCTAssertEqual(value.conflictsAnnounced, 1)
        XCTAssertEqual(value.preEditWarnings, 1)
        XCTAssertEqual(value.staleClaimsCleared, 1)
        XCTAssertEqual(value.claimsReleased, 3)
        XCTAssertEqual(value.landings, 1)

        let line = Stats.valueLine(paths: paths)
        XCTAssertTrue(line.contains("2 commit(s) blocked"), line)
        XCTAssertTrue(line.contains("1 landing(s)"), line)
    }

    func testLedgerLinesCarryASchemaVersion() throws {
        let fresh = String(decoding: try JSONCoding.encoder().encode(
            LedgerEntry(at: Date(), kind: .note, title: "x")), as: UTF8.self)
        XCTAssertTrue(fresh.contains("\"v\""), fresh)
        let decoded = try JSONCoding.decoder().decode(LedgerEntry.self, from: Data(fresh.utf8))
        XCTAssertEqual(decoded.v, 1)
        // And a line from before versions existed still decodes.
        let old = #"{"id":"a","at":"2026-01-01T00:00:00Z","kind":"note","title":"x"}"#
        XCTAssertEqual(try JSONCoding.decoder().decode(LedgerEntry.self, from: Data(old.utf8)).v, 1)
    }

    func testValueWithAnEmptyLedgerSaysSoAndPointsAtDoctor() throws {        try writeLedger([])
        let value = Stats.value(paths: paths)
        XCTAssertEqual(value, Stats.Value())
        XCTAssertTrue(Stats.valueLine(paths: paths).contains("doctor"))
    }

    func testSummaryAggregatesTurnsCharsAndModes() throws {
        try writeLedger([
            injected(session: "s1", mode: "full", chars: 400),
            injected(session: "s1", mode: "delta", chars: 200),
            injected(session: "s2", mode: "delta", chars: 0),
            // Noise the summary must walk past: other events, and a line that
            // is not JSON at all.
            String(decoding: try JSONCoding.encoder().encode(LedgerEntry(
                at: Date(), kind: .note, title: "land.ok"
            )), as: UTF8.self),
            "this is not json",
        ])

        let all = Stats.summary(paths: paths)
        XCTAssertEqual(all.turns, 3)
        XCTAssertEqual(all.nonEmpty, 2)
        XCTAssertEqual(all.chars, 600)
        XCTAssertEqual(all.fullChars, 400)
        XCTAssertEqual(all.estTokens, 150)
        XCTAssertEqual(all.avgPerTurn, 50)

        let one = Stats.summary(paths: paths, session: "s1")
        XCTAssertEqual(one, Stats.Summary(turns: 2, nonEmpty: 2, chars: 600, fullChars: 400))

        let quiet = Stats.summary(paths: paths, session: "s2")
        XCTAssertEqual(quiet.turns, 1)
        XCTAssertEqual(quiet.nonEmpty, 0)
        XCTAssertEqual(quiet.avgPerTurn, 0)

        XCTAssertEqual(Stats.summary(paths: paths, session: "nobody").turns, 0)
    }

    func testSummaryLineSaysEstimate() throws {
        try writeLedger([injected(session: "s1", mode: "full", chars: 410)])
        // estTokens truncates: 410 / 4 = 102, avg over 1 turn = 102.
        XCTAssertEqual(
            Stats.summaryLine(paths: paths),
            "coordination cost: 1 briefings (1 non-empty) · ≈ 102 tokens total · ≈ 102 tokens/turn (estimate: chars/4)"
        )
    }

    func testAMissingLedgerIsZeroAndNotAnError() {
        XCTAssertEqual(Stats.summary(paths: paths), Stats.Summary())
        XCTAssertTrue(Stats.summaryLine(paths: paths).contains("0 briefings"))
    }

    /// Old lines move to the archive, new lines stay hot, corrupt lines are
    /// never lost — and the totals still count everything.
    func testArchiveMovesOldLinesButTotalsSurvive() throws {
        let old = LedgerEntry(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .note, sessionID: "s1", title: Stats.eventTitle, mode: "full", chars: 400
        )
        let new = LedgerEntry(
            at: Date(), kind: .note, sessionID: "s1",
            title: Stats.eventTitle, mode: "delta", chars: 200
        )
        let encoder = JSONCoding.encoder()
        try writeLedger([
            String(decoding: try encoder.encode(old), as: UTF8.self),
            String(decoding: try encoder.encode(new), as: UTF8.self),
            "not json at all",
        ])

        Ledger(url: paths.ledger).archive(paths: paths, olderThan: 30 * 24 * 3600, now: Date())

        let hot = (try? String(contentsOf: paths.ledger, encoding: .utf8)) ?? ""
        XCTAssertFalse(hot.contains("\"chars\":400"), "old line must leave the hot file")
        XCTAssertTrue(hot.contains("\"chars\":200"), "new line stays")
        XCTAssertTrue(hot.contains("not json at all"), "corrupt lines are never lost to a parse failure")

        let archived = (try? String(contentsOf: paths.ledgerArchive, encoding: .utf8)) ?? ""
        XCTAssertTrue(archived.contains("\"chars\":400"))

        let total = Stats.summary(paths: paths)
        XCTAssertEqual(total.turns, 2)
        XCTAssertEqual(total.chars, 600)
        XCTAssertEqual(total.fullChars, 400)

        // A second archive moves nothing and changes nothing.
        Ledger(url: paths.ledger).archive(paths: paths, olderThan: 30 * 24 * 3600, now: Date())
        XCTAssertEqual(Stats.summary(paths: paths), total)
    }

    /// Lines written before {mode, chars} existed still decode, and count as
    /// empty turns rather than breaking the total.
    func testOldLinesWithoutTheNewKeysStillDecode() throws {
        try writeLedger([
            #"{"id":"old","at":"2026-09-01T10:00:00Z","kind":"note","provider":"unknown","sessionID":"s9","title":"briefing.injected"}"#,
        ])
        let decoded = try JSONCoding.decoder().decode(
            LedgerEntry.self,
            from: Data(#"{"id":"old","at":"2026-09-01T10:00:00Z","kind":"note","provider":"unknown"}"#.utf8)
        )
        XCTAssertNil(decoded.mode)
        XCTAssertNil(decoded.chars)
        XCTAssertEqual(Stats.summary(paths: paths, session: "s9").turns, 1)
    }
}
