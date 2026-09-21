import XCTest
@testable import GentleMergeCore

/// The conflict radar: which branch pairs would collide, announced once.
final class ConflictRadarTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var counter = 0

    private var paths: Paths { Paths(home: home) }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-radar-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: [String], in repo: URL) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repo, timeout: 30)
    }

    private func write(_ contents: String, to name: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func commit(_ message: String, in repo: URL) {
        git(["add", "-A"], in: repo)
        git(["commit", "-qm", message], in: repo)
    }

    private func makeRepo() throws -> URL {
        counter += 1
        let repo = root.appendingPathComponent("repo-\(counter)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repo)
        git(["config", "user.email", "t@example.com"], in: repo)
        git(["config", "user.name", "Test"], in: repo)
        try write("base\n", to: "f.txt", in: repo)
        commit("base", in: repo)
        return repo
    }

    private func busMessages() -> [AgentMessage] {
        AgentBus(paths: paths).messages()
    }

    // MARK: - Pure parts

    func testCandidatesMergeAgentBranchesAndLiveSessions() {
        XCTAssertEqual(
            ConflictRadar.candidates(agent: ["agent/b", "agent/a"], presenceBranches: ["feature/x", "agent/a", ""]),
            ["agent/a", "agent/b", "feature/x"]
        )
    }

    func testOverlapNeedsASharedPath() {
        XCTAssertTrue(ConflictRadar.overlaps(["a.swift", "b.swift"], ["b.swift", "c.swift"]))
        XCTAssertFalse(ConflictRadar.overlaps(["a.swift"], ["b.swift"]))
        XCTAssertFalse(ConflictRadar.overlaps([], ["b.swift"]))
    }

    func testSignatureWithABaseReAnnouncesAfterARebase() {
        let plain = ConflictRadar.signature(branchA: "agent/a", branchB: "main", paths: ["f.txt"])
        XCTAssertEqual(plain, ConflictRadar.signature(branchA: "agent/a", branchB: "main", paths: ["f.txt"], base: nil),
            "no base is the old signature: old state files keep working")
        XCTAssertNotEqual(plain, ConflictRadar.signature(branchA: "agent/a", branchB: "main", paths: ["f.txt"], base: "abc123"))
    }

    func testAgentBranchesFiltersAndSorts() {
        XCTAssertEqual(
            ConflictRadar.agentBranches(from: ["main", "agent/b", "agent/a", "origin/agent/c", "agent/"]),
            ["agent/a", "agent/b"]
        )
    }

    func testPairsAreOrderedAndComplete() {
        let found = ConflictRadar.pairs(of: ["agent/c", "agent/a", "agent/b"])
        XCTAssertEqual(found.count, 3)
        for (first, second) in found { XCTAssertLessThan(first, second) }
        XCTAssertTrue(found.contains { $0 == ("agent/a", "agent/b") })
    }

    func testWindowsRotateThroughEveryPairBeforeRepeating() {
        let all = [("a", "b"), ("a", "c"), ("b", "c")]
        let first = ConflictRadar.window(of: all, offset: 0, cap: 2)
        XCTAssertEqual(first.selected.map { "\($0.0)\($0.1)" }, ["ab", "ac"])
        let second = ConflictRadar.window(of: all, offset: first.nextOffset, cap: 2)
        XCTAssertEqual(second.selected.map { "\($0.0)\($0.1)" }, ["bc", "ab"])
        let whole = ConflictRadar.window(of: all, offset: 0, cap: 64)
        XCTAssertEqual(whole.selected.count, 3)
        XCTAssertEqual(whole.nextOffset, 0)
    }

    func testParseMergeTreeNameOnly() {
        let conflicted = "9121aa654b9dd0c4f12d81b5b8184a7bc6b9151f\nb.txt\na.txt\n"
        XCTAssertEqual(ConflictRadar.parseMergeTreeNameOnly(conflicted), ["a.txt", "b.txt"])
        XCTAssertEqual(ConflictRadar.parseMergeTreeNameOnly("9121aa654b9dd0c4f12d81b5b8184a7bc6b9151f\n"), [])
    }

    func testSignatureIgnoresOrderButNotPaths() {
        let forward = ConflictRadar.signature(branchA: "agent/a", branchB: "agent/b", paths: ["f.txt"])
        let backward = ConflictRadar.signature(branchA: "agent/b", branchB: "agent/a", paths: ["f.txt"])
        XCTAssertEqual(forward, backward)
        XCTAssertNotEqual(
            forward,
            ConflictRadar.signature(branchA: "agent/a", branchB: "agent/b", paths: ["g.txt"])
        )
    }

    func testLabelStripsThePrefix() {
        XCTAssertEqual(ConflictRadar.label(forBranch: "agent/claude"), "claude")
        XCTAssertEqual(ConflictRadar.label(forBranch: "main"), "main")
    }

    func testWarningTextNamesTheOtherSide() {
        let text = ConflictRadar.warningText(other: "agent/b", paths: ["f.txt"])
        XCTAssertTrue(text.contains("will conflict with agent/b"))
        XCTAssertTrue(text.contains("f.txt"))
        XCTAssertTrue(text.contains("Coordinate before landing."))
    }

    func testGitVersionParsingAndMinimum() {
        XCTAssertEqual(
            ConflictRadar.parseGitVersion("git version 2.50.1 (Apple Git-155)\n").map { "\($0.0).\($0.1).\($0.2)" },
            "2.50.1"
        )
        XCTAssertNil(ConflictRadar.parseGitVersion("not git at all"))
        XCTAssertFalse(ConflictRadar.supportsMergeTree(version: (2, 37, 9)))
        XCTAssertTrue(ConflictRadar.supportsMergeTree(version: (2, 38, 0)))
        XCTAssertTrue(ConflictRadar.supportsMergeTree(version: (3, 0, 0)))
    }

    func testStateForgivesKeysFromANewerBinary() throws {
        let repo = try makeRepo()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"lastRun":{},"announced":{},"future":{"x":1}}"#.utf8).write(to: paths.radar)
        let result = ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true)
        XCTAssertEqual(result, .nothingToDo)
    }

    // MARK: - Sweeps over a real repository

    private func conflictingRepo() throws -> URL {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "f.txt", in: repo)
        commit("alice", in: repo)
        git(["checkout", "-qb", "agent/bob", "main"], in: repo)
        try write("bob\n", to: "f.txt", in: repo)
        commit("bob", in: repo)
        return repo
    }

    /// Two branches touching the same line: both sides hear about it exactly
    /// once, no matter how many sweeps see the same conflict.
    func testConflictingBranchesAnnounceOnce() throws {
        let repo = try conflictingRepo()

        let first = ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true)
        XCTAssertEqual(first, .done(announced: 1, pairs: 1))

        let posted = busMessages()
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(Set(posted.compactMap(\.to)), ["alice", "bob"])
        XCTAssertTrue(posted.allSatisfy { $0.text.contains("will conflict with") })
        XCTAssertTrue(posted.allSatisfy { $0.toBranch?.hasPrefix("agent/") == true })

        let second = ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true)
        XCTAssertEqual(second, .done(announced: 0, pairs: 1))
        XCTAssertEqual(busMessages().count, 2)

        XCTAssertEqual(ConflictRadar.sweep(project: repo.path, paths: paths), .throttled)
    }

    func testCleanPairAnnouncesNothing() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        git(["checkout", "-qb", "agent/bob", "main"], in: repo)
        try write("bob\n", to: "b.txt", in: repo)
        commit("bob", in: repo)

        XCTAssertEqual(
            ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true),
            .done(announced: 0, pairs: 1)
        )
        XCTAssertTrue(busMessages().isEmpty)
    }

    func testFewerThanTwoBranchesIsNothingToDo() throws {
        let repo = try makeRepo()
        XCTAssertEqual(
            ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true),
            .nothingToDo
        )
    }

    func testASingleBranchConflictingWithMainIsAnnounced() throws {
        let repo = try makeRepo()
        try write("main\n", to: "f.txt", in: repo)
        commit("main moves", in: repo)
        git(["checkout", "-qb", "agent/alice", "HEAD~1"], in: repo)
        try write("alice\n", to: "f.txt", in: repo)
        commit("alice moves", in: repo)

        XCTAssertEqual(
            ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true),
            .done(announced: 1, pairs: 0)
        )
        XCTAssertTrue(busMessages().contains { $0.toBranch == "agent/alice" && $0.text.contains("main") })
    }

    func testAMergedBranchWarnsNobody() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        git(["checkout", "-q", "main"], in: repo)
        git(["merge", "--ff-only", "agent/alice"], in: repo)

        XCTAssertEqual(
            ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true),
            .done(announced: 0, pairs: 0)
        )
        XCTAssertTrue(busMessages().isEmpty)
    }

    func testDisjointBranchesSkipThePairPhase() throws {
        let repo = try makeRepo()
        for (branch, file) in [("agent/a", "a.txt"), ("agent/b", "b.txt")] {
            git(["checkout", "-qb", branch, "main"], in: repo)
            try write("x\n", to: file, in: repo)
            commit(branch, in: repo)
        }
        XCTAssertEqual(
            ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true),
            .done(announced: 0, pairs: 1)
        )
        let base = try XCTUnwrap(ConflictRadar.mergeBase("agent/a", "agent/b", in: repo.path))
        XCTAssertFalse(ConflictRadar.overlaps(
            ConflictRadar.changedFiles(from: base, to: "agent/a", in: repo.path) ?? [],
            ConflictRadar.changedFiles(from: base, to: "agent/b", in: repo.path) ?? []
        ))
    }

    /// Three branches, one pair per sweep: each sweep announces a new pair
    /// until every pair has been seen, and the ledger says the sweep was
    /// capped. Without rotation the first pair would starve the rest.
    func testCappedSweepsRotateThroughEveryPair() throws {
        let repo = try makeRepo()
        for (branch, content) in [("agent/alice", "alice\n"), ("agent/bob", "bob\n"), ("agent/carol", "carol\n")] {
            git(["checkout", "-qb", branch, "main"], in: repo)
            try write(content, to: "f.txt", in: repo)
            commit(branch, in: repo)
        }

        for expected in [2, 4, 6] {
            XCTAssertEqual(
                ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true, maxPairs: 1),
                .done(announced: 1, pairs: 1)
            )
            XCTAssertEqual(busMessages().count, expected)
        }
        XCTAssertEqual(
            ConflictRadar.sweep(project: repo.path, paths: paths, ignoreThrottle: true, maxPairs: 1),
            .done(announced: 0, pairs: 1)
        )
        XCTAssertEqual(busMessages().count, 6)

        let ledger = (try? String(contentsOf: paths.ledger, encoding: .utf8)) ?? ""
        XCTAssertTrue(ledger.contains("radar.capped"))
    }

    func testADirectoryThatIsNoRepositoryIsNothingToDo() {
        XCTAssertEqual(
            ConflictRadar.sweep(project: root.path, paths: paths, ignoreThrottle: true),
            .nothingToDo
        )
    }

    /// A branch that keeps failing to land writes one ledger line per half
    /// hour, not one per Stop.
    func testAutoSkipNotesAreThrottledPerBranch() {
        let project = root.path
        XCTAssertTrue(ConflictRadar.noteAutoSkip(branch: "agent/a", project: project, paths: paths))
        XCTAssertFalse(ConflictRadar.noteAutoSkip(branch: "agent/a", project: project, paths: paths))
        XCTAssertTrue(ConflictRadar.noteAutoSkip(branch: "agent/b", project: project, paths: paths))
        ConflictRadar.clearAutoNote(branch: "agent/a", project: project, paths: paths)
        XCTAssertTrue(ConflictRadar.noteAutoSkip(branch: "agent/a", project: project, paths: paths))
    }
}
