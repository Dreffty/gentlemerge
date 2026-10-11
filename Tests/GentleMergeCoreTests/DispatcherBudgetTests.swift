import XCTest
@testable import GentleMergeCore

/// The daily headless budget is counted off `dispatch.start` ledger lines —
/// forgivingly, so old lines and garbage never break the total.
final class DispatcherBudgetTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-budget-\(UUID())")
        paths = Paths(home: root.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func start(budget: Int?, at: Date) -> String {
        let entry = LedgerEntry(at: at, kind: .note, itemID: "req-1", title: "dispatch.start",
            summary: budget.map { "budget \($0)m" })
        return String(decoding: try! JSONCoding.encoder().encode(entry), as: UTF8.self)
    }

    func testSpentTodayCountsOnlyTodaysBudgetedStarts() throws {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        try Data([
            start(budget: 30, at: now),
            start(budget: 60, at: yesterday),
            start(budget: nil, at: now),
            "not json at all",
        ].joined(separator: "\n").utf8).write(to: paths.ledger)
        XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths, now: now), 30)
    }

    func testSpentTodayIsZeroWithoutALedger() {
        XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths), 0)
    }

    /// The parse is memoised on the ledger's size and mtime, but the *answer*
    /// still follows the file: the app's 3-second tick calls this on the main
    /// actor, and a cache that went stale would silently stop enforcing the
    /// daily budget (audit 2026-10-11).
    func testTheMemoisationStillFollowsTheFile() throws {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)

        func writeLedger(_ extraBudget: Int? = nil) throws {
            var lines = [
                start(budget: 30, at: now),
                start(budget: 60, at: yesterday),
                start(budget: nil, at: now),
                "not json at all",
            ]
            if let extraBudget { lines.append(start(budget: extraBudget, at: now)) }
            try Data(lines.joined(separator: "\n").utf8).write(to: paths.ledger)
        }

        try writeLedger()
        XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths, now: now), 30)

        // Rewriting with another day's budget must change the answer: the cache
        // is keyed on the ledger's size and mtime, and the ledger is
        // append-only, so any new line changes both.
        try writeLedger(15)
        XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths, now: now), 45)

        // "Today" is literally the day asked about: yesterday's ledger holds
        // only its own 60, and a day nothing was dispatched holds none at all.
        // (A cache that had gone stale would answer 45 for both.)
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths, now: yesterday), 60)
        XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths, now: tomorrow), 0)
    }

    /// A large ledger must not make the *repeat* calls expensive. Not a timing
    /// assertion — that is flaky by construction — but a budget check: warming
    /// the cache and then asking 50 times has to stay well inside what a
    /// 3-second tick on the main actor can afford, where a full decode each time
    /// cost seconds on a 50k-line ledger.
    func testALargeLedgerDoesNotMakeEveryCallCostADecode() throws {
        let now = Date()
        var lines = [start(budget: 30, at: now)]
        // 50k lines of noise, which is what a ledger accumulates over months of
        // the app running headless.
        for index in 0..<50_000 {
            lines.append("{\"at\":\"\(ISO8601DateFormatter.gentleMerge.string(from: now))\","
                + "\"title\":\"briefing.injected\",\"summary\":\"chars \(index)\"}")
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: paths.ledger)

        let cold = Date()
        XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths, now: now), 30)
        let coldCost = Date().timeIntervalSince(cold)

        let warm = Date()
        for _ in 0..<50 { XCTAssertEqual(Dispatcher.spentTodayMinutes(paths: paths, now: now), 30) }
        let warmCost = Date().timeIntervalSince(warm)

        XCTAssertLessThan(warmCost, coldCost,
                          "warming the cache should make repeat calls cheaper, not dearer")
        // 50 warm calls must fit in a twentieth of a tick; before the memoisation
        // each of them decoded the whole file.
        XCTAssertLessThan(warmCost, 0.15,
                          "50 cached calls took \(warmCost)s — the decode is still running every call")
    }
}
