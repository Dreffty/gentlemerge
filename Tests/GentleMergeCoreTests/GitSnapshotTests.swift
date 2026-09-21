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

        XCTAssertEqual(read("README.md"), "hello\n")

        _ = try snapshot.restore(report.safety)
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

    func testRestoreRefusesAFileSymlinkPointingOutside() throws {
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        try write("file.txt", "original\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "with file"])
        let reference = try snapshot.create(label: "before")

        // The file is now a symlink to the outside. Restoring must refuse
        // instead of writing the snapshot bytes through it.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-outside-\(UUID().uuidString).txt")
        try Data("do not touch\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: repository.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(
            at: repository.appendingPathComponent("file.txt"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try snapshot.restore(reference)) { error in
            guard case SnapshotError.refusesSymlink = error else {
                return XCTFail("expected refusesSymlink, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "do not touch\n")
    }

    func testRestoreRefusesADirectorySymlinkPointingOutside() throws {
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: repository.path))
        let reference = try snapshot.create(label: "before")

        // Sources/ becomes a symlink outward. Anything restored under it
        // would land outside the checkout.
        let outsideDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try FileManager.default.removeItem(at: repository.appendingPathComponent("Sources"))
        try FileManager.default.createSymbolicLink(
            at: repository.appendingPathComponent("Sources"),
            withDestinationURL: outsideDir
        )

        XCTAssertThrowsError(try snapshot.restore(reference)) { error in
            guard case SnapshotError.refusesSymlink = error else {
                return XCTFail("expected refusesSymlink, got \(error)")
            }
        }
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: outsideDir.path))?.isEmpty ?? false,
            "nothing may be written outside the checkout"
        )
    }
}
