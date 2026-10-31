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
