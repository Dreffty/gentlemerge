import XCTest
@testable import GentleMergeCore

final class IdentityTests: XCTestCase {
    func testLabelsAreSanitizedAndWeakOverridesRemainUnverified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        let identity = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths,
            environment: ["GENTLEMERGE_LABEL": "codex;\n evil"])
        XCTAssertEqual(identity.label, "codexevil")
        XCTAssertEqual(try Identity.reconcile(explicit: "codex; evil", resolved: identity), identity)
        let human = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths, environment: [:])
        let override = try Identity.reconcile(explicit: String(repeating: "a", count: 30), resolved: human)
        XCTAssertEqual(override.label.count, 24)
        XCTAssertFalse(override.verified)
    }

    func testWeakPresenceFallsBackWhenAmbiguous() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()
        let project = ProjectRegistry.canonicalPath(for: root.path)
        Presence.record(label: "a", project: project, branch: nil, task: nil, paths: paths)
        let one = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths, environment: [:])
        XCTAssertEqual(one.label, "a")
        XCTAssertEqual(one.source, .presence)
        XCTAssertFalse(one.verified)
        Presence.record(label: "b", project: project, branch: nil, task: nil, paths: paths)
        XCTAssertEqual(Identity.resolve(cwd: root.path, provider: .unknown, paths: paths, environment: [:]).source, .human)
        let provider = Identity.resolve(cwd: root.path, provider: .claudeCode, paths: paths, environment: [:])
        XCTAssertEqual(provider.label, "claude")
        XCTAssertEqual(provider.source, .provider)
        XCTAssertFalse(provider.verified)
    }

    func testWorktreeIdentityAndEnvironmentPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root.appendingPathComponent("home")).createDirectories()
        _ = Shell.run("/usr/bin/git", ["init", root.path])
        _ = Shell.run("/usr/bin/git", ["-C", root.path, "config", "gentlemerge.label", "claude"])
        let local = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths, environment: [:])
        XCTAssertEqual(local.label, "claude")
        XCTAssertEqual(local.source, .worktree)
        XCTAssertTrue(local.verified)
        let withExecutorName = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths,
            environment: ["GENTLEMERGE_NAME": "other#exec"])
        XCTAssertEqual(withExecutorName.label, "claude")
        XCTAssertTrue(withExecutorName.verified)
        XCTAssertEqual(Identity.resolve(cwd: root.path, provider: .unknown, paths: paths,
            environment: ["GENTLEMERGE_LABEL": "codex"]).label, "codex")
    }

    func testExecutorEnvNameSignsWhenNothingStrongerExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        let executor = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths,
            environment: ["GENTLEMERGE_NAME": "claude#exec1"])
        XCTAssertEqual(executor.label, "claude#exec1")
        XCTAssertFalse(executor.verified)
        // The strong label still beats the executor name.
        let strong = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths,
            environment: ["GENTLEMERGE_LABEL": "codex", "GENTLEMERGE_NAME": "claude#exec1"])
        XCTAssertEqual(strong.label, "codex")
        XCTAssertTrue(strong.verified)
    }

    func testEnvironmentIdentityRejectsImpersonation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        let identity = Identity.resolve(cwd: root.path, provider: .unknown, paths: paths,
                                        environment: ["GENTLEMERGE_LABEL": "codex"])
        XCTAssertEqual(identity.label, "codex")
        XCTAssertTrue(identity.verified)
        XCTAssertEqual(try Identity.reconcile(explicit: "codex", resolved: identity), identity)
        XCTAssertThrowsError(try Identity.reconcile(explicit: "claude", resolved: identity))
    }
}

extension IdentityTests {
    /// SECURITY.md promises `[A-Za-z0-9#-_.]{1,24}`: stripped, cut, and never
    /// empty — an empty label would file presence and messages under nobody.
    func testSafeNeverReturnsAnEmptyLabel() {
        XCTAssertEqual(Identity.safe("claude"), "claude")
        XCTAssertEqual(Identity.safe("claude#exec1"), "claude#exec1")
        XCTAssertEqual(Identity.safe("a/b"), "ab")
        XCTAssertEqual(Identity.safe("!!!"), "agent")
        XCTAssertEqual(Identity.safe(""), "agent")
        XCTAssertEqual(Identity.safe(String(repeating: "a", count: 30)).count, 24)
    }
}
