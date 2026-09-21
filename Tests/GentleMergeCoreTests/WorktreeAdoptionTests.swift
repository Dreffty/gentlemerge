import XCTest
@testable import GentleMergeCore

/// Fixing identity stops the silos forming. These cover going back for what the
/// silos already collected — fifteen open tasks, in the case that prompted it.
final class WorktreeAdoptionTests: XCTestCase {
    private var repository: URL!
    private var worktree: URL!
    private var registryURL: URL!

    override func setUpWithError() throws {
        repository = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        try Data("hello\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        git(["add", "-A"])
        git(["commit", "-q", "-m", "first"])

        worktree = repository.appendingPathComponent(".claude/worktrees/feature-x")
        git(["worktree", "add", "-q", "-b", "feature-x", worktree.path])

        registryURL = repository.appendingPathComponent("projects.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repository)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repository, timeout: 30)
    }

    /// Writes a handoff at a literal path. `save` files by the handoff's own
    /// `projectPath`, which is the only way left to create a worktree-local one
    /// now that identity resolves past it — which is the point.
    private func writeHandoff(at path: String, tasks: [TaskItem]) {
        ProjectRegistry.save(ProjectHandoff(projectPath: path, tasks: tasks))
    }

    /// Seeds the registry file the way the old binary wrote it — one entry per
    /// checkout — and loads it back through the real decoder.
    private func seedRegistry(_ summaries: [ProjectSummary]) throws -> ProjectRegistry {
        try JSONCoding.encoder(pretty: true).encode(summaries).write(to: registryURL)
        return ProjectRegistry(url: registryURL)
    }

    private func openTaskTexts(at path: String) -> [String] {
        ProjectRegistry.handoff(for: path, refreshingCommits: false).openTasks.map(\.text)
    }

    // MARK: - Listing

    func testTheMainCheckoutIsNotOneOfItsOwnWorktrees() {
        let listed = WorktreeAdoption.linkedWorktrees(of: repository.path)
        XCTAssertEqual(listed, [PathExtractor.normalized(worktree.path)])
    }

    func testWorktreeListIgnoresEverythingThatIsNotAPath() {
        let raw = """
        worktree /repo
        HEAD abc123
        branch refs/heads/main

        worktree /repo/.claude/worktrees/x
        HEAD def456
        detached
        """
        XCTAssertEqual(
            WorktreeAdoption.parseWorktreeList(raw, excluding: "/repo"),
            ["/repo/.claude/worktrees/x"]
        )
    }

    // MARK: - Adopting

    func testOpenTasksLeftInAWorktreeComeHome() throws {
        writeHandoff(at: repository.path, tasks: [TaskItem(text: "already here")])
        writeHandoff(
            at: worktree.path,
            tasks: [
                TaskItem(text: "left behind in the worktree", addedBy: "claude"),
                TaskItem(text: "also left behind"),
            ]
        )

        let report = WorktreeAdoption.adopt(repository: repository.path, registryURL: registryURL)

        XCTAssertEqual(report.tasksAdopted, 2)
        XCTAssertEqual(report.sources.count, 1)
        XCTAssertEqual(
            Set(openTaskTexts(at: repository.path)),
            ["already here", "left behind in the worktree", "also left behind"]
        )
    }

    func testWhoLeftATaskSurvivesTheMove() throws {
        writeHandoff(at: worktree.path, tasks: [TaskItem(text: "mine", addedBy: "codex")])
        WorktreeAdoption.adopt(repository: repository.path, registryURL: registryURL)

        let adopted = ProjectRegistry.handoff(for: repository.path, refreshingCommits: false)
            .openTasks.first { $0.text == "mine" }
        XCTAssertEqual(adopted?.addedBy, "codex")
    }

    /// Finished work is history the worktree can keep. Carrying it over would
    /// bury the live list under everything six sessions ever ticked off.
    func testFinishedTasksAreLeftWhereTheyAre() throws {
        writeHandoff(
            at: worktree.path,
            tasks: [TaskItem(text: "done and dusted", done: true), TaskItem(text: "still open")]
        )

        let report = WorktreeAdoption.adopt(repository: repository.path, registryURL: registryURL)

        XCTAssertEqual(report.tasksAdopted, 1)
        XCTAssertEqual(openTaskTexts(at: repository.path), ["still open"])
    }

    func testAdoptingTwiceAdoptsNothingTheSecondTime() throws {
        writeHandoff(at: worktree.path, tasks: [TaskItem(text: "only once")])

        let first = WorktreeAdoption.adopt(repository: repository.path, registryURL: registryURL)
        let second = WorktreeAdoption.adopt(repository: repository.path, registryURL: registryURL)

        XCTAssertEqual(first.tasksAdopted, 1)
        XCTAssertEqual(second.tasksAdopted, 0)
        XCTAssertEqual(openTaskTexts(at: repository.path), ["only once"])
    }

    func testAWorktreeWithNoHandoffIsNotAnError() throws {
        let report = WorktreeAdoption.adopt(repository: repository.path, registryURL: registryURL)
        XCTAssertEqual(report.tasksAdopted, 0)
        XCTAssertTrue(report.sources.isEmpty)
    }

    /// The worktree file is never deleted: it stops being the only copy, it does
    /// not stop existing.
    func testTheWorktreeKeepsItsOwnCopy() throws {
        writeHandoff(at: worktree.path, tasks: [TaskItem(text: "carried over")])
        WorktreeAdoption.adopt(repository: repository.path, registryURL: registryURL)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ProjectHandoff.fileURL(for: worktree.path).path)
        )
    }

    // MARK: - Folding the registry

    func testAWorktreeStopsBeingAProjectOfItsOwn() throws {
        var registry = try seedRegistry([
            ProjectSummary(path: repository.path, name: "repo", lastSeenAt: Date(timeIntervalSince1970: 1_000)),
            ProjectSummary(path: worktree.path, name: "feature-x", lastSeenAt: Date(timeIntervalSince1970: 2_000)),
        ])

        let folded = registry.foldWorktrees()

        XCTAssertEqual(folded, [worktree.path])
        XCTAssertEqual(registry.projects.map(\.path), [PathExtractor.normalized(repository.path)])
        // The worktree was the one seen most recently; the repository inherits
        // that, or the project drops down the list for no reason.
        XCTAssertEqual(registry.projects.first?.lastSeenAt, Date(timeIntervalSince1970: 2_000))
    }

    func testFoldingLeavesRepositoriesAlone() throws {
        var registry = try seedRegistry([
            ProjectSummary(path: repository.path, name: "repo", lastSeenAt: Date())
        ])
        XCTAssertTrue(registry.foldWorktrees().isEmpty)
        XCTAssertEqual(registry.projects.count, 1)
    }

    /// Folding has to happen, because the cache in front of `canonicalPath`
    /// resolves by longest known prefix — and a stale worktree entry is a
    /// longer match than the repository that contains it.
    func testASessionInAWorktreeLandsOnTheRepositoryAfterFolding() throws {
        var registry = try seedRegistry([
            ProjectSummary(path: worktree.path, name: "feature-x", lastSeenAt: Date())
        ])
        registry.foldWorktrees()

        let landed = registry.seen(path: worktree.path, provider: nil, at: Date())
        XCTAssertEqual(landed, PathExtractor.normalized(repository.path))
    }
}
