import XCTest
@testable import GentleMergeCore

/// Two failures in the git-hook installer, both invisible from the CLI: it
/// reported success while leaving the hook broken, or refused outright while
/// naming the wrong cause.
final class GitHookInstallTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var repo: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ghinstall-\(UUID())")
        paths = Paths(home: root.appendingPathComponent("home"))
        repo = root.appendingPathComponent("repo")
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            let out = Shell.run("/usr/bin/env", ["git"] + args, in: repo, timeout: 30)
            XCTAssertTrue(out.succeeded, out.stderr)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var hooksDir: URL { repo.appendingPathComponent(".git/hooks") }

    private func hookBody(_ name: String) -> String? {
        try? String(contentsOf: hooksDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// #38 — the idempotency check was `body.contains(marker)`, and `marker` is
    /// a compile-time constant while the body bakes in the resolved gate path.
    /// So installing again under a different home said "already installed" and
    /// left the hook pointing at the old one — while `ensureBinaryLink` re-linked
    /// the binary into the new home, so the hook could not find it. Every commit
    /// then printed "gate binary not found … this commit is NOT checked" and
    /// passed unchecked.
    func testReinstallingUnderANewHomeRefreshesTheBakedPath() throws {
        let installer = GitHookInstaller(paths: paths)
        let first = try installer.install(repo: repo)
        XCTAssertTrue(first.hasPrefix("installed"), "the first pass must install: \(first)")

        let oldGate = try XCTUnwrap(GitHookInstaller.gateDefault(paths: paths))
        XCTAssertTrue(
            hookBody("pre-commit")?.contains(oldGate) == true,
            "the first install must bake in the resolved gate path"
        )

        // Same home, same body: genuinely idempotent, nothing new.
        XCTAssertTrue(
            try installer.install(repo: repo).hasPrefix("already installed"),
            "a second identical install must be a no-op" 
        )

        // Now move the home, as GENTLEMERGE_HOME would.
        let moved = paths.home.appendingPathComponent("moved-home")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let movedPaths = Paths(home: moved)
        let reinstalled = try GitHookInstaller(paths: movedPaths).install(repo: repo)

        XCTAssertTrue(
            reinstalled.hasPrefix("installed"),
            "a different home bakes a different gate path, so this is not a no-op: \(reinstalled)"
        )
        let newGate = GitHookInstaller.gateDefault(paths: movedPaths)
        XCTAssertNotEqual(newGate, oldGate)
        XCTAssertTrue(
            hookBody("pre-commit")?.contains(newGate) == true,
            "the hook must now point at the gate under the new home"
        )
        XCTAssertFalse(
            hookBody("pre-commit")?.contains(oldGate) == true,
            "and must not still be pointing at the old one"
        )
    }

    /// #39 — a stale `*.gentlemerge-prev` from an earlier chain made `moveItem`
    /// throw, which escaped the install loop: exit 1, nothing installed, and the
    /// message named the collision rather than the cause.
    func testAStaleChainedHookDoesNotAbortTheInstall() throws {
        let hooks = hooksDir
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        // A foreign hook plus a stale copy of where it was already moved.
        let preCommit = hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\n# husky\necho husky\n".write(to: preCommit, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n# husky\nstale\n".write(
            to: hooks.appendingPathComponent("pre-commit.gentlemerge-prev"),
            atomically: true, encoding: .utf8
        )

        let installed = try GitHookInstaller(paths: paths).install(repo: repo)

        XCTAssertTrue(installed.contains("pre-commit"), "the install must complete: \(installed)")
        let body = try XCTUnwrap(hookBody("pre-commit"))
        XCTAssertTrue(body.contains(GitHookInstaller.marker), "our gate must be installed")
        // The foreign hook is chained, never destroyed — the whole point.
        XCTAssertTrue(
            hookBody("pre-commit.gentlemerge-prev")?.contains("husky") == true,
            "the foreign hook must survive as the chained predecessor"
        )
    }

    /// Chaining must still work on a first install, with nothing stale around.
    func testAForeignHookIsChainedNotOverwritten() throws {
        let hooks = hooksDir
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let preCommit = hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\n# lint-staged\necho lint-staged\n".write(to: preCommit, atomically: true, encoding: .utf8)

        _ = try GitHookInstaller(paths: paths).install(repo: repo)

        XCTAssertTrue(hookBody("pre-commit")?.contains("gentlemerge-prev") == true,
                      "our hook must chain whatever was there")
        XCTAssertTrue(hookBody("pre-commit.gentlemerge-prev")?.contains("lint-staged") == true,
                      "the foreign hook must be preserved verbatim")
    }

    /// `uninstall` must put the world back the way it found it.
    func testUninstallRestoresTheChainedHook() throws {
        let hooks = hooksDir
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let preCommit = hooks.appendingPathComponent("pre-commit")
        try "#!/bin/sh\n# lint-staged\necho lint-staged\n".write(to: preCommit, atomically: true, encoding: .utf8)

        let installer = GitHookInstaller(paths: paths)
        _ = try installer.install(repo: repo)
        XCTAssertEqual(try installer.uninstall(repo: repo), "removed")

        XCTAssertFalse(FileManager.default.fileExists(atPath: preCommit.appendingPathExtension("gentlemerge-prev").path),
                       "the chained predecessor must be moved back into place")
        XCTAssertTrue(hookBody("pre-commit")?.contains("lint-staged") == true,
                      "and it must be the foreign hook again")
    }
}