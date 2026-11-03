import XCTest
@testable import GentleMergeCore

final class LogBoundsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("log-bounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAnOversizeLogMovesAsideInsteadOfGrowingForever() throws {
        let log = root.appendingPathComponent("gentlemerge.log")
        try Data(repeating: UInt8(ascii: "x"), count: 2_000).write(to: log)

        Log.rotateIfNeeded(log, limit: 1_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the full log should have moved")
        let previous = root.appendingPathComponent("gentlemerge.log.1")
        XCTAssertEqual(try Data(contentsOf: previous).count, 2_000)
    }

    func testASecondRotationReplacesTheFirstGeneration() throws {
        let log = root.appendingPathComponent("gentlemerge.log")
        let previous = root.appendingPathComponent("gentlemerge.log.1")
        try Data("old generation".utf8).write(to: previous)
        try Data(repeating: UInt8(ascii: "y"), count: 2_000).write(to: log)

        Log.rotateIfNeeded(log, limit: 1_000)

        XCTAssertEqual(try Data(contentsOf: previous).count, 2_000)
    }

    func testASmallOrMissingLogIsLeftAlone() throws {
        let log = root.appendingPathComponent("gentlemerge.log")
        Log.rotateIfNeeded(log, limit: 1_000)                       // does not exist: nothing to do
        try Data("short".utf8).write(to: log)
        Log.rotateIfNeeded(log, limit: 1_000)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "short")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gentlemerge.log.1").path))
    }

    func testTheStagedFilesErrorIsOneLineNotGitsWholeUsageText() throws {
        // A directory that is not a repository: git reads `diff --cached` as `--no-index`
        // and prints its usage. What reaches the log is the first line.
        let log = root.appendingPathComponent("gentlemerge.log")
        let saved = Log.fileURL
        Log.fileURL = log
        defer { Log.fileURL = saved }

        let gate = PrecommitGate(paths: Paths(home: root.appendingPathComponent("home")))
        let files = gate.stagedFiles(repo: root)
        XCTAssertEqual(files, [PrecommitGate.unreadableIndexSentinel])

        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("could not read the staged files"), text)
        XCTAssertLessThan(text.split(separator: "\n").count, 3, "the usage text leaked into the log:\n\(text.prefix(400))")
    }
}
