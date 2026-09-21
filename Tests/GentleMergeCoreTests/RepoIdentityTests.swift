import XCTest
@testable import GentleMergeCore

/// The bug these exist for: five agents in five worktrees of one repository
/// were five projects. A collision warning addressed to one of them by branch
/// name was filed where nobody would read it.
final class RepoIdentityTests: XCTestCase {
    private var repository: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        repository = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        try Data("hello\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        git(["add", "-A"])
        git(["commit", "-q", "-m", "first"])

        // Nested on purpose: this is where Claude Code puts them, and a nested
        // worktree is also the case that fools a longest-prefix cache.
        worktree = repository
            .appendingPathComponent(".claude/worktrees/feature-x")
        git(["worktree", "add", "-q", "-b", "feature-x", worktree.path])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repository)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repository, timeout: 30)
    }

    private var repositoryPath: String { PathExtractor.normalized(repository.path) }

    // MARK: - The regression itself

    func testAWorktreeIsTheSameProjectAsItsRepository() throws {
        XCTAssertEqual(RepoIdentity.mainWorktreeRoot(for: worktree.path), repositoryPath)
        XCTAssertEqual(RepoIdentity.mainWorktreeRoot(for: repository.path), repositoryPath)
    }

    func testProjectIdentityAgreesFromEitherCheckout() throws {
        XCTAssertEqual(
            ProjectRegistry.canonicalPath(for: worktree.path),
            ProjectRegistry.canonicalPath(for: repository.path)
        )
    }

    func testASubdirectoryOfAWorktreeStillLandsOnTheRepository() throws {
        let nested = worktree.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(ProjectRegistry.canonicalPath(for: nested.path), repositoryPath)
    }

    func testOnlyTheLinkedCheckoutCountsAsAWorktree() throws {
        XCTAssertTrue(RepoIdentity.isLinkedWorktree(worktree.path))
        XCTAssertFalse(RepoIdentity.isLinkedWorktree(repository.path))
    }

    /// A snapshot restores the tree you are standing in, so this one must keep
    /// answering with the worktree even though identity no longer does.
    func testSnapshotsStillSeeTheWorktreeTheyAreIn() throws {
        let snapshot = try XCTUnwrap(GitSnapshot(anyPathInside: worktree.path))
        XCTAssertEqual(
            PathExtractor.normalized(snapshot.repository.path),
            PathExtractor.normalized(worktree.path)
        )
    }

    // MARK: - The rule, without a repository

    func testCollapseTakesTheDirectoryHoldingTheSharedGitDirectory() {
        XCTAssertEqual(
            RepoIdentity.collapse(
                commonDirectory: repository.appendingPathComponent(".git").path,
                toplevel: worktree.path
            ),
            repositoryPath
        )
    }

    /// A submodule's shared directory lives at `…/.git/modules/<name>`, whose
    /// parent is not a checkout. Collapsing there would file the submodule
    /// under a directory nobody works in.
    func testASubmoduleKeepsItsOwnCheckout() {
        XCTAssertEqual(
            RepoIdentity.collapse(
                commonDirectory: repository.appendingPathComponent(".git/modules/vendor").path,
                toplevel: worktree.path
            ),
            PathExtractor.normalized(worktree.path)
        )
    }

    /// Same for a bare repository, where the shared directory is `repo.git`.
    func testABareRepositoryKeepsItsOwnCheckout() {
        XCTAssertEqual(
            RepoIdentity.collapse(
                commonDirectory: repository.appendingPathComponent("thing.git").path,
                toplevel: worktree.path
            ),
            PathExtractor.normalized(worktree.path)
        )
    }

    /// `.git` that resolves to nothing on disk is not somewhere to file a
    /// project either.
    func testAMissingParentKeepsItsOwnCheckout() {
        XCTAssertEqual(
            RepoIdentity.collapse(
                commonDirectory: "/nowhere/at/all/.git",
                toplevel: worktree.path
            ),
            PathExtractor.normalized(worktree.path)
        )
    }

    func testAPathOutsideAnyRepositoryHasNoIdentity() {
        XCTAssertNil(RepoIdentity.mainWorktreeRoot(for: NSTemporaryDirectory()))
    }
}
