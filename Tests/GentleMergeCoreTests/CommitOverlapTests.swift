import XCTest
@testable import GentleMergeCore

/// The check an agent runs before it commits: which of its files somebody
/// already committed to, and whether the branch is behind.
final class CommitOverlapTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-precommit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: project, timeout: 30)
    }

    private func write(_ contents: String, to name: String) throws {
        let url = project.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func makeRepository() throws {
        git(["init", "-q"])
        git(["config", "user.email", "t@example.com"])
        git(["config", "user.name", "Codex"])
        try write("one\n", to: "MarkSheet.js")
        try write("two\n", to: "HabitsScreen.js")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "Add the sheets"])
    }

    private func head() -> String {
        git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The comparison

    func testAFileCommittedToWhileYouWorkedIsFlagged() {
        let commit = CommitRecord(
            sha: "aaaaaaa1", date: Date(), subject: "fix the late label",
            author: "codex", files: ["MarkSheet.js"]
        )

        let report = PrecommitCheck.report(
            projectName: "gameapp",
            baseline: "0000000",
            changed: ["MarkSheet.js", "HabitFormModal.js"],
            landed: [commit],
            incoming: [],
            upstream: nil
        )

        XCTAssertEqual(report.overlaps.map(\.path), ["MarkSheet.js"])
        XCTAssertEqual(report.overlaps.first?.commits.map(\.sha), ["aaaaaaa1"])
        XCTAssertEqual(report.untouched, ["HabitFormModal.js"])
        XCTAssertFalse(report.isClear)
        XCTAssertFalse(report.checkedRecentInstead)
    }

    func testAFileNobodyTouchedSaysSoRatherThanWarningAnyway() {
        let report = PrecommitCheck.report(
            projectName: "gameapp",
            baseline: "0000000",
            changed: ["HabitFormModal.js"],
            landed: [
                CommitRecord(
                    sha: "bbbbbbb2", date: Date(), subject: "unrelated",
                    files: ["README.md"]
                ),
            ],
            incoming: [],
            upstream: nil
        )

        XCTAssertTrue(report.overlaps.isEmpty)
        XCTAssertTrue(report.isClear)
        XCTAssertEqual(report.untouched, ["HabitFormModal.js"])
    }

    /// A commit on the remote that is not in your branch is the other way work
    /// disappears, and it has to read differently from one you already have.
    func testACommitOnlyOnTheUpstreamIsMarkedAsIncoming() {
        let mine = CommitRecord(
            sha: "ccccccc3", date: Date(), subject: "mine", files: ["MarkSheet.js"]
        )
        let theirs = CommitRecord(
            sha: "ddddddd4", date: Date(), subject: "theirs", files: ["MarkSheet.js"]
        )

        let report = PrecommitCheck.report(
            projectName: "gameapp",
            baseline: "0000000",
            changed: ["MarkSheet.js"],
            landed: [mine],
            incoming: [theirs],
            upstream: "origin/main"
        )

        XCTAssertEqual(report.overlaps.first?.commits.count, 2)
        XCTAssertFalse(report.isIncoming(mine))
        XCTAssertTrue(report.isIncoming(theirs))
        XCTAssertFalse(report.isClear)
    }

    func testNoBaselineSaysTheWindowIsAGuess() {
        let report = PrecommitCheck.report(
            projectName: "gameapp",
            baseline: nil,
            changed: [],
            landed: [],
            incoming: [],
            upstream: nil
        )

        XCTAssertTrue(report.checkedRecentInstead)
        XCTAssertTrue(report.isClear)
    }

    // MARK: - Reading the working tree

    func testStatusReadsPathsWithSpacesAndBothNamesOfARename() {
        let raw = " M Sources/A B.swift\0?? new file.txt\0R  new/name.swift\0old/name.swift\0"
        XCTAssertEqual(
            PrecommitCheck.parseStatus(raw),
            ["Sources/A B.swift", "new file.txt", "new/name.swift", "old/name.swift"]
        )
    }

    func testAnEmptyStatusIsNoFiles() {
        XCTAssertEqual(PrecommitCheck.parseStatus(""), [])
    }

    // MARK: - Against a real repository

    func testTheCommitThatLandedUnderYouIsTheOneYouAreShown() throws {
        try makeRepository()
        let baseline = head()

        // Somebody else commits while you have the file open.
        try write("one, fixed\n", to: "MarkSheet.js")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "fix: the late microversion label"])

        // And now you have your own uncommitted change to the same file.
        try write("one, fixed, and mine\n", to: "MarkSheet.js")
        try write("three\n", to: "HabitFormModal.js")

        let report = PrecommitCheck.run(in: project.path, baseline: baseline)

        XCTAssertTrue(report.isRepository)
        XCTAssertEqual(report.baseline, baseline)
        XCTAssertEqual(report.changed.sorted(), ["HabitFormModal.js", "MarkSheet.js"])
        XCTAssertEqual(report.overlaps.map(\.path), ["MarkSheet.js"])
        XCTAssertEqual(report.overlaps.first?.commits.first?.subject, "fix: the late microversion label")
        XCTAssertEqual(report.overlaps.first?.commits.first?.author, "Codex")
    }

    /// The first commit of the session is not news: it is the history the file
    /// has always had, and warning about it would train everyone to skip this.
    func testCommitsFromBeforeYourSessionAreNotYourProblem() throws {
        try makeRepository()
        let baseline = head()

        try write("one, mine\n", to: "MarkSheet.js")

        let report = PrecommitCheck.run(in: project.path, baseline: baseline)

        XCTAssertEqual(report.changed, ["MarkSheet.js"])
        XCTAssertTrue(report.landed.isEmpty)
        XCTAssertTrue(report.overlaps.isEmpty)
        XCTAssertTrue(report.isClear)
    }

    /// A baseline from another clone, or one a rebase threw away.
    func testABaselineGitHasNeverHeardOfFallsBackToRecentHistory() throws {
        try makeRepository()
        try write("one, mine\n", to: "MarkSheet.js")

        let report = PrecommitCheck.run(in: project.path, baseline: "0123456789abcdef0123")

        XCTAssertNil(report.baseline)
        XCTAssertTrue(report.checkedRecentInstead)
        // The fallback window is the last few commits, so the file's own first
        // commit is in it — that is exactly why the report says it guessed.
        XCTAssertEqual(report.overlaps.map(\.path), ["MarkSheet.js"])
    }

    func testSomewhereThatIsNotARepositorySaysSoInsteadOfFailing() {
        let report = PrecommitCheck.run(in: NSTemporaryDirectory(), baseline: nil)
        XCTAssertFalse(report.isRepository)
        XCTAssertTrue(report.changed.isEmpty)
    }

    // MARK: - Reading git log

    func testTheLogFormatCarriesTheFilesAndSurvivesADashInTheSubject() {
        let raw = "\u{1e}abc123\u{1f}2026-08-22T10:00:00Z\u{1f}feat: a — b\u{1f}Luis\n"
            + "Sources/A.swift\nTests/B.swift\n"
            + "\u{1e}def456\u{1f}2026-08-21T10:00:00Z\u{1f}Merge branch 'x'\u{1f}Luis\n"

        let commits = ProjectRegistry.parseLog(raw)

        XCTAssertEqual(commits.map(\.sha), ["abc123", "def456"])
        XCTAssertEqual(commits.first?.subject, "feat: a — b")
        XCTAssertEqual(commits.first?.author, "Luis")
        XCTAssertEqual(commits.first?.files, ["Sources/A.swift", "Tests/B.swift"])
        // A merge changed no file on its own, and says so.
        XCTAssertEqual(commits.last?.files, [])
    }
}
