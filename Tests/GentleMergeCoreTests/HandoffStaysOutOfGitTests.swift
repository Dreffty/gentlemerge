import XCTest
@testable import GentleMergeCore

/// The handoff is rewritten after every commit, because it lists the last ones. In git
/// it comes up modified for ever: Toca Plan had it tracked twice, and both copies were
/// always in the way of the next `git status`.
final class HandoffStaysOutOfGitTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var binary: String!
    private var home: String { root.appendingPathComponent("home").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-git-\(UUID())")
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"], ["config", "user.name", "t"]] {
            XCTAssertEqual(git(arguments).status, 0)
        }
        try Data("hola\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        XCTAssertEqual(git(["add", "-A"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "first"]).status, 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: repo)
    }

    private func run(_ arguments: [String]) -> Shell.Output {
        Shell.run(binary, arguments, in: repo, environment: ["GENTLEMERGE_HOME": home])
    }

    private var ignoreFile: String {
        (try? String(contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
    }

    func testInitKeepsTheHandoffOutOfGit() throws {
        XCTAssertEqual(run(["project", "init"]).status, 0)
        XCTAssertTrue(ignoreFile.contains(".gentlemerge/HANDOFF.md\n"), ignoreFile)
        XCTAssertTrue(ignoreFile.contains(".gentlemerge/env.sh\n"), ignoreFile)

        let status = git(["status", "--porcelain"]).stdout
        XCTAssertFalse(status.contains(".gentlemerge"), status)
    }

    func testARepeatedInitAddsNothingAndKeepsWhatWasThere() throws {
        try Data("build/".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        XCTAssertEqual(run(["project", "init"]).status, 0)
        let first = ignoreFile
        XCTAssertEqual(run(["project", "init"]).status, 0)
        XCTAssertEqual(ignoreFile, first)
        XCTAssertEqual(first, "build/\n.gentlemerge/env.sh\n.gentlemerge/HANDOFF.md\n")
    }

    /// `.gitignore` does nothing for a file git already follows. Untracking it is a
    /// change in somebody's repository, so `init` says the line and leaves it to them.
    func testATrackedHandoffIsNamedAndLeftAlone() throws {
        XCTAssertEqual(run(["project", "init"]).status, 0)
        XCTAssertEqual(git(["add", "-f", ".gentlemerge/HANDOFF.md"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "tracked by mistake"]).status, 0)

        let again = run(["project", "init"])
        XCTAssertEqual(again.status, 0, again.text)
        XCTAssertTrue(again.stdout.contains("git rm --cached .gentlemerge/HANDOFF.md"), again.stdout)
        XCTAssertTrue(git(["ls-files", ".gentlemerge/HANDOFF.md"]).stdout.contains("HANDOFF.md"), "still tracked")
    }

    func testDoctorNamesATrackedHandoff() throws {
        XCTAssertEqual(run(["project", "init"]).status, 0)
        XCTAssertEqual(check().level, .ok, check().detail)

        XCTAssertEqual(git(["add", "-f", ".gentlemerge/HANDOFF.md"]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "tracked by mistake"]).status, 0)

        XCTAssertEqual(check().level, .warn)
        XCTAssertTrue(check().detail.contains("git rm --cached .gentlemerge/HANDOFF.md"), check().detail)
    }

    /// Set up before this was the rule: one `git add -A` away from being tracked.
    func testDoctorNamesAHandoffThatIsNotIgnored() throws {
        XCTAssertEqual(run(["project", "init"]).status, 0)
        try Data().write(to: repo.appendingPathComponent(".gitignore"))

        XCTAssertEqual(check().level, .warn)
        XCTAssertTrue(check().detail.contains("gentlemerge project init"), check().detail)
    }

    func testAFolderWithNoRepositoryHasNothingToTrack() throws {
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(Doctor.handoffInGit(project: plain.path).level, .ok)
    }

    private func check() -> Doctor.Check {
        Doctor.handoffInGit(project: repo.path)
    }
}
