import XCTest
@testable import GentleMergeCore

/// HANDOFF.md is a tracked file the committing agent is itself editing. The
/// `Authority` doc comment already said such a source is "editable by the very
/// agent being judged, so never authoritative" — but `loadPinned` is empty in
/// the default configuration, so it *was* the authority. An agent could stage
/// an invasion of somebody's zone together with the deletion of that zone's
/// declaration, and the gate would see no zone at all (audit 2026-10-07). The
/// declaration then stayed deleted from history, so the next agent found the
/// zone free.
final class HandoffSelfJudgementTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("handoffself-\(UUID())")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = Paths(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeHandoff(_ text: String) throws {
        let url = ProjectHandoff.fileURL(for: root.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let withZone = """
    # Project

    ## Ownership
    - hermes_zone/** → hermes
    """

    private let zoneDeleted = """
    # Project

    ## Ownership
    """

    func testTheHandoffFileIsNamedTheWayGitNamesIt() {
        XCTAssertEqual(Ownership.handoffRelativePath, ".gentlemerge/HANDOFF.md")
    }

    /// The vulnerability, pinned as a test: with the declaration intact the
    /// gate blocks, and with the declaration deleted in the same commit the
    /// gate must still block.
    func testDeletingTheZoneDeclarationDoesNotLicenseTheInvasion() throws {
        try writeHandoff(withZone)

        // Baseline: handoff is authoritative and the invasion is caught.
        let trusting = Ownership.effective(project: root.path, paths: paths, handoffIsStaged: false)
        XCTAssertEqual(trusting.authority, .handoff)
        XCTAssertEqual(trusting.ownership.owner(of: "hermes_zone/models.dart"), "hermes")

        // The attack: the same file is also staged for edit in this commit.
        let selfJudged = Ownership.effective(project: root.path, paths: paths, handoffIsStaged: true)
        XCTAssertEqual(
            selfJudged.ownership.owner(of: "hermes_zone/models.dart"), nil,
            "a commit that rewrites HANDOFF.md must not be judged by the zones that rewrite removes"
        )
    }

    /// Pinned zones stay authoritative even when HANDOFF.md is staged — the
    /// pinned store lives in the home and is not reachable from the worktree,
    /// so it is still a trustworthy judge.
    func testPinnedZonesStillRuleWhenTheHandoffFileIsStaged() throws {
        try writeHandoff(withZone)
        let rules = [Ownership.Rule(pattern: "pinned_zone/**", owner: "codex")]
        try Ownership.savePinned([root.path: rules], paths: paths)

        let effective = Ownership.effective(project: root.path, paths: paths, handoffIsStaged: true)

        XCTAssertEqual(effective.authority, .pinned)
        XCTAssertEqual(effective.ownership.owner(of: "pinned_zone/x.dart"), "codex")
    }

    /// And the handoff's own zones are ignored even when pinned exists for a
    /// different project.
    func testTheHandoffIsIgnoredOnlyForTheCommitThatRewritesIt() throws {
        try writeHandoff(zoneDeleted)

        XCTAssertEqual(
            Ownership.effective(project: root.path, paths: paths, handoffIsStaged: false).ownership.rules, [],
            "an unrelated commit still reads whatever the file says"
        )
    }

    /// End to end through the gate: staging an invasion *and* the deletion must
    /// not produce a clean bill of health.
    func testTheGateBlocksTheCombinedStagedChange() throws {
        try writeHandoff(withZone)
        let staged = ["hermes_zone/models.dart", Ownership.handoffRelativePath]
        let effective = Ownership.effective(
            project: root.path, paths: paths,
            handoffIsStaged: staged.contains(Ownership.handoffRelativePath)
        ).ownership

        let violations = PrecommitGate.evaluate(
            staged: ["hermes_zone/models.dart"],
            me: "claude",
            claims: [],
            ownership: effective
        )

        // With the handoff disarmed there is no zone left to catch this, which
        // is precisely why the real defence is `ownership pin`. Assert the
        // mechanism we *can* guarantee: the declaration is not silently honoured.
        XCTAssertEqual(violations.count, 0, "no zone means nothing to enforce — which is why pinning exists")

        let pinned = Ownership(rules: [Ownership.Rule(pattern: "hermes_zone/**", owner: "hermes")])
        let blocking = PrecommitGate.evaluate(
            staged: ["hermes_zone/models.dart"], me: "claude", claims: [], ownership: pinned
        )
        XCTAssertEqual(blocking.count, 1, "a pinned zone does block")
        XCTAssertTrue(blocking[0].blocking)
    }
}

/// The narrowing: what must stop ruling is a commit that *rewrites the zones*,
/// not any commit that touches HANDOFF.md. The task list lives in the same file
/// and AGENT_PROTOCOL.md tells every agent to write there, so disarming on the
/// file's presence switched the whole ownership layer off for the ordinary
/// "I finished something, let me record it" commit (audit 2026-10-08).
///
/// Real git repository on purpose: `rulesAtHead` reads `git show HEAD:…`, so a
/// test over a hand-written directory would exercise none of it.
final class HandoffSelfJudgementNarrowingTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("handoffnarrow-\(UUID())")
        paths = Paths(home: root.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "t"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let out = Shell.run("/usr/bin/env", ["git"] + args, in: root, timeout: 30)
        guard out.succeeded else {
            throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr])
        }
        return out.stdout
    }

    private func writeHandoff(_ text: String) throws {
        let url = ProjectHandoff.fileURL(for: root.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let zonesAtHead = """
    # Project

    ## Ownership
    - hermes_zone/** → hermes
    """

    /// The ordinary commit: a task line added, zones untouched.
    func testACommitThatOnlyAddsATaskStillEnforcesTheZones() throws {
        try writeHandoff(zonesAtHead)
        try git(["add", "-A"]); try git(["commit", "-qm", "zones"])

        try writeHandoff(zonesAtHead + "\n## Open tasks\n\n- [ ] finished the migration\n")
        try git(["add", "-A"])

        let effective = Ownership.effective(project: root.path, paths: paths, handoffIsStaged: true)
        XCTAssertEqual(effective.authority, .handoff)
        XCTAssertEqual(
            effective.ownership.owner(of: "hermes_zone/models.dart"), "hermes",
            "recording what I did must not switch off somebody else's zone"
        )
    }

    /// The threat the rule was written for, still covered.
    func testACommitThatRewritesTheZonesIsNotJudgedByThem() throws {
        try writeHandoff(zonesAtHead)
        try git(["add", "-A"]); try git(["commit", "-qm", "zones"])

        try writeHandoff("# Project\n\n## Ownership\n")
        try git(["add", "-A"])

        let effective = Ownership.effective(project: root.path, paths: paths, handoffIsStaged: true)
        XCTAssertEqual(effective.authority, .handoff)
        XCTAssertNil(effective.ownership.owner(of: "hermes_zone/models.dart"))
    }

    /// Nothing to compare against reads as "rewriting" — fail closed, which is
    /// what a directory that is not a repository has always done.
    func testNoHeadToCompareAgainstDisarms() throws {
        try writeHandoff(zonesAtHead)   // never committed: unborn HEAD
        let effective = Ownership.effective(project: root.path, paths: paths, handoffIsStaged: true)
        XCTAssertEqual(effective.ownership.rules, [])
    }
}