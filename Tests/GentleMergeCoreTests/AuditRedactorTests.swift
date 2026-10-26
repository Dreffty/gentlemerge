import XCTest
@testable import GentleMergeCore

/// The long-number rule broke file paths and dates; it must keep hiding real numbers.
final class RedactorLongNumberTests: XCTestCase {
    private func scrubbed(_ text: String) -> String { Redactor.scrub(text).text }

    func testADigitFolderInAFilePathSurvives() {
        for path in ["/backups/20261026/log.txt", "/var/run/1234567890/app.sock", "~/Downloads/87654321/x.md",
                     "./out/12345678901/report.html", "../runs/9876543210/a.txt"] {
            XCTAssertEqual(scrubbed("see \(path) for the log"), "see \(path) for the log", path)
        }
        XCTAssertEqual(scrubbed("copied to '/srv/data/11223344/f' ok"), "copied to '/srv/data/11223344/f' ok")
    }

    func testACalendarDateSurvives() {
        XCTAssertEqual(scrubbed("build 20261026 is green"), "build 20261026 is green")
        XCTAssertEqual(scrubbed("release-20260101"), "release-20260101")
    }

    func testRealLongNumbersAreStillHidden() {
        XCTAssertEqual(scrubbed("account 21452098"), "account [redacted number]")
        XCTAssertEqual(scrubbed("mi teléfono es 1234567890 por si acaso"), "mi teléfono es [redacted number] por si acaso")
        XCTAssertEqual(scrubbed("call 611234567 now"), "call [redacted number] now")
        // 8 digits that are not a calendar date
        XCTAssertEqual(scrubbed("id 99881234"), "id [redacted number]")
        // a URL is not a file path, whatever it contains
        XCTAssertEqual(scrubbed("https://bank.example/accounts/12345678"), "https://bank.example/accounts/[redacted number]")
    }

    func testANumberOutsideAPathNextToOneIsStillHidden() {
        XCTAssertEqual(scrubbed("/tmp/x and 12345678"), "/tmp/x and [redacted number]")
    }
}

/// Housekeeping the audit asked for: the home must not fill up with empty lock files.
final class LockFileSweepTests: XCTestCase {
    func testIdleLocksAreSweptAndRecentOrHeldOnesAreNot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("locks-\(UUID())")
        let paths = try Paths(home: home).createDirectories()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = Date().addingTimeInterval(-3 * 86_400)
        func lock(_ name: String, in dir: URL, modified: Date) throws -> URL {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let stale = try lock("handoff-abc.lock", in: paths.home, modified: old)
        let staleMarker = try lock("brief-reader-x.lock.lock", in: paths.delivered, modified: old)
        let fresh = try lock("handoff-new.lock", in: paths.home, modified: Date())
        let held = try lock("handoff-held.lock", in: paths.home, modified: old)
        let notALock = paths.home.appendingPathComponent("ledger.jsonl")
        try Data("x".utf8).write(to: notALock)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: notALock.path)

        let descriptor = open(held.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { close(descriptor) }

        XCTAssertEqual(Retention.pruneLocks(paths: paths), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "touched today")
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path), "somebody holds it right now")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notALock.path))
    }
}

final class TestSuiteStaysOutOfTheRealHomeTests: XCTestCase {
    func testWithNoExplicitHomeTheSuiteGetsAScratchDirectory() {
        // This process is the suite: it must not resolve to ~/.gentlemerge.
        if ProcessInfo.processInfo.environment["GENTLEMERGE_HOME"].map({ !$0.isEmpty }) == true { return }
        let home = Paths.fromEnvironment().home.path
        XCTAssertNotEqual(home, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gentlemerge").path)
        XCTAssertTrue(home.contains("gentlemerge-xctest-home"), home)
    }
}
