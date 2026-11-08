import XCTest
@testable import GentleMergeCore

/// `gentlemerge precommit` run in a linked worktree is about that worktree.
///
/// It resolved the directory to the repository's main checkout first, because that
/// is what a project is. A worktree full of changes answered "Nothing uncommitted",
/// so the one check every agent is told to run before committing checked somebody
/// else's desk. Found while working from a worktree on the 2026-11-07 review.
final class PrecommitWorktreeTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var worktree: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("precommit-wt-\(UUID())")
        repo = root.appendingPathComponent("repo")
        worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"]] {
            _ = Shell.run("/usr/bin/env", ["git"] + arguments, in: repo)
        }
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = Shell.run("/usr/bin/env", ["git", "add", "-A"], in: repo)
        _ = Shell.run("/usr/bin/env", ["git", "commit", "-qm", "base"], in: repo)
        _ = Shell.run("/usr/bin/env", ["git", "worktree", "add", "-q", "-b", "side", worktree.path], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func precommit(in directory: URL) -> Shell.Output {
        Shell.run(binary, ["precommit"], in: directory,
                  environment: ["GENTLEMERGE_HOME": root.appendingPathComponent("home").path])
    }

    func testAWorktreesOwnChangesAreWhatItReportsOn() throws {
        try Data("changed here\n".utf8).write(to: worktree.appendingPathComponent("a.txt"))

        let there = precommit(in: worktree)
        XCTAssertEqual(there.status, 0, there.text)
        XCTAssertFalse(there.stdout.contains("Nothing uncommitted"), there.stdout)
        XCTAssertTrue(there.stdout.contains("1 file uncommitted"), there.stdout)

        // And the main checkout, untouched, still says it has nothing.
        XCTAssertTrue(precommit(in: repo).stdout.contains("Nothing uncommitted"))
    }
}
