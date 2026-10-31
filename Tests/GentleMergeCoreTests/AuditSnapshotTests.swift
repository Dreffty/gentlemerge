import XCTest
@testable import GentleMergeCore

/// What a restore gave back was not what the snapshot held: a script lost its
/// executable bit, a symlink came back as a text file, and the report listed a
/// restored directory as "left in place".
final class SnapshotRestoreFidelityTests: XCTestCase {
    private var repository: URL!
    private var manager: FileManager { .default }

    override func setUpWithError() throws {
        repository = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-snapfid-\(UUID().uuidString)")
        try manager.createDirectory(at: repository, withIntermediateDirectories: true)
        git(["init", "-q"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws { try? manager.removeItem(at: repository) }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repository, timeout: 30)
    }

    private func url(_ path: String) -> URL { repository.appendingPathComponent(path) }

    private func write(_ path: String, _ contents: String, mode: Int? = nil) throws {
        try manager.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url(path))
        if let mode { try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url(path).path) }
    }

    private func permissions(_ path: String) throws -> Int {
        try XCTUnwrap(manager.attributesOfItem(atPath: url(path).path)[.posixPermissions] as? Int)
    }

    private func commitAll() { git(["add", "-A"]); git(["commit", "-q", "-m", "c"]) }

    func testARestoredScriptIsStillExecutable() throws {
        try write("run.sh", "#!/bin/sh\necho hi\n", mode: 0o755)
        try write("plain.txt", "x\n", mode: 0o644)
        commitAll()
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "before")

        try manager.removeItem(at: url("run.sh"))
        try manager.removeItem(at: url("plain.txt"))
        _ = try snapshot.restore(reference)

        XCTAssertNotEqual(try permissions("run.sh") & 0o111, 0, "the executable bit was lost")
        XCTAssertEqual(try permissions("plain.txt") & 0o111, 0, "a plain file must not become executable")
        XCTAssertTrue(git(["status", "--porcelain"]).stdout.isEmpty,
                      "git sees a difference after restoring: \(git(["status", "--porcelain"]).stdout)")
    }

    func testARestoredSymlinkIsStillASymlink() throws {
        try write("real.txt", "data\n")
        try manager.createSymbolicLink(atPath: url("link").path, withDestinationPath: "real.txt")
        commitAll()
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "before")

        try manager.removeItem(at: url("link"))
        _ = try snapshot.restore(reference)
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: url("link").path), "real.txt")

        // Pointing somewhere else now: the link is replaced as a link, and what
        // it pointed at is untouched.
        try manager.removeItem(at: url("link"))
        try manager.createSymbolicLink(atPath: url("link").path, withDestinationPath: "elsewhere")
        _ = try snapshot.restore(reference)
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: url("link").path), "real.txt")
        XCTAssertTrue(git(["status", "--porcelain"]).stdout.isEmpty)
    }

    func testARestoredDirectoryIsNotAlsoLeftInPlace() throws {
        try write("d/a.txt", "1\n")
        try write("keep.txt", "k\n")
        commitAll()
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "before")

        git(["rm", "-rq", "d"])
        let report = try snapshot.restore(reference)

        XCTAssertEqual(report.restored, ["d/a.txt"])
        XCTAssertEqual(report.created, [], "d/a.txt was written back; it is not a new file")
    }

    func testNewFilesWithAccentsAreListedByTheirRealName() throws {
        try write("a.txt", "a\n")
        commitAll()
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "before")

        try write("ñandú nuevo.txt", "n\n")
        try write("sub dir/otro \"raro\".txt", "o\n")
        let report = try snapshot.restore(reference)

        XCTAssertEqual(report.created, ["ñandú nuevo.txt", "sub dir/otro \"raro\".txt"].sorted())
    }

    /// One path the restore will not write must stop it before it writes any.
    func testARefusalLeavesTheWorkingTreeUntouched() throws {
        try write("a.txt", "original a\n")
        try write("src/b.txt", "original b\n")
        commitAll()
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "before")

        try write("a.txt", "edited a\n")
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-snapfid-out-\(UUID().uuidString)")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: outside) }
        try manager.removeItem(at: url("src"))
        try manager.createSymbolicLink(at: url("src"), withDestinationURL: outside)

        XCTAssertThrowsError(try snapshot.restore(reference))
        XCTAssertEqual(try String(contentsOf: url("a.txt"), encoding: .utf8), "edited a\n",
                       "a.txt was restored although the restore refused as a whole")
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testASubmoduleIsSkippedNotFatal() throws {
        try write("a.txt", "a\n")
        git(["update-index", "--add", "--cacheinfo", "160000,1111111111111111111111111111111111111111,sub"])
        git(["commit", "-q", "-m", "with submodule"])
        try write("a.txt", "edited\n")
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "before")
        try write("a.txt", "edited again\n")

        let report = try snapshot.restore(reference)

        XCTAssertEqual(try String(contentsOf: url("a.txt"), encoding: .utf8), "edited\n")
        XCTAssertTrue(report.restored.contains("a.txt"))
        XCTAssertFalse(report.restored.contains("sub"), "a submodule has no files to write back")
    }
}
