import XCTest
@testable import GentleMergeCore

/// An attachment is the one thing on the bus that is a file rather than a
/// sentence, which makes it the one thing that could put a secret on disk, put
/// a gigabyte in `~`, or leave a path pointing at nothing. These are those.
final class ArtifactTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var paths: Paths!
    private var store: ArtifactStore!
    private var bus: AgentBus!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-artifacts-\(UUID().uuidString)")
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        paths = Paths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.createDirectories()
        store = ArtifactStore(paths: paths)
        bus = AgentBus(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ contents: String, to name: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func storedText(_ attachment: Attachment) throws -> String {
        try String(contentsOf: store.url(for: attachment), encoding: .utf8)
    }

    private func artifactDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.artifacts.path).sorted()
    }

    // MARK: - Text goes in scrubbed

    func testTheStoredCopyOfATextFileHasLostItsSecrets() throws {
        let url = try write(
            """
            # Deploy notes
            Set ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnop1234 before running.
            Everything else is in the Makefile, and the port is 8080.
            """,
            to: "report.md"
        )

        let attachment = try store.store(contentsOf: url)
        let onDisk = try storedText(attachment)

        XCTAssertFalse(onDisk.contains("sk-ant-api03-abcdefghijklmnop1234"))
        XCTAssertTrue(onDisk.contains("ANTHROPIC_API_KEY"), "the name stays so the sentence still reads")
        XCTAssertTrue(onDisk.contains("[redacted"), onDisk)
        // The rest of the file is still the file: a scrub that ate the useful
        // half would be a filter people route around.
        XCTAssertTrue(onDisk.contains("port is 8080"))
        // And the original is left exactly as its author wrote it.
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("sk-ant-api03-abcdefghijklmnop1234"))
    }

    func testTheSummaryIsTheScrubbedHeadAndNotTheWholeFile() throws {
        let body = (1...50).map { "line \($0) of the report" }.joined(separator: "\n")
        let url = try write("password: hunter2000\n" + body, to: "long.md")

        let attachment = try store.store(contentsOf: url)
        let summary = try XCTUnwrap(attachment.summary)

        XCTAssertFalse(summary.contains("hunter2000"))
        XCTAssertEqual(summary.split(separator: "\n").count, ArtifactStore.summaryLines)
        XCTAssertFalse(summary.contains("line 40 of the report"))
    }

    func testAFileThatIsAlmostEntirelySecretIsRefused() throws {
        let url = try write("sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345\n", to: "key.txt")

        XCTAssertThrowsError(try store.store(contentsOf: url)) { error in
            guard case ArtifactStore.Failure.suppressed = error else {
                return XCTFail("expected a suppressed attachment, got \(error)")
            }
        }
        // Nothing was written on the way to saying no.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.artifacts.path))
    }

    func testAnEmptyFileIsRefusedRatherThanStored() throws {
        let url = try write("   \n\n", to: "blank.md")

        XCTAssertThrowsError(try store.store(contentsOf: url)) { error in
            guard case ArtifactStore.Failure.empty = error else {
                return XCTFail("expected an empty attachment, got \(error)")
            }
        }
    }

    // MARK: - The cap

    func testAFileOverTheCapIsRefused() throws {
        let url = source.appendingPathComponent("huge.log")
        try Data(repeating: UInt8(ascii: "x"), count: ArtifactStore.byteLimit + 1).write(to: url)

        XCTAssertThrowsError(try store.store(contentsOf: url)) { error in
            guard case ArtifactStore.Failure.tooLarge = error else {
                return XCTFail("expected a size complaint, got \(error)")
            }
        }
    }

    func testAMissingFileIsRefused() throws {
        XCTAssertThrowsError(try store.store(contentsOf: source.appendingPathComponent("nope.md")))
    }

    // MARK: - Binary

    func testABinaryFileIsCopiedByteForByteAndSaysSoOutLoud() throws {
        let url = source.appendingPathComponent("screenshot.png")
        // Invalid UTF-8 on purpose: this is what "binary" means here.
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0xfe, 0x00, 0x01])
        try bytes.write(to: url)

        let attachment = try store.store(contentsOf: url)
        let stored = try Data(contentsOf: store.url(for: attachment))

        XCTAssertEqual(stored, bytes)
        XCTAssertEqual(ArtifactStore.digest(stored), ArtifactStore.digest(bytes))
        XCTAssertEqual(attachment.sha256, ArtifactStore.digest(bytes))
        XCTAssertNil(attachment.summary)
        XCTAssertTrue(attachment.isBinary)
        XCTAssertTrue(attachment.line(at: "/wherever").contains("binary — not scrubbed"))
    }

    // MARK: - Dedupe

    func testTheSameContentUnderTwoNamesIsStoredOnce() throws {
        let text = "the same report, twice\nsecond line\n"
        let first = try store.store(contentsOf: try write(text, to: "report.md"))
        let second = try store.store(contentsOf: try write(text, to: "informe.md"))

        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(try artifactDirectories().count, 1)
        // Same directory, each under the name its sender used.
        XCTAssertNotEqual(first.storedPath, second.storedPath)
        XCTAssertEqual(try storedText(first), try storedText(second))
    }

    func testTwoFilesThatScrubToTheSameTextShareADirectory() throws {
        let first = try store.store(contentsOf: try write("token: aaaaaaaaaaaa\nthe rest of the note\n", to: "a.md"))
        let second = try store.store(contentsOf: try write("token: bbbbbbbbbbbb\nthe rest of the note\n", to: "b.md"))

        // Dedupe is over what is stored, which is what anybody will ever read.
        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(try artifactDirectories().count, 1)
    }

    // MARK: - Naming

    func testAnAttachmentNameCannotClimbOutOfTheStore() throws {
        let escape = try write("nothing to see\nsecond line\n", to: "id_rsa")
        let attachment = try store.store(contentsOf: escape)

        XCTAssertEqual(attachment.name, "id_rsa")
        XCTAssertNil(ArtifactStore.safeName(".."))
        XCTAssertEqual(ArtifactStore.safeName("../../.ssh/id_rsa"), "id_rsa")
        XCTAssertTrue(store.url(for: attachment).path.hasPrefix(paths.artifacts.path))
    }

    func testTheDirectoryNameAlwaysSurvivesTheRedactor() {
        // An all-digit path component reads as an account number on its way out
        // of a briefing, and the path is the part that has to arrive intact.
        let allDigits = "012345678901" + String(repeating: "a", count: 52)
        XCTAssertTrue(ArtifactStore.key(for: allDigits).contains(where: \.isLetter))
        XCTAssertEqual(ArtifactStore.key(for: String(repeating: "1", count: 64)).count, 12)
    }

    // MARK: - What the receiver is told

    func testTheBriefingHandsOverThePathAndTheHeadButNeverTheFile() throws {
        let body = (1...40).map { "step \($0): do the thing" }.joined(separator: "\n")
        let attachment = try store.store(contentsOf: try write(body, to: "plan.md"))
        bus.post(AgentMessage(from: "codex", to: "claude", text: "el informe está listo", attachments: [attachment]))

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "s1", me: "claude", project: nil))

        XCTAssertTrue(briefing.contains("→ attachment:"))
        XCTAssertTrue(briefing.contains(attachment.storedPath))
        XCTAssertTrue(briefing.contains("step 1: do the thing"))
        XCTAssertFalse(briefing.contains("step 40: do the thing"))
    }

    func testAMessageWithAnAttachmentSurvivesARoundTripThroughTheLog() throws {
        let attachment = try store.store(contentsOf: try write("a\nreport\n", to: "r.md"))
        bus.post(AgentMessage(from: "codex", text: "informe", attachments: [attachment]))

        let stored = try XCTUnwrap(bus.messages().last)
        XCTAssertEqual(stored.attachments, [attachment])
    }

    func testAnOlderBinaryReadsTheNoteAndIgnoresTheKey() throws {
        // The line an install that predates attachments would find in the log:
        // no `attachments` key at all, and it must still decode.
        let line = #"{"id":"1","at":"2026-08-21T10:00:00Z","from":"codex","text":"sin adjuntos"}"#
        let message = try JSONCoding.decoder().decode(AgentMessage.self, from: Data(line.utf8))

        XCTAssertNil(message.attachments)
        XCTAssertEqual(message.text, "sin adjuntos")
    }

    // MARK: - Collection

    func testThePruneCollectsAnOrphanAndKeepsWhatAMessageStillPointsAt() throws {
        let kept = try store.store(contentsOf: try write("the live report\nsecond line\n", to: "live.md"))
        let orphan = try store.store(contentsOf: try write("nobody's report\nsecond line\n", to: "orphan.md"))
        bus.post(AgentMessage(from: "codex", text: "todavía útil", attachments: [kept]))

        // Both are minutes old to the file system; the prune only ever looks at
        // artifacts that have outlived the gap between storing and posting.
        try age(paths.artifacts, byHours: 2)

        bus.pruneMessages(now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: orphan).path))
    }

    func testAnArtifactIsSafeUntilItsMessageHasHadTimeToLand() throws {
        let fresh = try store.store(contentsOf: try write("just written\nsecond line\n", to: "fresh.md"))

        bus.pruneMessages(now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: fresh).path))
    }

    func testCollectingLeavesEverythingAloneWhenNothingIsOrphaned() throws {
        let attachment = try store.store(contentsOf: try write("still here\nsecond line\n", to: "here.md"))
        try age(paths.artifacts, byHours: 2)

        let collected = store.collect(keeping: ArtifactStore.keys(referencedBy: [
            AgentMessage(from: "codex", text: "note", attachments: [attachment]),
        ]))

        XCTAssertEqual(collected, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: attachment).path))
    }

    /// Push every artifact directory into the past, so the grace period is not
    /// the thing under test.
    private func age(_ directory: URL, byHours hours: Int) throws {
        let then = Date().addingTimeInterval(-Double(hours) * 3600)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: then],
                ofItemAtPath: directory.appendingPathComponent(name).path
            )
        }
    }
}
