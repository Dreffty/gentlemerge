import XCTest
@testable import GentleMergeCore

final class ReviewTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: project, timeout: 30)
    }

    // MARK: - Detection

    func testASwiftPackageKnowsHowToCheckItself() throws {
        try write("Package.swift", "// swift-tools-version: 6.0")
        let checks = ProjectChecks.checks(for: project)

        XCTAssertEqual(checks.map(\.name), ["swift build", "swift test"])
        XCTAssertEqual(checks.first { $0.kind == .test }?.command, "swift test")
    }

    func testNodeChecksFollowTheLockfileAndTheScriptsThatExist() throws {
        try write("package.json", #"{"scripts":{"build":"vite build","test":"vitest run"}}"#)
        try write("pnpm-lock.yaml", "lockfileVersion: 9")

        let checks = ProjectChecks.checks(for: project)
        XCTAssertEqual(checks.map(\.command), ["pnpm run build", "pnpm test"])

        // A script that is not in package.json is not invented.
        XCTAssertFalse(checks.contains { $0.command.contains("lint") })
    }

    func testTypescriptWithoutATypecheckScriptStillGetsOne() throws {
        try write("package.json", #"{"scripts":{}}"#)
        try write("tsconfig.json", "{}")

        let checks = ProjectChecks.checks(for: project)
        let typecheck = try XCTUnwrap(checks.first { $0.kind == .typecheck })
        XCTAssertEqual(typecheck.command, "npx --no-install tsc --noEmit")
        XCTAssertTrue(typecheck.optional, "anything that might hit the network stays opt-in")
    }

    func testXcodeSchemesAreReadFromDiskNotFromXcodebuild() throws {
        // A helper scheme sorts first alphabetically; the app's own scheme is
        // the one you actually meant.
        try write("ForgeDesk.xcodeproj/xcshareddata/xcschemes/AAATests.xcscheme", "<Scheme/>")
        try write("ForgeDesk.xcodeproj/xcshareddata/xcschemes/ForgeDesk.xcscheme", "<Scheme/>")
        let checks = ProjectChecks.checks(for: project)

        let xcode = try XCTUnwrap(checks.first { $0.name.hasPrefix("xcodebuild") })
        XCTAssertTrue(xcode.command.contains("-scheme 'ForgeDesk'"))
        XCTAssertTrue(xcode.optional, "Xcode builds are slow enough to be a choice")
    }

    func testAProjectCanOverrideEverything() throws {
        try write("Package.swift", "// swift-tools-version: 6.0")
        try write(
            ProjectChecks.configFileName,
            #"{"replaceDetected":true,"checks":[{"name":"house rules","command":"make verify","kind":"test","timeout":60,"optional":false}]}"#
        )

        let checks = ProjectChecks.checks(for: project)
        XCTAssertEqual(checks.map(\.name), ["house rules"])
    }

    func testMakefileTestTargetIsFound() throws {
        try write("Makefile", "build:\n\tswift build\n\ntest:\n\tswift test\n")
        XCTAssertEqual(ProjectChecks.makefileTarget(in: project), "test")
        XCTAssertEqual(ProjectChecks.checks(for: project).map(\.command), ["make test"])
    }

    func testTheMakefileDoesNotDuplicateTestsWeAlreadyFound() throws {
        try write("Package.swift", "// swift-tools-version: 6.0")
        try write("Makefile", "test:\n\tswift test\n")

        // `make test` here is the same run as `swift test`; running both is
        // twice the wait for the same answer.
        XCTAssertEqual(ProjectChecks.checks(for: project).map(\.command), ["swift build", "swift test"])
    }

    // MARK: - What changed

    func testWorkIsMeasuredAgainstWhereTheSessionStarted() throws {
        git(["init", "-q"])
        git(["config", "user.email", "t@example.com"])
        git(["config", "user.name", "T"])
        try write("App.swift", "let a = 1\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "before"])
        let baseline = git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // The agent commits one change and leaves another uncommitted.
        try write("App.swift", "let a = 2\nlet b = 3\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "agent commit"])
        try write("Views/HomeView.swift", "// new view\n")

        let work = WorkInspector.summarize(projectPath: project.path, baseline: baseline)

        XCTAssertTrue(work.isRepository)
        XCTAssertFalse(work.baselineIsHead, "the session moved HEAD, so the diff spans commits")
        XCTAssertTrue(work.changes.contains { $0.path == "App.swift" && $0.added == 2 })
        let created = try XCTUnwrap(work.changes.first { $0.path == "Views/HomeView.swift" })
        XCTAssertTrue(created.isUntracked)
    }

    func testANonRepositoryIsReportedAsUnknowable() {
        let work = WorkInspector.summarize(projectPath: project.path, baseline: nil)
        XCTAssertFalse(work.isRepository)

        let questions = WorkInspector.openQuestions(for: work, checks: [])
        XCTAssertTrue(questions.contains { $0.contains("not a git repository") })
    }

    // MARK: - What no machine can answer

    func testTheReportSaysWhatItCannotKnow() {
        let work = WorkSummary(
            projectPath: "/tmp/p",
            isRepository: true,
            baseline: "abc",
            baselineIsHead: true,
            changes: [
                FileChange(path: "Sources/HomeView.swift", status: "M", added: 40, removed: 2),
                FileChange(path: "Sources/Engine.swift", status: "M", added: 90, removed: 10),
                FileChange(path: "Sources/Store.swift", status: "M", added: 12, removed: 0),
                FileChange(path: "Package.resolved", status: "M", added: 4, removed: 4),
            ],
            outsidePaths: ["/tmp/.zshrc"]
        )

        let passed = CheckResult(name: "swift build", command: "swift build", kind: .build, status: .passed)
        let questions = WorkInspector.openQuestions(for: work, checks: [passed])

        XCTAssertTrue(questions.contains { $0.contains("how it looks") }, "view changes need eyes")
        XCTAssertTrue(questions.contains { $0.contains("no test file did") })
        XCTAssertTrue(questions.contains { $0.contains("lockfile") })
        XCTAssertTrue(questions.contains { $0.contains("outside the project") })
        XCTAssertTrue(questions.contains { $0.contains("nothing confirmed behaviour") })
    }

    func testAPassingBuildIsNeverReportedAsEverythingBeingFine() {
        let work = WorkSummary(projectPath: "/tmp/p", isRepository: true, baseline: "a", baselineIsHead: true)
        let review = Review(
            projectPath: "/tmp/p",
            finishedAt: Date(),
            work: work,
            checks: [CheckResult(name: "swift build", command: "swift build", kind: .build, status: .passed)],
            openQuestions: WorkInspector.openQuestions(for: work, checks: [
                CheckResult(name: "swift build", command: "swift build", kind: .build, status: .passed),
            ])
        )

        XCTAssertEqual(review.verdict, .passed)
        XCTAssertEqual(review.headline, "1 check passed")
        XCTAssertFalse(review.openQuestions.isEmpty, "passing checks still leave open questions")
    }

    func testNothingRunnableMeansUnverifiedNotClean() {
        let review = Review(
            projectPath: "/tmp/p",
            finishedAt: Date(),
            work: WorkSummary(projectPath: "/tmp/p", isRepository: false),
            checks: []
        )
        XCTAssertEqual(review.verdict, .unverified)
        XCTAssertEqual(review.headline, "Nothing could be checked automatically")
    }

    func testAFailedCheckDominatesTheVerdict() {
        let review = Review(
            projectPath: "/tmp/p",
            finishedAt: Date(),
            work: WorkSummary(projectPath: "/tmp/p", isRepository: true),
            checks: [
                CheckResult(name: "build", command: "b", kind: .build, status: .passed),
                CheckResult(name: "test", command: "t", kind: .test, status: .failed, exitCode: 1),
            ]
        )
        XCTAssertEqual(review.verdict, .problems)
        XCTAssertEqual(review.headline, "1 of 2 checks failed")
    }
}
