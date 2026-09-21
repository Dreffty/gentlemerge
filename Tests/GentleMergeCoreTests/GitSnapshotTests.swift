import XCTest
@testable import GentleMergeCore

final class GitSnapshotTests: XCTestCase {
    private var repository: URL!

    override func setUpWithError() throws {
        repository = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        git(["init", "-q"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        try write("README.md", "hello\n")
        try write("Sources/App.swift", "let version = 1\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "first"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repository)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repository, timeout: 30)
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: -

    func testSnapshotAndRestoreBringsFileContentsBack() throws {
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))

        try write("Sources/App.swift", "let version = 2\n")
        let reference = try snapshot.create(label: "before the agent")

        // The agent does its thing.
        try write("Sources/App.swift", "let version = 999\nlet broken = true\n")
        try write("Sources/New.swift", "// created by the agent\n")

        let report = try snapshot.restore(reference)

        XCTAssertEqual(read("Sources/App.swift"), "let version = 2\n")
        XCTAssertTrue(report.restored.contains("Sources/App.swift"))
        // Files the agent created are never deleted behind your back.
        XCTAssertEqual(read("Sources/New.swift"), "// created by the agent\n")
        XCTAssertTrue(report.created.contains("Sources/New.swift"))
    }

    func testRestoringIsItselfUndoable() throws {
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let original = try snapshot.create(label: "original")

        try write("README.md", "rewritten by the agent\n")
        let report = try snapshot.restore(original)

        let safety = try XCTUnwrap(report.safety, "the state being replaced must be captured first")
        XCTAssertEqual(read("README.md"), "hello\n")

        _ = try snapshot.restore(safety)
        XCTAssertEqual(read("README.md"), "rewritten by the agent\n")
    }

    func testSnapshotsNeverTouchYourStagingArea() throws {
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))

        try write("Sources/App.swift", "let version = 2\n")
        try write("untracked.txt", "scratch\n")
        git(["add", "Sources/App.swift"])
        let before = git(["status", "--porcelain"]).stdout

        _ = try snapshot.create(label: "mid-staging")

        XCTAssertEqual(
            git(["status", "--porcelain"]).stdout,
            before,
            "a snapshot must be invisible to whatever you had staged"
        )
    }

    func testSnapshotsCaptureUntrackedFilesButNotIgnoredOnes() throws {
        try write(".gitignore", "build/\n")
        try write("build/artifact.bin", "junk\n")
        try write("scratch.txt", "keep me\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "ignore build"])

        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "with untracked")

        let files = Shell.run(
            "/usr/bin/env",
            ["git", "ls-tree", "-r", "--name-only", reference.commit],
            in: repository
        ).lines

        XCTAssertTrue(files.contains("scratch.txt"))
        XCTAssertFalse(files.contains("build/artifact.bin"), ".gitignore is respected")
    }

    func testListingAndPruning() throws {
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let first = try snapshot.create(label: "one")
        try write("README.md", "changed\n")
        let second = try snapshot.create(label: "two")

        let listed = snapshot.list()
        XCTAssertEqual(Set(listed.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(Set(listed.map(\.label)), Set(["one", "two"]))

        snapshot.prune(keeping: 1)
        XCTAssertEqual(snapshot.list().count, 1)
    }

    func testANonRepositoryIsRefusedRatherThanGuessed() {
        let plain = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-plain-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        XCTAssertNil(GitSnapshot(anyPathInside: plain.path))
        XCTAssertFalse(GitSnapshot.isRepository(plain.path))
    }
}
