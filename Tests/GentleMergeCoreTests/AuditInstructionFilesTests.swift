import XCTest
@testable import GentleMergeCore

/// `project init` rewrote the project's CLAUDE.md / AGENTS.md. Those are a
/// person's instructions: it replaced a Latin-1 or UTF-16 one with the pointer
/// alone, turned a symlink into a copy and ignored a read-only flag.
final class InstructionFileSafetyTests: XCTestCase {
    private var root: URL!
    private var manager: FileManager { .default }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-instr-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("CLAUDE.md").path)
        try? manager.removeItem(at: root)
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func initialize() throws -> [ProjectRegistry.SkippedInstructionFile] {
        try ProjectRegistry.initializeReportingSkips(projectPath: root.path).skipped
    }

    func testAFileThatIsNotUTF8IsLeftExactlyAsItWas() throws {
        let latin1 = Data([0x52, 0x65, 0x67, 0x6C, 0x61, 0x73, 0x20, 0x61, 0xF1, 0x6F, 0x0A])   // "Reglas año\n"
        let utf16 = try XCTUnwrap("Instrucciones ñ\n".data(using: .utf16))
        try latin1.write(to: url("CLAUDE.md"))
        try utf16.write(to: url("AGENTS.md"))

        let skipped = try initialize()

        XCTAssertEqual(try Data(contentsOf: url("CLAUDE.md")), latin1, "CLAUDE.md was overwritten")
        XCTAssertEqual(try Data(contentsOf: url("AGENTS.md")), utf16, "AGENTS.md was overwritten")
        XCTAssertEqual(Set(skipped.map(\.name)), ["CLAUDE.md", "AGENTS.md"])
        XCTAssertTrue(skipped.allSatisfy { $0.reason.contains("UTF-8") }, "\(skipped)")
    }

    func testAUTF8FileGetsThePointerOnceAndKeepsItsContent() throws {
        try Data("Reglas: no tocar ñandú.\n".utf8).write(to: url("CLAUDE.md"))

        XCTAssertEqual(try initialize(), [])
        let once = try String(contentsOf: url("CLAUDE.md"), encoding: .utf8)
        XCTAssertTrue(once.hasPrefix("Reglas: no tocar ñandú.\n"))
        XCTAssertEqual(once.components(separatedBy: ProjectRegistry.pointerMarker).count - 1, 1)

        XCTAssertEqual(try initialize(), [])
        XCTAssertEqual(try String(contentsOf: url("CLAUDE.md"), encoding: .utf8), once, "running it twice changed the file")
    }

    func testASymlinkedInstructionFileStaysALink() throws {
        try Data("shared rules\n".utf8).write(to: url("AGENTS.md"))
        try manager.createSymbolicLink(atPath: url("CLAUDE.md").path, withDestinationPath: "AGENTS.md")

        XCTAssertEqual(try initialize(), [])

        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: url("CLAUDE.md").path), "AGENTS.md")
        let shared = try String(contentsOf: url("AGENTS.md"), encoding: .utf8)
        XCTAssertEqual(shared.components(separatedBy: ProjectRegistry.pointerMarker).count - 1, 1,
                       "the link and its target are one file: the pointer goes in once")
    }

    func testAReadOnlyFileIsSkippedWithAReadableReasonAndTheHandoffStillExists() throws {
        try Data("mine\n".utf8).write(to: url("CLAUDE.md"))
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url("CLAUDE.md").path)

        let skipped = try initialize()

        XCTAssertEqual(try String(contentsOf: url("CLAUDE.md"), encoding: .utf8), "mine\n")
        XCTAssertEqual(skipped.map(\.name), ["CLAUDE.md"])
        XCTAssertTrue(skipped[0].reason.contains("Permission denied"), skipped[0].reason)
        XCTAssertTrue(manager.fileExists(atPath: ProjectHandoff.fileURL(for: root.path).path))
    }
}
