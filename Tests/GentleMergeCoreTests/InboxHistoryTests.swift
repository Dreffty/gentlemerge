import XCTest
@testable import GentleMergeCore

/// `clearHistory` did nothing, and `state.json` grew forever.
///
/// `saveState` unions the rows on disk back in, so a headless drain cannot
/// erase what the menu-bar app just added — correct, and the reason the merge
/// exists. But the union also put back every row `clearHistory` had just
/// removed, one tick later. The comment above the merge said "rows are never
/// deleted, only re-stated, so a union cannot resurrect": that describes the
/// intent, and the code did the opposite (audit 2026-10-07).
@MainActor
final class InboxHistoryTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var model: InboxModel!

    override func setUp() async throws {
        try await MainActor.run { try prepare() }
    }

    private func prepare() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inboxhist-\(UUID())")
        paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        model = InboxModel(paths: paths)
    }

    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: self.paths.home) }
    }

    /// A resolved row, which is what history is made of: ingest, then mark
    /// handled through the same public path the UI uses. Identified by diffing
    /// ids rather than by title, since the title is the provider's wording and
    /// not ours to predict.
    @discardableResult
    private func addResolved(_ marker: String) throws -> InboxItem {
        let before = Set(model.items.map(\.id))
        model.ingest(SpoolEnvelope(
            id: "env-\(marker)",
            provider: .claudeCode,
            cwd: root.path,
            payload: JSONValue.object(["message": .string(marker)])
        ))
        let item = try XCTUnwrap(
            model.items.first { !before.contains($0.id) },
            "ingest produced no new item for \(marker)"
        )
        model.markHandled(item)
        return item
    }

    func testClearedHistoryDoesNotComeBack() throws {
        for i in 0..<5 { try addResolved("gone\(i)") }
        let first = try XCTUnwrap(model.items.first { $0.summary.contains("gone0") })
        XCTAssertFalse(first.isPending)

        model.clearHistory()
        // Reload from disk exactly as a fresh process or a 3-second tick would.
        model.loadState()

        XCTAssertFalse(
            model.items.contains { $0.id == first.id },
            "Clear history resurrected the row it was asked to remove: \(model.items.map(\.summary))"
        )
    }

    /// And it stays gone across repeated drains, not just the first one.
    func testClearedHistoryStaysGoneAcrossRepeatedSaves() throws {
        for i in 0..<3 { try addResolved("bye\(i)") }
        let ids = Set(model.items.map(\.id))

        model.clearHistory()
        for _ in 0..<3 {
            model.loadState()
            model.saveState()
        }

        XCTAssertTrue(
            ids.isDisjoint(with: Set(model.items.map(\.id))),
            "rows came back after repeated save/load cycles"
        )
    }

    /// The merge the whole thing depends on must keep working: a row another
    /// process added while this one was draining must survive our save. This is
    /// the guarantee the removal ledger must not break.
    func testRowsWrittenByAnotherProcessAreStillMerged() throws {
        let mine = try addResolved("mine")
        model.saveState()

        // A second process appends a row directly to the same file.
        let extra = InboxItem(
            id: "theirs", sessionID: "other", provider: .claudeCode,
            eventName: "Stop", title: "theirs", summary: "s"
        )
        var onDisk = try JSONCoding.decoder().decode([InboxItem].self, from: Data(contentsOf: paths.state))
        onDisk.append(extra)
        try AtomicFile.write(try JSONCoding.encoder().encode(onDisk), to: paths.state)

        model.loadState()
        model.saveState()

        XCTAssertTrue(model.items.contains { $0.id == mine.id }, "our own row must survive")
        XCTAssertTrue(model.items.contains { $0.title == "theirs" }, "another process's row must not be erased")
    }

    /// A pending row is not history and must survive a clear.
    func testClearingHistoryLeavesPendingRowsAlone() throws {
        let envelope = SpoolEnvelope(
            provider: .claudeCode,
            cwd: root.path,
            payload: JSONValue.object(["message": .string("still open")])
        )
        model.ingest(envelope)
        let pendingID = try XCTUnwrap(model.items.first { $0.isPending }).id

        model.clearHistory()
        model.loadState()

        XCTAssertTrue(model.items.contains { $0.id == pendingID && $0.isPending })
    }

    /// `trimHistory` is the same defect on the automatic path: with no removal
    /// ledger the file kept every row ever ingested regardless of
    /// `historyLimit`.
    func testHistoryLimitIsActuallyEnforcedOnDisk() throws {
        model.config.historyLimit = 3
        for i in 0..<12 { try addResolved("h\(i)") }
        model.saveState()

        let onDisk = try JSONCoding.decoder().decode([InboxItem].self, from: Data(contentsOf: paths.state))
        let resolved = onDisk.filter { !$0.isPending }
        XCTAssertLessThanOrEqual(
            resolved.count, 3,
            "historyLimit is 3 but \(resolved.count) resolved rows are on disk"
        )
    }
}