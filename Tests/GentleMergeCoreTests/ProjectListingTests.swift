import XCTest
@testable import GentleMergeCore

/// Which projects get remembered, and which get a row.
///
/// Of 17 projects on a real machine, 10 were scratch folders and `/tmp`, while
/// FocusDesk, escudero and usal-bot were missing: once a session had opened in a parent
/// folder, every repository inside it was filed under that folder and never listed.
final class ProjectListingTests: XCTestCase {
    private var root: URL!
    private var registryFile: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("listing-\(UUID())")
        registryFile = root.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeRepository(_ name: String) throws -> URL {
        let folder = try makeFolder(name)
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "init", "-q", "-b", "main"], in: folder).status, 0)
        return folder
    }

    private func normalized(_ url: URL) -> String { PathExtractor.normalized(url.path) }

    // MARK: - Which project a path belongs to

    func testARepositoryInsideAKnownFolderIsItsOwnProject() throws {
        let parent = try makeFolder("Side Projects")
        let repository = try makeRepository("Side Projects/FocusDesk")
        let nested = try makeFolder("Side Projects/FocusDesk/Sources/Deep")
        var registry = ProjectRegistry(url: registryFile)

        XCTAssertEqual(registry.seen(path: parent.path, provider: nil, at: Date()), normalized(parent))
        XCTAssertEqual(registry.seen(path: repository.path, provider: nil, at: Date()), normalized(repository))
        XCTAssertEqual(registry.seen(path: nested.path, provider: nil, at: Date()), normalized(repository))

        XCTAssertEqual(Set(registry.projects.map(\.path)), [normalized(parent), normalized(repository)])
    }

    func testAPlainFolderInsideAKnownOneStaysThere() throws {
        let parent = try makeFolder("Side Projects")
        let plain = try makeFolder("Side Projects/notes")
        var registry = ProjectRegistry(url: registryFile)
        _ = registry.seen(path: parent.path, provider: nil, at: Date())

        XCTAssertEqual(registry.seen(path: plain.path, provider: nil, at: Date()), normalized(parent))
        XCTAssertEqual(registry.projects.count, 1)
    }

    /// A linked worktree carries a `.git` of its own, and is still the same project.
    func testAWorktreeInsideAKnownRepositoryIsThatRepository() throws {
        let repository = try makeRepository("repo")
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "-c", "user.email=t@e.invalid", "-c", "user.name=t",
                                                  "commit", "-q", "--allow-empty", "-m", "base"], in: repository).status, 0)
        let worktree = repository.appendingPathComponent(".claude/worktrees/x")
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "worktree", "add", "-q", "-b", "x", worktree.path], in: repository).status, 0)
        var registry = ProjectRegistry(url: registryFile)
        _ = registry.seen(path: repository.path, provider: nil, at: Date())

        XCTAssertEqual(registry.seen(path: worktree.path, provider: nil, at: Date()), normalized(repository))
        XCTAssertEqual(registry.projects.count, 1)
    }

    // MARK: - Which ones get a row

    private func summary(_ path: String, seen age: TimeInterval = 0, established: Bool? = false) -> ProjectSummary {
        ProjectSummary(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                       lastSeenAt: Date(timeIntervalSinceNow: -age), isEstablished: established)
    }

    private let aMonth: TimeInterval = 30 * 24 * 3600

    func testARepositoryIsListedHoweverLongAgoItWasSeen() {
        XCTAssertTrue(summary("/Users/x/app", seen: aMonth, established: true).isListed())
    }

    func testAPlainFolderIsListedWhileItIsRecentAndNotAfter() {
        XCTAssertTrue(summary("/Users/x/notes", seen: 3600).isListed())
        XCTAssertFalse(summary("/Users/x/notes", seen: aMonth).isListed())
    }

    func testScratchFoldersAreNeverListedHoweverRecent() {
        for path in ["/tmp", "/private/tmp/x", "/var/folders/ab/T/y",
                     "/Users/x/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-2026-11-06-41bfd2"] {
            XCTAssertFalse(summary(path).isListed(), path)
        }
    }

    /// A scratch folder somebody turned into a repository has stopped being scratch.
    func testAScratchFolderWithARepositoryIsListed() {
        XCTAssertTrue(summary("/tmp/real", established: true).isListed())
    }

    /// An entry from before this was kept: not looked at yet, so not hidden yet.
    func testAnEntryNobodyHasLookedAtStaysListed() {
        XCTAssertTrue(summary("/Users/x/notes", seen: aMonth, established: nil).isListed())
        XCTAssertFalse(summary("/tmp", seen: aMonth, established: nil).isListed())
    }

    /// A handoff is somebody's work: a list of open tasks must not vanish with the folder's
    /// last session.
    func testAPlainFolderWithAHandoffCountsAsEstablished() throws {
        let plain = try makeFolder("Marca personal")
        XCTAssertFalse(ProjectRegistry.isEstablished(plain.path))
        try FileManager.default.createDirectory(at: plain.appendingPathComponent(".gentlemerge"), withIntermediateDirectories: true)
        try Data("# x\n".utf8).write(to: ProjectHandoff.fileURL(for: plain.path))
        XCTAssertTrue(ProjectRegistry.isEstablished(plain.path))
    }

    func testSeeingAProjectNotesWhetherItIsEstablished() throws {
        let repository = try makeRepository("repo")
        let plain = try makeFolder("plain")
        var registry = ProjectRegistry(url: registryFile)
        _ = registry.seen(path: repository.path, provider: nil, at: Date())
        _ = registry.seen(path: plain.path, provider: nil, at: Date())

        let reloaded = ProjectRegistry(url: registryFile)
        XCTAssertEqual(reloaded.projects.first { $0.path == normalized(repository) }?.isEstablished, true)
        XCTAssertEqual(reloaded.projects.first { $0.path == normalized(plain) }?.isEstablished, false)
    }

    func testRefreshingSettlesOldEntries() throws {
        let repository = try makeRepository("repo")
        let old = #"[{"path":"\#(normalized(repository))","name":"repo","lastSeenAt":"2026-01-01T00:00:00Z"}]"#
        try Data(old.utf8).write(to: registryFile)
        var registry = ProjectRegistry(url: registryFile)
        XCTAssertNil(registry.projects.first?.isEstablished)

        registry.refreshEstablished()

        XCTAssertEqual(registry.projects.first?.isEstablished, true)
        XCTAssertEqual(ProjectRegistry(url: registryFile).projects.first?.isEstablished, true, "and it stays")
    }

    @MainActor
    func testTheWindowListsTheSameOnes() async throws {
        let repository = try makeRepository("repo")
        let plain = try makeFolder("plain")
        let paths = Paths(home: root.appendingPathComponent("home"))
        var registry = ProjectRegistry(url: paths.projects)
        try paths.createDirectories()
        _ = registry.seen(path: repository.path, provider: nil, at: Date())
        _ = registry.seen(path: plain.path, provider: nil, at: Date())

        let model = InboxModel(paths: paths)
        XCTAssertEqual(model.projects.count, 2)
        // `plain` lives under the system's temporary folder, so it is scratch here.
        XCTAssertEqual(model.visibleProjects.map(\.path), [normalized(repository)])
    }

    // MARK: - From the command line

    func testTheCommandHidesScratchAndSaysSo() throws {
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path
        let home = root.appendingPathComponent("home")
        let repository = try makeRepository("repo")
        let plain = try makeFolder("plain")
        let paths = Paths(home: home)
        try paths.createDirectories()
        var registry = ProjectRegistry(url: paths.projects)
        _ = registry.seen(path: repository.path, provider: nil, at: Date())
        _ = registry.seen(path: plain.path, provider: nil, at: Date())
        let environment = ["GENTLEMERGE_HOME": home.path]

        let listed = Shell.run(binary, ["projects"], in: root, environment: environment)
        XCTAssertEqual(listed.status, 0, listed.text)
        XCTAssertTrue(listed.stdout.contains(normalized(repository)), listed.stdout)
        XCTAssertFalse(listed.stdout.contains(normalized(plain)), listed.stdout)
        XCTAssertTrue(listed.stdout.contains("1 more"), listed.stdout)
        XCTAssertTrue(listed.stdout.contains("--all"), listed.stdout)

        let all = Shell.run(binary, ["projects", "--all"], in: root, environment: environment)
        XCTAssertEqual(all.status, 0, all.text)
        XCTAssertTrue(all.stdout.contains(normalized(plain)), all.stdout)
    }
}
