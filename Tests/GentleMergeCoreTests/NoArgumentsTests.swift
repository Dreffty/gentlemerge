import XCTest
@testable import GentleMergeCore

/// `gentlemerge` on its own, typed in a terminal, started the menu-bar app inside that
/// terminal and kept it busy until somebody pressed ⌃C. On Linux it printed the help.
/// It prints the help everywhere now; the app is `gentlemerge app`, or the app itself
/// launched from Finder or `open`.
final class NoArgumentsTests: XCTestCase {
    private var binary: String {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path
    }

    func testNothingTypedPrintsTheHelpAndReturns() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noargs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let output = Shell.run(binary, [], environment: ["GENTLEMERGE_HOME": home.path], timeout: 10)
        XCTAssertFalse(output.timedOut, "it is still running: it started the app")
        XCTAssertEqual(output.status, 0, output.text)
        XCTAssertTrue(output.stdout.contains("USAGE"), output.stdout)
        XCTAssertTrue(output.stdout.contains("gentlemerge app"), "the help should say how to open the app")
    }

    func testTheAppCommandTakesNoOptions() {
        XCTAssertEqual(CommandOptions.allowed(command: "app", arguments: []), [])
    }
}
