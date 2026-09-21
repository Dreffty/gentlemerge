import XCTest
@testable import GentleMergeCore

/// The "where" layer of not stepping on each other: globs that decide whether
/// two patterns overlap, claims that expire, zones that travel in HANDOFF.md,
/// and the pre-commit gate that turns all of it into a decision.
final class GlobTests: XCTestCase {
    func testDoubleStarGoesThroughDirectories() {
        XCTAssertTrue(Glob.matches("lib/**", "lib/a/b.dart"))
        XCTAssertTrue(Glob.matches("lib/**", "lib/a.dart"))
        XCTAssertTrue(Glob.matches("**/test_*.py", "tests/test_bus.py"))
        XCTAssertTrue(Glob.matches("**/test_*.py", "test_bus.py"), "**/ matches zero directories too")
    }

    func testSingleStarStaysInItsDirectory() {
        XCTAssertTrue(Glob.matches("lib/*", "lib/a.dart"))
        XCTAssertFalse(Glob.matches("lib/*", "lib/a/b.dart"))
        XCTAssertTrue(Glob.matches("lib/store", "lib/store/x.dart"), "no wildcards covers the subtree")
        XCTAssertFalse(Glob.matches("lib/store", "lib/other/x.dart"))
    }

    func testOverlapIsConservative() {
        XCTAssertTrue(Glob.mayOverlap("lib/**", "lib/store/**"))
        XCTAssertFalse(Glob.mayOverlap("lib/**", "assets/**"))
        XCTAssertTrue(Glob.mayOverlap("lib/store/**", "lib/store/a.dart"))
        XCTAssertTrue(Glob.mayOverlap("**", "anything/else"), "a rootless pattern assumes overlap")
    }

    func testNormalizeStripsDotSlashAndTrailingSlash() {
        XCTAssertTrue(Glob.matches("./lib/**", "lib/x"))
        XCTAssertTrue(Glob.matches("lib/", "lib/x"))
    }

    func testQuestionMatchesExactlyOneCharacter() {
        XCTAssertTrue(Glob.matches("lib/?.dart", "lib/a.dart"))
        XCTAssertFalse(Glob.matches("lib/?.dart", "lib/ab.dart"))
    }
}

final class OwnershipTests: XCTestCase {
    func testParseAcceptsAllThreeSeparators() {
        let ownership = Ownership.parse(section: """
        - lib/store/** → claude
        - assets/** -> codex
        - lib/data/**: hermes
        """)
        XCTAssertEqual(ownership.rules.count, 3)
        XCTAssertEqual(ownership.rules[0].owner, "claude")
        XCTAssertEqual(ownership.rules[1].owner, "codex")
        XCTAssertEqual(ownership.rules[2].owner, "hermes")
        XCTAssertEqual(ownership.rules[2].pattern, "lib/data/**", "backticks are stripped")
    }

    func testTheMostSpecificRuleWins() {
        let ownership = Ownership(rules: [
            .init(pattern: "lib/**", owner: "claude"),
            .init(pattern: "lib/store/**", owner: "codex"),
        ])
        XCTAssertEqual(ownership.owner(of: "lib/store/a.dart"), "codex")
        XCTAssertEqual(ownership.owner(of: "lib/other.dart"), "claude")
        XCTAssertNil(ownership.owner(of: "assets/x.png"))
    }

    func testRoundTripThroughTheHandoffFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-ownership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("proj").path
        let handoff = ProjectHandoff(
            projectPath: project,
            extraSections: [(heading: Ownership.heading, body: Ownership(rules: [
                .init(pattern: "assets/**", owner: "codex"),
            ]).render())]
        )
        XCTAssertTrue(HandoffMarkdown.render(handoff).contains("assets/**"))

        let parsed = HandoffMarkdown.parse(
            HandoffMarkdown.render(handoff),
            projectPath: project
        )
        let restored = Ownership.from(handoff: parsed)
        XCTAssertEqual(restored.rules.map { $0.pattern }, ["assets/**"])
        XCTAssertEqual(restored.owner(of: "assets/images/x.png"), "codex")
    }

    func testPinnedAuthorityWinsOverTheHandoffFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-ownership-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        let project = root.appendingPathComponent("proj").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        // HANDOFF.md says codex; the judged agent rewrites it to say itself.
        func writeHandoff(owner: String) throws {
            let dir = URL(fileURLWithPath: project).appendingPathComponent(".gentlemerge", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("# p — agent handoff\n\n## Ownership\n\n- assets/** → \(owner)\n".utf8)
                .write(to: dir.appendingPathComponent("HANDOFF.md"))
        }
        try writeHandoff(owner: "codex")
        let pinned = try Ownership.pin(project: project, paths: paths, by: "you")
        XCTAssertEqual(pinned.map(\.owner), ["codex"])

        // The attacker grants itself the zone in the working tree…
        try writeHandoff(owner: "mallory")
        // …and the gate still enforces the pinned rules.
        let (effective, authority) = Ownership.effective(project: project, paths: paths)
        XCTAssertEqual(authority, .pinned)
        XCTAssertEqual(effective.owner(of: "assets/x.png"), "codex")
        let violations = PrecommitGate.evaluate(
            staged: ["assets/x.png"], me: "mallory",
            claims: [], ownership: effective
        )
        XCTAssertEqual(violations.count, 1)

        // Every write leaves a signed trail.
        let ledger = try String(contentsOf: paths.ledger, encoding: .utf8)
        XCTAssertTrue(ledger.contains("ownership.changed"), ledger)
    }

    func testWithoutAPinTheHandoffStillRules() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-ownership-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.appendingPathComponent("home"))
        try paths.createDirectories()
        let (effective, authority) = Ownership.effective(project: "/nope", paths: paths)
        XCTAssertEqual(authority, .handoff)
        XCTAssertTrue(effective.rules.isEmpty)
    }
}

final class PathClaimsTests: XCTestCase {
    private var root: URL!
    private var claims: PathClaims!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-pathclaims-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        claims = PathClaims(paths: Paths(home: root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnOverlappingClaimBySomebodyElseThrows() throws {
        _ = try claims.claim(pattern: "lib/**", label: "claude", project: "/p", intent: "refactor")
        XCTAssertThrowsError(
            try claims.claim(pattern: "lib/store/**", label: "codex", project: "/p", intent: "typo")
        ) { error in
            guard let conflict = error as? PathClaimConflict else { return XCTFail("expected a conflict") }
            XCTAssertTrue(conflict.description.contains("claude"), "the holder is named")
            XCTAssertTrue(conflict.description.contains("refactor"), "so is the intent")
        }
    }

    func testTheSameLabelRenewsInsteadOfThrowing() throws {
        let first = try claims.claim(pattern: "lib/**", label: "claude", project: "/p", intent: "refactor")
        // Renew with a shorter TTL and confirm the expiry moved back.
        let renewed = try claims.claim(
            pattern: "lib/**", label: "claude", project: "/p", intent: nil,
            ttl: first.expires.timeIntervalSinceNow - 600
        )
        XCTAssertLessThan(renewed.expires, first.expires)
        XCTAssertEqual(claims.load().count, 1, "renewed in place, not duplicated")
    }

    func testAnImplicitTouchNeverFightsNorOverwrites() throws {
        _ = try claims.claim(pattern: "lib/**", label: "claude", project: "/p", intent: "refactor")
        // The recorded claim is the other agent's, not ours: implicit claims
        // never throw and never take a path away from whoever holds it.
        let recorded = claims.touch(file: "lib/store/x.swift", label: "codex", project: "/p")
        XCTAssertTrue(recorded.map { $0.label == "claude" } ?? true)
        XCTAssertTrue(claims.load().contains { $0.label == "claude" })
        XCTAssertFalse(claims.load().contains { $0.label == "codex" })
    }

    func testAnExpiredClaimIsPrunedOnTheNextWrite() throws {
        _ = try claims.claim(pattern: "lib/**", label: "claude", project: "/p",
                             intent: nil, ttl: -1) // already expired
        XCTAssertTrue(claims.load().contains { $0.label == "claude" }, "load does not prune")
        claims.prune()
        XCTAssertTrue(claims.load().isEmpty, "prune drops the expired claim")
    }

    func testTwoConcurrentWritersDoNotLoseWrites() {
        // One expectation per writer is the API contract; assertingInconsistency
        // on a second fulfill is the one thing a concurrent test cannot recover
        // from. `assertForOverFulfill: false` keeps 16 writers from crashing.
        let root = self.root! // Capture the Sendable URL, not the XCTestCase.
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let writer = PathClaims(paths: Paths(home: root))
            _ = try? writer.claim(pattern: "lib/\(index % 4)/**", label: "agent-\(index)", project: "/p",
                                  intent: nil)
        }
        let live = claims.live(project: "/p")
        XCTAssertEqual(live.count, 4, "16 writers, 4 distinct patterns — none lost to a race, got \(live.count)")
    }

    func testReleaseAndRenewAreScopedToTheLabel() throws {
        _ = try claims.claim(pattern: "lib/**", label: "claude", project: "/p", intent: nil)
        _ = try claims.claim(pattern: "assets/**", label: "codex", project: "/p", intent: nil)
        try claims.release(label: "claude", project: "/p")
        XCTAssertEqual(claims.live(project: "/p").map { $0.label }, ["codex"])
        try claims.renew(label: "codex", project: "/p")
        XCTAssertTrue(claims.live(project: "/p").contains { $0.label == "codex" })
    }

    func testLiveIsScopedToTheProject() throws {
        _ = try claims.claim(pattern: "lib/**", label: "claude", project: "/a", intent: nil)
        _ = try claims.claim(pattern: "lib/**", label: "codex", project: "/b", intent: nil)
        XCTAssertEqual(claims.live(project: "/a").map { $0.label }, ["claude"])
    }
}

final class PrecommitGateTests: XCTestCase {
    private func claim(_ label: String, _ pattern: String, implicit: Bool = false,
                       ttl: TimeInterval = 600) -> PathClaim {
        PathClaim(label: label, projectPath: "/p", pattern: pattern, intent: nil,
                  since: Date(), expires: Date().addingTimeInterval(ttl), implicit: implicit)
    }
    private let ownership = Ownership(rules: [.init(pattern: "assets/**", owner: "codex")])

    func testSomebodyElsesClaimBlocks() {
        let violations = PrecommitGate.evaluate(
            staged: ["lib/store/a.swift"], me: "codex",
            claims: [claim("claude", "lib/**")], ownership: ownership
        )
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations[0].reason.contains("claimed by claude"), "the holder is named")
        XCTAssertTrue(violations[0].blocking)
    }

    func testAnotherAgentsZoneWithoutAClaimBlocks() {
        let violations = PrecommitGate.evaluate(
            staged: ["assets/x.png"], me: "claude",
            claims: [], ownership: ownership
        )
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations[0].reason.contains("owned by codex"))
    }

    func testAnotherAgentsZoneWithAnExplicitClaimOfMyOwnDoesNotBlock() {
        let violations = PrecommitGate.evaluate(
            staged: ["assets/x.png"], me: "claude",
            claims: [claim("claude", "assets/**")], ownership: ownership
        )
        XCTAssertTrue(violations.isEmpty)
    }

    func testAnImplicitClaimOfMyOwnDoesNotBuyTheOverride() {
        let violations = PrecommitGate.evaluate(
            staged: ["assets/x.png"], me: "claude",
            claims: [claim("claude", "assets/**", implicit: true)], ownership: ownership
        )
        XCTAssertEqual(violations.count, 1, "history is not a decision")
    }

    func testNoIdentityNeverBlocks() {
        XCTAssertTrue(PrecommitGate.evaluate(
            staged: ["assets/x.png"], me: nil,
            claims: [claim("claude", "assets/**")], ownership: ownership
        ).isEmpty, "enforcing claims against an unknown actor is a block we cannot justify")
    }

    func testMyOwnClaimDoesNotBlockMe() {
        XCTAssertTrue(PrecommitGate.evaluate(
            staged: ["lib/store/a.swift"], me: "claude",
            claims: [claim("claude", "lib/**")], ownership: ownership
        ).isEmpty)
    }

    func testAnExpiredClaimDoesNotBlock() {
        XCTAssertTrue(PrecommitGate.evaluate(
            staged: ["lib/store/a.swift"], me: "codex",
            claims: [claim("claude", "lib/**", ttl: -1)], ownership: ownership
        ).isEmpty)
    }

    func testADeadOwnersClaimDoesNotBlock() {
        let presence = [Presence.PresenceMark(
            label: "claude", projectPath: "/p", branch: nil, updatedAt: Date(),
            pid: 1, task: nil, capabilities: [])]
        XCTAssertTrue(PrecommitGate.evaluate(
            staged: ["lib/store/a.swift"], me: "codex",
            claims: [claim("claude", "lib/**")], ownership: ownership,
            presence: presence, isPIDAlive: { _ in false }
        ).isEmpty, "a session that died without releasing must not block the living")
    }

    func testALiveOwnersClaimStillBlocks() {
        let presence = [Presence.PresenceMark(
            label: "claude", projectPath: "/p", branch: nil, updatedAt: Date(),
            pid: 1, task: nil, capabilities: [])]
        XCTAssertEqual(PrecommitGate.evaluate(
            staged: ["lib/store/a.swift"], me: "codex",
            claims: [claim("claude", "lib/**")], ownership: ownership,
            presence: presence, isPIDAlive: { _ in true }
        ).count, 1)
    }

    func testMyOwnDeadClaimStillBuysMyOverride() {
        let presence = [Presence.PresenceMark(
            label: "claude", projectPath: "/p", branch: nil, updatedAt: Date(),
            pid: 1, task: nil, capabilities: [])]
        XCTAssertTrue(PrecommitGate.evaluate(
            staged: ["assets/x.png"], me: "claude",
            claims: [claim("claude", "assets/**")], ownership: ownership,
            presence: presence, isPIDAlive: { _ in false }
        ).isEmpty, "you cannot be dead while committing")
    }

    func testWithoutLivenessNothingIsReaped() {
        XCTAssertEqual(PrecommitGate.evaluate(
            staged: ["lib/store/a.swift"], me: "codex",
            claims: [claim("claude", "lib/**")], ownership: ownership
        ).count, 1, "the gate without liveness behaves exactly as before")
    }
}

final class ReapingTests: XCTestCase {
    private let now = Date()
    private func claim(_ label: String, ttl: TimeInterval = 600) -> PathClaim {
        PathClaim(label: label, projectPath: "/p", pattern: "lib/**", intent: nil,
                  since: now, expires: now.addingTimeInterval(ttl), implicit: false)
    }
    private func mark(_ label: String, pid: Int? = nil, updatedMinutesAgo: Double = 0) -> Presence.PresenceMark {
        Presence.PresenceMark(label: label, projectPath: "/p", branch: nil,
            updatedAt: now.addingTimeInterval(-updatedMinutesAgo * 60),
            pid: pid, task: nil, capabilities: [])
    }

    func testADeadPIDReaps() {
        let (live, reaped) = PathClaims.reap(
            [claim("hermes")], presence: [mark("hermes", pid: 999_999)],
            isPIDAlive: { _ in false }, now: now)
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(reaped.count, 1)
    }

    func testALivePIDKeeps() {
        let (live, reaped) = PathClaims.reap(
            [claim("hermes")], presence: [mark("hermes", pid: 1)],
            isPIDAlive: { _ in true }, now: now)
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(reaped.isEmpty)
    }

    func testNoMarksMeansUnknownNeverDead() {
        let (live, reaped) = PathClaims.reap(
            [claim("hermes")], presence: [],
            isPIDAlive: { _ in nil }, now: now)
        XCTAssertEqual(live.count, 1, "a plain shell leaves no presence; reaping it would punish the least instrumented agent")
        XCTAssertTrue(reaped.isEmpty)
    }

    func testStalePresenceReapsWithoutAPID() {
        let (live, reaped) = PathClaims.reap(
            [claim("hermes")], presence: [mark("hermes", updatedMinutesAgo: 60)],
            isPIDAlive: { _ in nil }, now: now)
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(reaped.count, 1)
    }

    func testFreshPresenceWithoutPIDKeeps() {
        let (live, reaped) = PathClaims.reap(
            [claim("hermes")], presence: [mark("hermes")],
            isPIDAlive: { _ in nil }, now: now)
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(reaped.isEmpty)
    }

    func testExpiredClaimsAreNotReaped() {
        let (live, reaped) = PathClaims.reap(
            [claim("hermes", ttl: -1)], presence: [mark("hermes", pid: 9)],
            isPIDAlive: { _ in false }, now: now)
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(reaped.isEmpty, "already dead by time is not reaped")
    }

    func testASubagentMarkSpeaksForTheParentClaim() {
        let (live, reaped) = PathClaims.reap(
            [claim("claude")], presence: [mark("claude#exec1", pid: 9)],
            isPIDAlive: { _ in false }, now: now)
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(reaped.count, 1)
    }
}

final class GitHookInstallerTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-githooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = root.appendingPathComponent("repo")
        _ = try Shell.run("/usr/bin/env", ["git", "init", repo.path], timeout: 15)
        try "readme".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try Shell.run("/usr/bin/env", ["git", "-C", repo.path, "add", "."], timeout: 15)
        _ = try Shell.run(
            "/usr/bin/env",
            ["git", "-C", repo.path, "-c", "user.email=t@x", "-c", "user.name=t", "commit", "-m", "init"],
            timeout: 15
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheHookLandsInTheCommonDir() throws {
        let installer = GitHookInstaller(paths: Paths(home: root))
        let message = try installer.install(repo: repo)
        XCTAssertTrue(message.contains("installed"), message)

        // A linked worktree shares the common dir, so the hook is there for it
        // without a second install.
        _ = try Shell.run(
            "/usr/bin/env",
            ["git", "-C", repo.path, "worktree", "add", root.appendingPathComponent("wt").path, "-b", "wt"],
            timeout: 15
        )
        let dir = try installer.hooksDir(for: repo)
        let hook = dir.appendingPathComponent("pre-commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hook.path))
        XCTAssertTrue(try String(contentsOf: hook, encoding: .utf8).contains(GitHookInstaller.marker))
        let post = dir.appendingPathComponent("post-commit")
        XCTAssertTrue(
            try String(contentsOf: post, encoding: .utf8).contains(GitHookInstaller.postCommitMarker),
            "post-commit releases what just landed"
        )
    }

    func testAForeignHookIsChainedNotDestroyed() throws {
        let dir = try GitHookInstaller(paths: Paths(home: root)).hooksDir(for: repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let foreign = dir.appendingPathComponent("pre-commit")
        try "#!/bin/sh\necho husky\n".write(to: foreign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreign.path)

        let installer = GitHookInstaller(paths: Paths(home: root))
        _ = try installer.install(repo: repo)

        let hook = try String(contentsOf: foreign.appendingPathExtension("gentlemerge-prev"), encoding: .utf8)
        XCTAssertTrue(hook.contains("husky"), "the foreign hook keeps its copy")
        let ours = try String(contentsOf: foreign, encoding: .utf8)
        XCTAssertTrue(ours.contains("gentlemerge-prev"), "and ours chains to it")
    }

    func testUninstallRestoresThePreviousHook() throws {
        let dir = try GitHookInstaller(paths: Paths(home: root)).hooksDir(for: repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "#!/bin/sh\necho husky\n".write(
            to: dir.appendingPathComponent("pre-commit"), atomically: true, encoding: .utf8
        )

        let installer = GitHookInstaller(paths: Paths(home: root))
        _ = try installer.install(repo: repo)
        let result = try installer.uninstall(repo: repo)
        XCTAssertEqual(result, "removed")
        let restored = try String(contentsOf: dir.appendingPathComponent("pre-commit"), encoding: .utf8)
        XCTAssertTrue(restored.contains("husky"))
    }

    func testInstallIsIdempotent() throws {
        let installer = GitHookInstaller(paths: Paths(home: root))
        _ = try installer.install(repo: repo)
        XCTAssertEqual(try installer.install(repo: repo).contains("already installed"), true)
    }

    func testMergeCommitsGetTheSameGate() throws {
        let installer = GitHookInstaller(paths: Paths(home: root))
        _ = try installer.install(repo: repo)
        let dir = try installer.hooksDir(for: repo)
        for name in GitHookInstaller.hookNames {
            let hook = dir.appendingPathComponent(name)
            let body = try String(contentsOf: hook, encoding: .utf8)
            XCTAssertTrue(body.contains(GitHookInstaller.marker), "\(name) carries our gate")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hook.path), "\(name) runs")
        }
    }

    func testUninstallRemovesBothHooks() throws {
        let installer = GitHookInstaller(paths: Paths(home: root))
        _ = try installer.install(repo: repo)
        XCTAssertEqual(try installer.uninstall(repo: repo), "removed")
        let dir = try installer.hooksDir(for: repo)
        for name in GitHookInstaller.hookNames + ["post-commit"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
        XCTAssertEqual(try installer.uninstall(repo: repo), "not ours; left alone")
    }

    func testCustomHooksPathInsideTheRepoGetsOurHooksChained() throws {
        _ = try Shell.run("/usr/bin/env", ["git", "-C", repo.path, "config", "core.hooksPath", ".githooks"], timeout: 15)
        let custom = repo.appendingPathComponent(".githooks")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let foreign = custom.appendingPathComponent("pre-commit")
        try "#!/bin/sh\necho lefthook\n".write(to: foreign, atomically: true, encoding: .utf8)

        let installer = GitHookInstaller(paths: Paths(home: root))
        let message = try installer.install(repo: repo)
        XCTAssertTrue(message.contains("core.hooksPath"), message)

        let ours = try String(contentsOf: foreign, encoding: .utf8)
        XCTAssertTrue(ours.contains(GitHookInstaller.marker))
        let kept = try String(contentsOf: foreign.appendingPathExtension("gentlemerge-prev"), encoding: .utf8)
        XCTAssertTrue(kept.contains("lefthook"), "the foreign hook keeps its copy")

        // The common dir stays untouched: git would never run a hook from it.
        let classic = try installer.hooksDir(for: repo)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: classic.appendingPathComponent("pre-commit").path))
    }

    func testHooksPathOutsideTheRepoRefusesLoudly() throws {
        _ = try Shell.run(
            "/usr/bin/env",
            ["git", "-C", repo.path, "config", "core.hooksPath", root.appendingPathComponent("global-hooks").path],
            timeout: 15
        )
        let installer = GitHookInstaller(paths: Paths(home: root))
        XCTAssertThrowsError(try installer.install(repo: repo)) { error in
            XCTAssertTrue(error.localizedDescription.contains("core.hooksPath"), error.localizedDescription)
        }
    }
}
