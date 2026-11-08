import XCTest
@testable import GentleMergeCore

/// What the documentation promises in numbers. A figure nobody re-checks drifts away
/// from the thing it describes, and these are the ones people decide on.
final class DocumentedFiguresTests: XCTestCase {
    private var readme: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        }
    }

    /// Measured on a month of real use: 466 briefings, 47,436 tokens, 101 a turn. The
    /// README said ~20–70, a guess from before anybody had counted.
    func testTheCostPerTurnIsTheOneThatWasMeasured() throws {
        let text = try readme
        XCTAssertFalse(text.contains("20–70"))
        XCTAssertTrue(text.contains("~100/turn"), "say what `gentlemerge stats` says")
    }

    /// The product changed name and purpose; the first screen of help had not. It
    /// still opened as the approval inbox it used to be.
    func testHelpSpeaksOfTheProductAsItIsNow() throws {
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"] ?? ".build/debug/gentlemerge")
            .standardizedFileURL.path
        let help = Shell.run(binary, ["help"]).stdout
        XCTAssertFalse(help.contains("every agent that needs you"), help)
        XCTAssertFalse(help.contains("what you authorized"), help)
        XCTAssertTrue(help.hasPrefix("gentlemerge — coordination for AI coding agents that share one repository"), help)
    }
}
