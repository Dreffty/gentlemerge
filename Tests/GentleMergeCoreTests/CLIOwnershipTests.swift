import XCTest
@testable import GentleMergeCore

/// `ownership show/pin/add/rm` through the real binary, against a HANDOFF.md
/// an agent could have rewritten.
final class CLIOwnershipTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var project: URL!
    private var binary: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-ownership-\(UUID())")
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".gentlemerge"), withIntermediateDirectories: true)
        binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge").standardizedFileURL.path
        try Data("# p — agent handoff\n\n## Ownership\n\n- assets/** → codex\n".utf8)
            .write(to: project.appendingPathComponent(".gentlemerge/HANDOFF.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ownership(_ args: [String]) -> Shell.Output {
        Shell.run(binary, ["ownership"] + args + ["--project", project.path], in: root,
            environment: ["GENTLEMERGE_HOME": home.path], timeout: 60)
    }

    func testShowNamesTheSource() throws {
        let plain = ownership([])
        XCTAssertEqual(plain.status, 0)
        XCTAssertTrue(plain.stdout.contains("source: handoff"), plain.stdout)
        XCTAssertEqual(ownership(["pin"]).status, 0)
        let pinned = ownership([])
        XCTAssertTrue(pinned.stdout.contains("source: pinned"), pinned.stdout)
        XCTAssertTrue(pinned.stdout.contains("assets/** → codex"), pinned.stdout)
    }

    func testAddAndRmAreWitnessed() throws {
        XCTAssertEqual(ownership(["add", "lib/**", "hermes"]).status, 0)
        XCTAssertTrue(ownership([]).stdout.contains("lib/** → hermes"))
        XCTAssertEqual(ownership(["rm", "lib/**"]).status, 0)
        XCTAssertFalse(ownership([]).stdout.contains("lib/**"))
        let ledger = try String(contentsOf: Paths(home: home).ledger, encoding: .utf8)
        XCTAssertTrue(ledger.contains("ownership.changed"), ledger)
    }
}
