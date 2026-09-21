import XCTest
@testable import GentleMergeCore

final class ProjectMapTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    @discardableResult
    private func git(_ arguments: [String]) -> Shell.Output {
        Shell.run("/usr/bin/env", ["git"] + arguments, in: project, timeout: 30)
    }

    private func commitEverything(_ message: String) {
        git(["add", "-A"])
        git(["commit", "-q", "-m", message])
    }

    private func makeRepository() {
        git(["init", "-q"])
        git(["config", "user.email", "t@example.com"])
        git(["config", "user.name", "T"])
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = project.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    /// The smallest thing that still looks like a real Swift package.
    private func makeSwiftPackage() throws {
        try write("// swift-tools-version: 6.0\n", to: "Package.swift")
        try write("print(\"hello\")\n", to: "Sources/App/main.swift")
        try write(String(repeating: "// filler\n", count: 200), to: "Sources/App/Engine.swift")
        try write("import XCTest\n", to: "Tests/AppTests/EngineTests.swift")
    }

    // MARK: - What it finds

    func testTheMapDescribesTheProjectAndHowToRunIt() throws {
        try makeSwiftPackage()

        let map = ProjectMap.build(for: project.path, head: nil)

        XCTAssertEqual(map.stack, ["Swift", "SwiftPM"])
        XCTAssertEqual(map.commands, ["`swift build`", "`swift test`"], "detected, not invented")
        XCTAssertEqual(map.fileCount, 4, "three sources and the manifest, which is Swift too")
        XCTAssertEqual(map.directories, ["Sources (2)", "Tests (1)"])
        XCTAssertEqual(map.hubs.first, "Package.swift", "the file that answers 'what is this'")
        XCTAssertTrue(map.hubs.contains("Sources/App/main.swift"), "the entry point by convention")
        XCTAssertTrue(map.hubs.contains("Sources/App/Engine.swift"), "the biggest source file")
        XCTAssertLessThanOrEqual(map.hubs.count, ProjectMap.maximumHubs)
    }

    func testDependencyAndBuildDirectoriesAreNeverWalked() throws {
        try makeSwiftPackage()
        for index in 0..<50 {
            try write("module.exports = {}\n", to: "node_modules/pkg\(index)/index.js")
        }
        try write("compiled\n", to: "build/Generated.swift")
        try write("cached\n", to: ".build/checkouts/Thing.swift")

        let map = ProjectMap.build(for: project.path, head: nil)

        XCTAssertEqual(map.fileCount, 4, "somebody else's code is not this project's shape")
        XCTAssertFalse(map.directories.contains { $0.hasPrefix("node_modules") })
        XCTAssertFalse(map.hubs.contains { $0.contains("node_modules") || $0.contains("build/") })
    }

    func testADirectoryThatIsNotAProjectSaysNothing() {
        // Silence is the point: an empty folder must not cost a session a
        // single token.
        XCTAssertTrue(ProjectMap.build(for: project.path, head: nil).isEmpty)
        XCTAssertNil(ProjectRegistry.sessionContext(for: project.path))
    }

    // MARK: - Freshness

    func testAProjectWithoutGitStillGetsAMapWithNoSeal() throws {
        try makeSwiftPackage()

        let map = ProjectMap.build(for: project.path, head: nil)
        XCTAssertNil(map.commit)
        XCTAssertFalse(map.isStale(comparedTo: nil), "nothing to drift from")

        let context = try XCTUnwrap(ProjectRegistry.sessionContext(for: project.path))
        XCTAssertTrue(context.contains("no git here"), "say why there is no commit rather than lying")
    }

    func testTheMapIsSealedWithHeadAndRebuiltWhenHeadMovesOn() throws {
        try makeSwiftPackage()
        makeRepository()
        commitEverything("First")
        try ProjectRegistry.initialize(projectPath: project.path)

        _ = ProjectRegistry.sessionContext(for: project.path)
        let first = try XCTUnwrap(ProjectRegistry.handoff(for: project.path, refreshingCommits: false).map)
        XCTAssertTrue(first.isSealed(with: ProjectRegistry.currentCommit(in: project.path)))

        try write("print(\"more\")\n", to: "Sources/App/Extra.swift")
        commitEverything("Second")

        _ = ProjectRegistry.sessionContext(for: project.path)
        let second = try XCTUnwrap(ProjectRegistry.handoff(for: project.path, refreshingCommits: false).map)

        XCTAssertNotEqual(second.commit, first.commit, "a new commit means a new map")
        XCTAssertTrue(second.isSealed(with: ProjectRegistry.currentCommit(in: project.path)))
        XCTAssertEqual(second.fileCount, 5, "and it sees the file that arrived with it")
    }

    func testACachedMapAdmitsItMayBeStaleInsteadOfBeingRebuilt() throws {
        try makeSwiftPackage()
        makeRepository()
        commitEverything("First")
        try ProjectRegistry.initialize(projectPath: project.path)
        _ = ProjectRegistry.sessionContext(for: project.path)

        try write("print(\"more\")\n", to: "Sources/App/Extra.swift")
        commitEverything("Second")

        // The reader's version: no walk, no rewrite, but no pretending either.
        let context = try XCTUnwrap(
            ProjectRegistry.sessionContext(for: project.path, refreshingMap: false)
        )
        XCTAssertTrue(context.contains("may be stale"), context)

        let onDisk = try XCTUnwrap(ProjectRegistry.handoff(for: project.path, refreshingCommits: false).map)
        XCTAssertEqual(onDisk.fileCount, 4, "a read must not have rewritten the file")
    }

    func testTheMapIsCachedInTheHandoffButNeverCreatesOne() throws {
        try makeSwiftPackage()

        // No handoff file: a session starting here is not permission to leave
        // one behind, so the map is built for this session only.
        _ = ProjectRegistry.sessionContext(for: project.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectHandoff.fileURL(for: project.path).path))

        try ProjectRegistry.initialize(projectPath: project.path)
        _ = ProjectRegistry.sessionContext(for: project.path)

        let text = try String(contentsOf: ProjectHandoff.fileURL(for: project.path), encoding: .utf8)
        XCTAssertTrue(text.contains("## \(HandoffMarkdown.mapHeading)"))
        XCTAssertTrue(text.contains("`swift build`"))
    }

    func testAskingForTheCachedMapNeverWritesToTheProject() throws {
        try makeSwiftPackage()
        try ProjectRegistry.initialize(projectPath: project.path)
        let before = try Data(contentsOf: ProjectHandoff.fileURL(for: project.path))

        // `gentlemerge brief` runs inside somebody's repository, possibly one
        // this session was told not to touch. It reads.
        let context = try XCTUnwrap(
            ProjectRegistry.sessionContext(for: project.path, refreshingMap: false)
        )
        let after = try Data(contentsOf: ProjectHandoff.fileURL(for: project.path))

        XCTAssertTrue(context.contains("Project map"), "still worth showing, just not worth writing")
        XCTAssertEqual(before, after, "a read left a diff behind")
    }

    func testGeneratedBundlesAreNotWhereYouStartReading() throws {
        try makeSwiftPackage()
        try write(String(repeating: "a", count: 400_000), to: "web/vendor.min.js")
        try write(String(repeating: "b", count: 300_000), to: "web/table.js")

        let map = ProjectMap.build(for: project.path, head: nil)

        XCTAssertFalse(map.hubs.contains { $0.contains("min.js") || $0.contains("table.js") })
        XCTAssertEqual(map.fileCount, 5, "the hand-written one still counts as code")
    }

    // MARK: - The file

    func testTheMapSurvivesARoundTripThroughTheFile() {
        let map = ProjectMap(
            stack: ["Swift", "SwiftPM"],
            commands: ["`swift build`", "`swift test`"],
            fileCount: 44,
            directories: ["Sources (34)", "Tests (7)"],
            hubs: ["Package.swift", "Sources/App/main.swift"],
            commit: "2a893f11c0ffee0000000000000000000000abcd",
            builtAt: HandoffMarkdown.dayFormatter.date(from: "2026-08-21")!
        )
        let handoff = ProjectHandoff(projectPath: "/tmp/p", projectName: "p", map: map)

        let parsed = HandoffMarkdown.parse(HandoffMarkdown.render(handoff), projectPath: "/tmp/p")
        let readBack = try? XCTUnwrap(parsed.map)

        XCTAssertEqual(readBack?.stack, map.stack)
        XCTAssertEqual(readBack?.commands, map.commands)
        XCTAssertEqual(readBack?.fileCount, map.fileCount)
        XCTAssertEqual(readBack?.directories, map.directories)
        XCTAssertEqual(readBack?.hubs, map.hubs)
        XCTAssertEqual(readBack?.builtAt, map.builtAt)
        // Only the short form is written down; it is what a reader compares by
        // eye against `git rev-parse HEAD`.
        XCTAssertEqual(readBack?.commit, map.shortCommit)
        XCTAssertTrue(readBack?.isStale(comparedTo: "0000000badc0ffee") == true)

        // Rendering what we just read must not change the file again.
        XCTAssertEqual(HandoffMarkdown.render(parsed), HandoffMarkdown.render(handoff))
    }

    func testAHandoffWrittenBeforeMapsExistedIsStillUnderstood() {
        let text = """
        # gameapp — agent handoff

        ## Recent commits

        - `a1b2c3d` 2026-08-14 — Fix the reward table

        ## Open tasks

        - [ ] Barrer las recompensas rotas

        ## Notes

        The economy sim is in Scripts/.

        ## Decisions

        We are not migrating to SwiftData.
        """

        let handoff = HandoffMarkdown.parse(text, projectPath: "/tmp/p")

        XCTAssertNil(handoff.map, "no map yet is not a broken map")
        XCTAssertEqual(handoff.commits.map(\.subject), ["Fix the reward table"])
        XCTAssertEqual(handoff.tasks.map(\.text), ["Barrer las recompensas rotas"])
        XCTAssertEqual(handoff.notes, "The economy sim is in Scripts/.")

        let rewritten = HandoffMarkdown.render(handoff)
        XCTAssertFalse(rewritten.contains("## \(HandoffMarkdown.mapHeading)"))
        XCTAssertTrue(rewritten.contains("## Decisions"))
        XCTAssertTrue(rewritten.contains("We are not migrating to SwiftData."))
    }

    func testAMapSectionIsRewrittenRatherThanFrozenAsSomebodyElsesWork() {
        let text = """
        # p — agent handoff

        ## Project map

        _Generated from the files on disk at commit `deadbeef` on 2026-01-01 — run `git rev-parse HEAD` to see whether it has moved on._

        - Stack: COBOL
        - [ ] a checkbox somebody dropped in here

        ## Open tasks

        - [ ] one
        """

        let handoff = HandoffMarkdown.parse(text, projectPath: "/tmp/p")

        XCTAssertEqual(handoff.map?.stack, ["COBOL"])
        XCTAssertEqual(handoff.map?.commit, "deadbeef")
        XCTAssertEqual(handoff.extraSections.count, 0, "the map is ours to regenerate, not an extra")
        XCTAssertEqual(
            handoff.tasks.map(\.text),
            ["a checkbox somebody dropped in here", "one"],
            "a task written in the wrong section is still a task"
        )
    }
}
