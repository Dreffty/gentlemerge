import XCTest
@testable import GentleMergeCore

/// One directory, two spellings: the advice before an edit must not depend on which one the
/// harness used for the project and which one for the file.
final class AdviseSymlinkedPathTests: XCTestCase {
    private var root: URL!
    private var real: URL!
    private var alias: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advise-paths-\(UUID())").resolvingSymlinksInPath()
        real = root.appendingPathComponent("real")
        alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: real.appendingPathComponent("lib/a.swift"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheRelativePathSeesThroughASymlinkedProjectFolder() {
        XCTAssertEqual(ToolInputFormatter.relativeToCheckout(real.path + "/lib/a.swift", checkout: alias.path), "lib/a.swift")
        XCTAssertEqual(ToolInputFormatter.relativeToCheckout(alias.path + "/lib/a.swift", checkout: real.path), "lib/a.swift")
        XCTAssertEqual(ToolInputFormatter.relativeToCheckout(alias.path + "/lib/a.swift", checkout: alias.path), "lib/a.swift")
    }

    func testDotsAndDoubledSlashesCollapse() {
        XCTAssertEqual(ToolInputFormatter.relativeToCheckout(real.path + "/lib/../lib//a.swift", checkout: real.path), "lib/a.swift")
        XCTAssertEqual(ToolInputFormatter.relativeToCheckout("./lib/a.swift", checkout: real.path), "lib/a.swift")
        XCTAssertEqual(ToolInputFormatter.relativeToCheckout("lib/a.swift", checkout: real.path), "lib/a.swift")
    }

    func testAFileOutsideTheCheckoutOrTheCheckoutItselfIsNotInsideIt() {
        XCTAssertNil(ToolInputFormatter.relativeToCheckout("/etc/hosts", checkout: real.path))
        XCTAssertNil(ToolInputFormatter.relativeToCheckout(real.path + "/../elsewhere/a.swift", checkout: real.path))
        XCTAssertNil(ToolInputFormatter.relativeToCheckout(real.path, checkout: real.path))
        XCTAssertNil(ToolInputFormatter.relativeToCheckout("", checkout: real.path))
    }

    func testAdviseWarnsWhenTheFileAndTheProjectAreSpelledDifferently() throws {
        let home = root.appendingPathComponent("home")
        let paths = try Paths(home: home).createDirectories()
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "init", "-q", "-b", "main"], in: real).status, 0)
        let project = ProjectRegistry.canonicalPath(for: real.path)
        try PathClaims(paths: paths).claim(pattern: "lib/**", label: "claude", project: project, intent: nil)

        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
            ?? ".build/debug/gentlemerge").standardizedFileURL.path
        let payload = root.appendingPathComponent("payload.json")
        for (file, cwd) in [(real.path + "/lib/a.swift", alias.path), (alias.path + "/lib/a.swift", real.path)] {
            let body = #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"\#(file)"}}"#
            try Data(body.utf8).write(to: payload)
            let out = Shell.run(binary, ["advise", "--payload", payload.path, "--project", cwd],
                                in: URL(fileURLWithPath: cwd),
                                environment: ["GENTLEMERGE_HOME": home.path, "GENTLEMERGE_LABEL": "codex",
                                              "CLAUDE_PROJECT_DIR": cwd],
                                timeout: 60)
            XCTAssertTrue(out.stdout.contains("claimed by claude"), "silent for file \(file) in \(cwd): \(out.stdout) \(out.stderr)")
        }
    }
}
