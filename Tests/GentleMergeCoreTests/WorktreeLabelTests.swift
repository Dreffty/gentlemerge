import XCTest
@testable import GentleMergeCore

/// The label a worktree declares for itself is the identity every consumer
/// compares, so two things have to hold: what git stores is what every reader
/// computes, and writing it must never cost the user their repository.
final class WorktreeLabelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wtlabel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "t@example.com"])
        try git(["config", "user.name", "t"])
        try "seed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"]); try git(["commit", "-qm", "seed"])
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

    /// Labels are compared as strings against claims, `--to` routes and presence
    /// marks, all of which go through `Identity.safe`. A stored value safe would
    /// alter made the gate judge a worktree against a claim it could never match
    /// (audit 2026-10-08).
    func testTheStoredLabelIsTheSafeOne() throws {
        _ = try WorktreeLabel.write(label: "🚀rocket", in: root)
        XCTAssertEqual(try git(["config", "--get", "gentlemerge.label"]).trimmingCharacters(in: .whitespacesAndNewlines), "rocket")
        XCTAssertEqual(WorktreeLabel.read(cwd: root), "rocket")
    }

    /// A value written by hand (or by an older binary) is normalised on read, so
    /// an existing repository is healed rather than left mismatched.
    func testAHandEditedLabelIsSafeOnReadToo() throws {
        try git(["config", "extensions.worktreeConfig", "true"])
        try git(["config", "--worktree", "gentlemerge.label", "🚀rocket"])
        XCTAssertEqual(WorktreeLabel.read(cwd: root), "rocket")
    }

    /// Enabling `extensions.worktreeConfig` in a *bare* repository's common
    /// config makes git consider every linked worktree bare too, and every
    /// command dies with "this operation must be run in a work tree" — the
    /// user's repository, not just our label (audit 2026-10-08).
    func testABareRepositoryIsRefusedRatherThanBricked() throws {
        let bare = root.appendingPathComponent("bare.git")
        for arguments in [["init", "-q", "--bare", bare.path]] {
            let out = Shell.run("/usr/bin/env", ["git"] + arguments, in: root, timeout: 30)
            XCTAssertTrue(out.succeeded, out.stderr)
        }
        let added = Shell.run("/usr/bin/env", ["git", "-C", bare.path, "worktree", "add", "-q", "../w1", "-b", "agent/x"],
                              in: root, timeout: 30)
        if added.succeeded {
            let worktree = root.appendingPathComponent("w1")
            XCTAssertThrowsError(try WorktreeLabel.write(label: "f1", in: worktree)) { error in
                XCTAssertTrue("\(error)".contains("bare"), "\(error)")
            }
            // The extension was never written, so the worktree still works.
            let status = Shell.run("/usr/bin/env", ["git", "status", "--short"], in: worktree, timeout: 30)
            XCTAssertTrue(status.succeeded, status.stderr)
        } else {
            // A bare repo with no commits cannot host a worktree; assert the
            // guard on the bare directory itself, which is the same write path.
            XCTAssertThrowsError(try WorktreeLabel.write(label: "f1", in: bare))
        }
    }

    /// A normal repository still gets its label, and round-trips.
    func testANormalRepositoryRoundTripsItsLabel() throws {
        _ = try WorktreeLabel.write(label: "hermes", in: root)
        XCTAssertEqual(WorktreeLabel.read(cwd: root), "hermes")
    }
}
