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
}
