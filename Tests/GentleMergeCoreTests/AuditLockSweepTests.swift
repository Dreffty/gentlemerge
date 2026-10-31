import XCTest
@testable import GentleMergeCore

/// The sweep deletes idle lock sidecars. A sidecar deleted between a locker's
/// `open` and its `flock` must not leave that locker holding a lock nobody
/// else can see (audit 2026-11-01).
final class LockSweepRaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lock-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        LockedFile.afterOpenForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testASidecarSweptMidOpenIsNotTheOneHeld() throws {
        let url = root.appendingPathComponent("claims.json")
        let lock = root.appendingPathComponent("claims.json.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        var sweeps = 0
        LockedFile.afterOpenForTesting = {
            guard sweeps == 0 else { return }
            sweeps += 1
            try? FileManager.default.removeItem(at: lock)       // what Retention.pruneLocks does
        }

        var heldTheFileAtThePath = false
        try LockedFile.withExclusiveLock(url) {
            heldTheFileAtThePath = FileManager.default.fileExists(atPath: lock.path)
        }

        XCTAssertEqual(sweeps, 1)
        XCTAssertTrue(heldTheFileAtThePath, "the body ran under a lock on a sidecar that was gone")
    }

    func testTheNonBlockingFormRetriesTooAndStillReportsAHeldLock() throws {
        let url = root.appendingPathComponent("land.json")
        let lock = root.appendingPathComponent("land.json.lock")
        var swept = false
        LockedFile.afterOpenForTesting = {
            guard !swept else { return }
            swept = true
            try? FileManager.default.removeItem(at: lock)
        }
        var ran = false
        XCTAssertTrue(try LockedFile.tryExclusiveLock(url) { ran = FileManager.default.fileExists(atPath: lock.path) })
        XCTAssertTrue(ran)
        LockedFile.afterOpenForTesting = nil

        // Somebody else holding it is still a plain "no".
        let other = open(lock.path, O_WRONLY | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(other, 0)
        defer { close(other) }
        XCTAssertEqual(flock(other, LOCK_EX), 0)
        XCTAssertFalse(try LockedFile.tryExclusiveLock(url) { XCTFail("ran while somebody else held it") })
    }
}

/// A one-shot command must not wait forever behind the app's drain (audit 2026-11-01).
final class HeadlessDrainPatienceTests: XCTestCase {
    func testAHeadlessDrainGivesUpWhileAnotherProcessHoldsTheDrainLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drain-patience-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        try SpoolStore(paths: paths).enqueue(SpoolEnvelope(provider: .claudeCode, cwd: root.path,
            payload: .object(["session_id": .string("s1"), "hook_event_name": .string("Stop")])))

        // Stand in for an app whose drain is stuck behind a macOS permission prompt.
        let lock = paths.home.appendingPathComponent("drain.lock.lock")
        let held = open(lock.path, O_WRONLY | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX), 0)

        let start = Date()
        InboxModel.drainHeadless(paths: paths)
        let waited = Date().timeIntervalSince(start)

        XCTAssertLessThan(waited, 15, "waited \(waited)s behind a drain that never ends")
        let queued = try FileManager.default.contentsOfDirectory(atPath: paths.spool.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(queued.count, 1, "the envelope is left for the drain that holds the lock")
    }

    func testTheBoundedLockStillRunsWhenNobodyHoldsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drain-free-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ran = try LockedFile.withExclusiveLock(root.appendingPathComponent("x"), waitingAtMost: 1) { 42 }
        XCTAssertEqual(ran, 42)
    }
}
