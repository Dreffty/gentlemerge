import XCTest
@testable import GentleMergeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `doctor` is what an agent reads when the coordinator may be dead, so its
/// lines must be facts, not vibes: every condition below pins one line.
final class DoctorTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var repo: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-doctor-\(UUID().uuidString)")
        paths = Paths(home: root)
        try paths.createDirectories()
        repo = root.appendingPathComponent("repo")
        _ = try Shell.run("/usr/bin/env", ["git", "init", repo.path], timeout: 15)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func diagnose(gitVersion: String?? = "git version 2.39.0") -> [Doctor.Check] {
        Doctor.run(paths: paths, project: repo.path, repo: repo, gitVersion: gitVersion)
    }

    private func check(_ name: String, in checks: [Doctor.Check]) -> Doctor.Check {
        guard let found = checks.first(where: { $0.name == name }) else {
            XCTFail("no \(name) check in \(checks.map(\.line))")
            return Doctor.Check(name: name, level: .fail, detail: "missing")
        }
        return found
    }

    func testLinesAreGreppable() {
        let line = Doctor.Check(name: "spool", level: .ok, detail: "empty").line
        XCTAssertEqual(line, "ok spool: empty")
    }

    func testMissingHooksWarnInsteadOfFailing() {
        let hooks = check("git-hooks", in: diagnose())
        XCTAssertEqual(hooks.level, .warn)
        XCTAssertTrue(hooks.detail.contains("git-hooks install"), hooks.detail)
    }

    func testInstalledHooksWithoutBinaryWarn() throws {
        _ = try GitHookInstaller(paths: paths).install(repo: repo)
        // Hermetic: the developer machine running this test may or may not
        // have a gate binary installed — point at a path that cannot exist.
        setenv("GENTLEMERGE_BIN", "/nonexistent-gentlemerge-binary", 1)
        defer { unsetenv("GENTLEMERGE_BIN") }
        let hooks = check("git-hooks", in: diagnose())
        XCTAssertEqual(hooks.level, .warn, hooks.detail)
        XCTAssertTrue(hooks.detail.contains("missing"), hooks.detail)
        XCTAssertTrue(hooks.detail.contains("unchecked"), hooks.detail)
    }

    func testInstalledHooksWithBinaryReportOk() throws {
        _ = try GitHookInstaller(paths: paths).install(repo: repo)
        let fake = root.appendingPathComponent("gentlemerge")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("GENTLEMERGE_BIN", fake.path, 1)
        defer { unsetenv("GENTLEMERGE_BIN") }
        let hooks = check("git-hooks", in: diagnose())
        XCTAssertEqual(hooks.level, .ok, hooks.detail)
        XCTAssertTrue(hooks.detail.contains("post-commit"), hooks.detail)
    }

    func testOldGitWarnsWithTheVersion() {
        let git = check("git", in: diagnose(gitVersion: "git version 2.34.1 (Ubuntu)"))
        XCTAssertEqual(git.level, .warn)
        XCTAssertTrue(git.detail.contains("2.34.1"), git.detail)
    }

    func testNewGitReportsOk() {
        let git = check("git", in: diagnose(gitVersion: "git version 2.55.0"))
        XCTAssertEqual(git.level, .ok)
    }

    func testUnreadableGitWarns() {
        let git = check("git", in: diagnose(gitVersion: .some(nil)))
        XCTAssertEqual(git.level, .warn)
        XCTAssertTrue(git.detail.contains("could not read"), git.detail)
    }

    func testStuckSpoolWarns() throws {
        let file = paths.spool.appendingPathComponent("old.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: file.path
        )
        let spool = check("spool", in: diagnose())
        XCTAssertEqual(spool.level, .warn, spool.detail)
        XCTAssertTrue(spool.detail.contains("1 queued"), spool.detail)
    }

    func testEmptySpoolIsOk() {
        XCTAssertEqual(check("spool", in: diagnose()).level, .ok)
    }

    func testUnwritableHomeFails() throws {
        #if canImport(Darwin)
        if geteuid() == 0 { throw XCTSkip("running as root: permission bits do not apply") }
        #elseif canImport(Glibc)
        if geteuid() == 0 { throw XCTSkip("running as root: permission bits do not apply") }
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.home.path)
        // Restore so tearDown can clean up even when the assert fails.
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.home.path) }
        let home = check("home-writable", in: diagnose())
        XCTAssertEqual(home.level, .fail, home.detail)
    }

    func testUnpinnedOwnershipWarns() throws {
        let dir = repo.appendingPathComponent(".gentlemerge", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("# r — agent handoff\n\n## Ownership\n\n- assets/** → codex\n".utf8)
            .write(to: dir.appendingPathComponent("HANDOFF.md"))
        let ownership = check("ownership", in: diagnose())
        XCTAssertEqual(ownership.level, .warn, ownership.detail)
        XCTAssertTrue(ownership.detail.contains("ownership pin"), ownership.detail)
    }

    func testQuietMachineStillReportsOk() {        let checks = diagnose()
        XCTAssertEqual(check("presence", in: checks).level, .ok)
        XCTAssertEqual(check("app", in: checks).level, .ok)
        XCTAssertEqual(check("clock", in: checks).level, .ok)
        XCTAssertFalse(checks.contains(where: { $0.level == .fail }), "\(checks.map(\.line))")
    }
}
