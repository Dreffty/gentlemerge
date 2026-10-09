import XCTest
@testable import GentleMergeCore

/// `AtomicFile.write` is the substrate every other guarantee stands on: the
/// pre-commit gate reads `claims-paths.json` through it, un-locked, while other
/// agents rewrite it. If a reader can ever observe an empty world, the gate
/// decides "nothing is claimed" and waves a blocked commit through.
///
/// The old implementation was `removeItem` + `moveItem`, which is
/// delete-then-rename: the destination genuinely did not exist for a window,
/// and the loser of a writer race threw with its temp file orphaned. Measured
/// against the real gate, 54% of blocked evaluations passed (audit
/// 2026-10-07). These tests pin the invariants that closes.
final class AtomicFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("atomicfile-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `static` so the concurrent closures below capture a free function rather
    /// than `self`: `XCTestCase` is not Sendable, and the Linux CI toolchain
    /// rejects capturing it from a `@Sendable` closure (audit 2026-10-09).
    private static func payload(_ seed: Int) -> Data {
        Data(String(repeating: "x", count: 2048).utf8) + Data("-\(seed)".utf8)
    }

    /// A reader hammering the file while a writer rewrites it must never see it
    /// absent or empty. This is the exact access pattern of `precommit`.
    func testAConcurrentReaderNeverSeesTheFileAbsent() throws {
        let url = root.appendingPathComponent("claims.json")
        try AtomicFile.write(Self.payload(0), to: url)

        let writers = 4
        let iterations = 400
        let group = DispatchGroup()
        let empty = Counter()

        // Readers spin on their own; writers overwrite. Any zero-length or
        // missing read is a hole in the rename.
        for r in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<iterations * 3 {
                    guard let data = try? Data(contentsOf: url) else { empty.increment(); continue }
                    if data.isEmpty { empty.increment() }
                }
                group.leave()
            }
        }
        for w in 0..<writers {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<iterations { try? AtomicFile.write(Self.payload(w * 10_000 + i), to: url) }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(empty.value, 0, "a reader observed an absent or empty claims file during a concurrent rewrite")
    }

    /// Concurrent writers must all succeed and must not leak their temp files.
    /// The old `moveItem` threw "file exists" for every loser, destroying the
    /// previous content and leaving a `.tmp-` behind with no sweeper.
    func testConcurrentWritersNeitherThrowNorLeak() throws {
        let url = root.appendingPathComponent("cursor.json")
        let writers = 6
        let iterations = 200
        let group = DispatchGroup()
        let failures = Counter()

        for w in 0..<writers {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<iterations {
                    do {
                        try AtomicFile.write(Self.payload(w * 10_000 + i), to: url)
                    } catch {
                        failures.increment()
                    }
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(failures.value, 0, "a concurrent rename failed; the destination is now gone")
        let orphans = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".tmp-") }
        XCTAssertEqual(orphans, [], "orphaned temp files: \(orphans.count)")
        // Whatever won, the file must still be whole.
        let final = try Data(contentsOf: url)
        XCTAssertFalse(final.isEmpty, "the destination ended up empty")
    }

    /// The destination must survive being rewritten, including the very first
    /// write into a directory that does not exist yet.
    func testWriteCreatesIntermediateDirectoriesAndReplaces() throws {
        let url = root.appendingPathComponent("a/b/c/state.json")
        try AtomicFile.write(Self.payload(1), to: url)
        let first = try Data(contentsOf: url)
        try AtomicFile.write(Self.payload(2), to: url)
        let second = try Data(contentsOf: url)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, Self.payload(2), "rename must replace, not merge or append")
    }

    /// A plain thread-safe counter: `@MainActor` or locks would serialise the
    /// very thing under test.
    private final class Counter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}