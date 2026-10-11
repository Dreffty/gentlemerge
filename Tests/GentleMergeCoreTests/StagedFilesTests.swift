import XCTest
@testable import GentleMergeCore

/// The gate's own eyes: `stagedFiles` deciding what the pre-commit hook gets
/// to judge.
///
/// These are integration tests against a real git repository on purpose. Every
/// bug they pin lived in *how git's output was read*, so a unit test over a
/// hand-written string array would have passed happily while the hook walked
/// straight past a claimed file (audit 2026-10-07).
final class StagedFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID())")
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
        guard out.succeeded else { throw NSError(domain: "git", code: Int(out.status), userInfo: [NSLocalizedDescriptionKey: out.stderr]) }
        return out.stdout
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func stage(_ relatives: [String]) throws {
        try git(["add", "--"] + relatives)
    }

    private var gate: PrecommitGate { PrecommitGate(paths: Paths(home: root.appendingPathComponent("home"))) }

    /// A path holding a non-ASCII byte must arrive at the gate as itself.
    /// `--name-only` C-quoted it (`"lib/donn\303\251es/caf\303\251.txt"`), which
    /// matches no zone pattern but a bare `**` — so `lib/données/**` was not
    /// enforced for any accented file.
    func testANonASCIIPathIsReadAsItselfNotQuoted() throws {
        try write("lib/données/café.txt", "hello")
        try stage(["lib/données/café.txt"])

        let staged = gate.stagedFiles(repo: root)

        XCTAssertEqual(staged, ["lib/données/café.txt"])
        XCTAssertTrue(
            Glob.matches("lib/données/**", staged[0]),
            "the claim pattern must match the path the gate actually reads"
        )
    }

    /// A path with a quote or a backslash in it — the other half of C-quoting.
    func testAPathWithQuotesAndBackslashesSurvives() throws {
        try write("lib/we\"ird\\name.txt", "hello")
        try stage(["lib/we\"ird\\name.txt"])

        XCTAssertEqual(gate.stagedFiles(repo: root), ["lib/we\"ird\\name.txt"])
    }

    /// A file replaced by a symlink is a typechange (`T`). The old filter was
    /// `ACMRD`, so `stagedFiles` returned nothing and the gate passed a commit
    /// that gutted a claimed file.
    func testAFileReplacedByASymlinkIsSeen() throws {
        try write("hermes_zone/secret.txt", "real contents")
        try git(["add", "-A"])
        try git(["commit", "-qm", "seed"])
        // Replace it with a symlink pointing outside the repo.
        try FileManager.default.removeItem(at: root.appendingPathComponent("hermes_zone/secret.txt"))
        try write("outside/target.txt", "elsewhere")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("hermes_zone/secret.txt"),
            withDestinationURL: root.appendingPathComponent("outside/target.txt")
        )
        try stage(["hermes_zone/secret.txt"])

        XCTAssertEqual(
            gate.stagedFiles(repo: root), ["hermes_zone/secret.txt"],
            "a typechange must reach the gate, or swapping a claimed file for a symlink is invisible"
        )
    }

    /// A rename must report the path being given up as well as the one being
    /// taken. `--name-only` reported only the destination, so a file could be
    /// moved *out of* another agent's claim without the old name ever being
    /// named. Note the commit needs no `git mv`: re-adding identical content is
    /// also reported as a rename.
    func testARenameReportsBothTheOldAndTheNewName() throws {
        try write("hermes_zone/models.dart", "class Model {}")
        try git(["add", "-A"])
        try git(["commit", "-qm", "seed"])

        try FileManager.default.createDirectory(at: root.appendingPathComponent("mine"), withIntermediateDirectories: true)
        try git(["mv", "hermes_zone/models.dart", "mine/models.dart"])
        let staged = gate.stagedFiles(repo: root)

        XCTAssertTrue(staged.contains("hermes_zone/models.dart"), "the claimed path must be checked: \(staged)")
        XCTAssertTrue(staged.contains("mine/models.dart"), "the new path must be checked: \(staged)")
    }

    /// And the "delete then re-add, differing by a byte" spelling of a rename,
    /// which is `R092` and needs no `git mv` at all.
    func testADeleteAndReaddThatLooksLikeARenameStillNamesTheOldPath() throws {
        try write("hermes_zone/models.dart", "class Model {}")
        try git(["add", "-A"])
        try git(["commit", "-qm", "seed"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("hermes_zone/models.dart"))
        try write("mine/models.dart", "class Model { }")   // one extra byte
        try git(["add", "-A"])

        XCTAssertTrue(
            gate.stagedFiles(repo: root).contains("hermes_zone/models.dart"),
            "git calls this R092; the gate still has to see the claimed path"
        )
    }

    /// Failing open is the worst possible default for an enforcement point: a
    /// git that cannot answer must not read as "nothing is claimed".
    func testAnUnreadableIndexBlocksInsteadOfPassingSilently() throws {
        let violations = PrecommitGate.evaluate(
            staged: [PrecommitGate.unreadableIndexSentinel],
            me: "codex",
            claims: [],
            ownership: Ownership(rules: [])
        )

        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations[0].blocking, "an unknown index must not be waved through")
    }

    /// Outside a repository, `stagedFiles` must surface the failure, not [].
    func testOutsideARepositoryItReportsRatherThanReturningEmpty() {
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("notarepo-\(UUID())")
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        XCTAssertEqual(
            gate.stagedFiles(repo: elsewhere), [PrecommitGate.unreadableIndexSentinel],
            "no index means no verdict, and no verdict must not mean 'pass'"
        )
    }

    /// The parser itself, independent of git: both names for a rename, one for
    /// everything else, and no phantom entries from the NUL framing.
    func testTheParserReadsBothNamesOfARename() {
        XCTAssertEqual(
            PrecommitCheck.parseStagedNameStatus("R100\0old.txt\0new.txt"),
            ["old.txt", "new.txt"]
        )
        XCTAssertEqual(
            PrecommitCheck.parseStagedNameStatus("M\0a.txt\0A\0lib/b.txt\0"),
            ["a.txt", "lib/b.txt"]
        )
        XCTAssertEqual(
            PrecommitCheck.parseStagedNameStatus("D\0gone.txt\0"), ["gone.txt"]
        )
        XCTAssertEqual(PrecommitCheck.parseStagedNameStatus(""), [])
        // Truncated framing must not crash or invent a path.
        XCTAssertEqual(PrecommitCheck.parseStagedNameStatus("R100\0old.txt"), [])
    }
}