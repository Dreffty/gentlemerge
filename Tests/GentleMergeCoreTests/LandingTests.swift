import XCTest
@testable import GentleMergeCore

/// Landing a branch: clean tree, no conflicts, green checks, then and only
/// then main moves — and the bus hears about it.
final class LandingTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var counter = 0

    private var paths: Paths { Paths(home: home) }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-landing-\(UUID().uuidString)")
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

    private func tip(of branch: String, in repo: URL) -> String {
        git(["rev-parse", branch], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func land(
        _ repo: URL,
        branch: String? = nil,
        into: String? = nil,
        label: String = "alice",
        skipChecks: Bool = false,
        dryRun: Bool = false,
        fast: Bool = false
    ) throws -> Landing.Report {
        try Landing.land(
            branch: branch, into: into, repo: repo, label: label,
            verified: true, paths: paths,
            skipChecks: skipChecks, dryRun: dryRun, fast: fast, progress: { _ in }
        )
    }

    private func failure(of action: () throws -> Landing.Report) -> Landing.Failure? {
        do {
            _ = try action()
            return nil
        } catch let failure as Landing.Failure {
            return failure
        } catch {
            XCTFail("unexpected error: \(error)")
            return nil
        }
    }

    // MARK: - Refusals

    func testADirtyWorktreeAbortsListingItsFiles() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("dirty\n", to: "f.txt", in: repo)

        guard case .dirty(let files)? = failure(of: { try land(repo) }) else {
            return XCTFail("a dirty tree should refuse to land")
        }
        XCTAssertEqual(files, ["f.txt"])
    }

    func testAConflictNamesTheFileAndWhoTouchedIt() throws {
        let repo = try makeRepo()
        git(["config", "user.name", "Main Author"], in: repo)
        try write("main\n", to: "f.txt", in: repo)
        commit("main", in: repo)
        git(["checkout", "-qb", "agent/alice", "HEAD~1"], in: repo)
        git(["config", "user.name", "Branch Author"], in: repo)
        try write("branch\n", to: "f.txt", in: repo)
        commit("branch", in: repo)

        guard case .conflicts(let branch, let into, let details)? = failure(of: { try land(repo) }) else {
            return XCTFail("a conflicting branch should refuse to land")
        }
        XCTAssertEqual(branch, "agent/alice")
        XCTAssertEqual(into, "main")
        XCTAssertEqual(details.map(\.path), ["f.txt"])
        XCTAssertTrue(details[0].authors.contains("Main Author"))
        XCTAssertTrue(details[0].authors.contains("Branch Author"))
    }

    func testLandingFromAnotherWorktreeIsRefused() throws {
        let repo = try makeRepo()
        git(["branch", "agent/alice"], in: repo)

        guard case .wrongCheckout(let expected, _)? = failure(of: { try land(repo, branch: "agent/alice") }) else {
            return XCTFail("landing a branch from main's worktree should fail")
        }
        XCTAssertEqual(expected, "agent/alice")
    }

    // MARK: - Checks gate main

    private func failingChecksRepo() throws -> URL {
        let repo = try makeRepo()
        try Data(
            #"{"checks":[{"name":"always fails","command":"false","kind":"test","timeout":30,"optional":false}],"replaceDetected":true}"#.utf8
        ).write(to: repo.appendingPathComponent(".gentlemerge.json"))
        // Committed, so the tree is clean and the check file is part of what lands.
        commit("checks", in: repo)
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        return repo
    }

    /// Failing checks stop the landing with main exactly where it was.
    func testFailingChecksLeaveMainAlone() throws {
        let repo = try failingChecksRepo()
        let mainBefore = tip(of: "main", in: repo)

        guard case .checksFailed(let results)? = failure(of: { try land(repo) }) else {
            return XCTFail("failing checks should stop the landing")
        }
        XCTAssertEqual(results.map(\.name), ["always fails"])
        XCTAssertEqual(tip(of: "main", in: repo), mainBefore)
        XCTAssertTrue(AgentBus(paths: paths).messages().isEmpty)
    }

    // MARK: - The happy path

    /// A clean landing moves main, tells the bus, and releases the claims on
    /// what just merged.
    func testLandingMovesMainAndReleasesClaims() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        let branchTip = tip(of: "agent/alice", in: repo)

        let project = ProjectRegistry.canonicalPath(for: repo.path)
        try PathClaims(paths: paths).claim(
            pattern: "a.txt", label: "alice", project: project, intent: "landing"
        )
        // Somebody else's claim on the same file stands: their edit is still
        // uncommitted somewhere, and landing must not hand it back for them.
        try PathClaims(paths: paths).claim(
            pattern: "other.txt", label: "bob", project: project, intent: "elsewhere"
        )

        let report = try land(repo)
        XCTAssertEqual(report.branch, "agent/alice")
        XCTAssertEqual(report.into, "main")
        XCTAssertEqual(report.sha, branchTip)
        XCTAssertEqual(tip(of: "main", in: repo), branchTip)
        XCTAssertFalse(report.dryRun)

        let posted = AgentBus(paths: paths).messages()
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(posted[0].text.hasPrefix("landed "))
        XCTAssertTrue(posted[0].text.contains("from alice"))
        XCTAssertTrue(posted[0].text.contains("a.txt"))

        let live = PathClaims(paths: paths).live(project: project)
        XCTAssertFalse(live.contains { $0.label == "alice" })
        XCTAssertTrue(live.contains { $0.label == "bob" })

        let ledger = (try? String(contentsOf: paths.ledger, encoding: .utf8)) ?? ""
        XCTAssertTrue(ledger.contains("land.ok"))
    }

    /// When main is checked out in the main worktree, the landing merges there
    /// instead of moving the ref from the side.
    func testLandingIntoACheckedOutMainMerges() throws {
        let repo = try makeRepo()
        let wt = root.appendingPathComponent("wt")
        git(["worktree", "add", "-b", "agent/alice", wt.path], in: repo)
        defer { git(["worktree", "remove", "--force", wt.path], in: repo) }
        try write("alice\n", to: "a.txt", in: wt)
        commit("alice", in: wt)

        let report = try land(wt)
        XCTAssertEqual(tip(of: "main", in: repo), report.sha)
        XCTAssertTrue(AgentBus(paths: paths).messages().first?.text.hasPrefix("landed ") == true)
    }

    func testDryRunPlansWithoutTouchingAnything() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        let mainBefore = tip(of: "main", in: repo)

        let report = try land(repo, dryRun: true)
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.files, ["a.txt"])
        XCTAssertFalse(report.message.isEmpty)
        XCTAssertEqual(tip(of: "main", in: repo), mainBefore)
        XCTAssertTrue(AgentBus(paths: paths).messages().isEmpty)
    }

    // MARK: - Claims released by coverage

    func testReleaseCoveringReleasesOnlyWhatCovers() throws {
        let project = "test-project"
        let claims = PathClaims(paths: paths)
        try claims.claim(pattern: "docs/**", label: "alice", project: project, intent: nil)
        try claims.claim(pattern: "other.txt", label: "alice", project: project, intent: nil)
        // A different label on a disjoint pattern: landing alice's files must
        // not hand bob's claim back for him.
        try claims.claim(pattern: "img/**", label: "bob", project: project, intent: nil)

        let released = try claims.releaseCovering(files: ["docs/a.md"], project: project, label: "alice")
        XCTAssertEqual(released.count, 1)

        let live = claims.live(project: project)
        XCTAssertEqual(live.count, 2)
        XCTAssertTrue(live.contains { $0.label == "alice" && $0.pattern == "other.txt" })
        XCTAssertTrue(live.contains { $0.label == "bob" })
    }

    // MARK: - Automatic landing

    func testAutoLandIsOffByDefault() throws {
        XCTAssertFalse(AppConfig().autoLand)
        let decoded = try JSONCoding.decoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.autoLand)
    }

    func testAutoLandLandsAnAheadBranch() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        let branchTip = tip(of: "agent/alice", in: repo)

        guard case .landed(let report) = Landing.autoLand(cwd: repo.path, provider: .unknown, paths: paths) else {
            return XCTFail("a clean branch ahead of main should auto-land")
        }
        XCTAssertEqual(report.sha, branchTip)
        XCTAssertEqual(tip(of: "main", in: repo), branchTip)
    }

    func testAutoLandSkipsADirtyTreeQuietly() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        try write("uncommitted\n", to: "f.txt", in: repo)

        guard case .skipped = Landing.autoLand(cwd: repo.path, provider: .unknown, paths: paths) else {
            return XCTFail("a dirty tree should skip auto-land")
        }
        XCTAssertNotEqual(tip(of: "main", in: repo), tip(of: "agent/alice", in: repo))
    }

    // MARK: - Fast landing

    func testFastLandsWhatFastForwardsWithoutChecks() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)

        let report = try land(repo, fast: true)
        XCTAssertEqual(report.checksRun, 0)
        XCTAssertEqual(tip(of: "main", in: repo), tip(of: "agent/alice", in: repo))
    }

    func testFastRefusesABranchThatNeedsARebase() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)
        git(["checkout", "-q", "main"], in: repo)
        try write("main\n", to: "m.txt", in: repo)
        commit("main moves", in: repo)
        git(["checkout", "-q", "agent/alice"], in: repo)

        guard case .cannotFastForward? = failure(of: { try land(repo, fast: true) }) else {
            return XCTFail("fast must refuse what does not fast-forward")
        }
        XCTAssertNotEqual(tip(of: "main", in: repo), tip(of: "agent/alice", in: repo))
    }

    // MARK: - Serial landings

    func testTryExclusiveLockSkipsWhileHeld() throws {
        let url = root.appendingPathComponent("landprobe")
        try LockedFile.withExclusiveLock(url) {
            XCTAssertFalse(try LockedFile.tryExclusiveLock(url) { XCTFail("must not run while held") })
        }
        XCTAssertTrue(try LockedFile.tryExclusiveLock(url) {})
    }

    func testAutoLandSkipsWhileAnotherLandingHoldsTheLock() throws {
        let repo = try makeRepo()
        git(["checkout", "-qb", "agent/alice"], in: repo)
        try write("alice\n", to: "a.txt", in: repo)
        commit("alice", in: repo)

        try LockedFile.withExclusiveLock(home.appendingPathComponent("land")) {
            guard case .skipped(let reason) = Landing.autoLand(cwd: repo.path, provider: .unknown, paths: paths) else {
                return XCTFail("a second landing must skip, not stack")
            }
            XCTAssertTrue(reason.contains("another landing"), reason)
        }
        XCTAssertNotEqual(tip(of: "main", in: repo), tip(of: "agent/alice", in: repo))
    }
}
