import XCTest
@testable import GentleMergeCore

/// Three gaps the worktree episode exposed, once the notes were finally
/// reaching everybody: no name a person and an agent could both use for a note,
/// no way to correct one, and no way to address one at a branch.
final class MessageHandleTests: XCTestCase {
    private var root: URL!
    private var bus: AgentBus!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gentlemerge-handle-\(UUID().uuidString)")
        let paths = Paths(home: root)
        try paths.createDirectories()
        bus = AgentBus(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - A name you can say out loud

    func testTheHandleIsFourCharactersAndSurvivesAReload() {
        let message = AgentMessage(id: "579DEA35-72AA-4A80-ABE2-F6CA1F757D82", from: "claude", text: "x")
        XCTAssertEqual(message.handle.count, 4)
        // Derived, not counted: the same id names the same note tomorrow, after
        // everything around it has expired.
        XCTAssertEqual(message.handle, AgentMessage.handle(for: message.id))
    }

    func testDifferentNotesGetDifferentHandles() {
        let handles = Set((0..<400).map { AgentMessage.handle(for: "id-\($0)-\(UUID().uuidString)") })
        // Four hex characters is 65536 slots; 400 draws should collide rarely
        // enough that a briefing's worth of notes stays unambiguous.
        XCTAssertGreaterThan(handles.count, 390)
    }

    func testANoteAnswersToItsHandleAndToItsID() {
        let message = AgentMessage(id: "579DEA35-72AA-4A80-ABE2-F6CA1F757D82", from: "claude", text: "x")
        XCTAssertTrue(message.answersTo(message.handle))
        XCTAssertTrue(message.answersTo("#" + message.handle.uppercased()))
        XCTAssertTrue(message.answersTo(message.id))
        XCTAssertTrue(message.answersTo("579dea"))
        XCTAssertFalse(message.answersTo("579"), "too short to mean anything")
        XCTAssertFalse(message.answersTo(""))
    }

    func testLookingUpANoteFindsItByHandle() throws {
        bus.post(AgentMessage(from: "claude", text: "el merge da 2 marcas de conflicto"))
        let posted = try XCTUnwrap(bus.messages(limit: 10).first)

        let found = bus.messages(matching: posted.handle)
        XCTAssertEqual(found.map(\.id), [posted.id])
    }

    /// Asking for a note by name is usually the prelude to acting on it, so a
    /// note that has been corrected or has expired still has to be findable —
    /// "that one no longer stands" is an answer you can only give if you found it.
    func testACorrectedNoteCanStillBeLookedUp() throws {
        bus.post(AgentMessage(from: "claude", text: "el merge da 2 marcas"))
        let original = try XCTUnwrap(bus.messages(limit: 10).first)
        bus.post(AgentMessage(from: "claude", text: "da 1", replacesID: original.id))

        XCTAssertEqual(bus.messages(matching: original.handle).map(\.id), [original.id])
        XCTAssertFalse(bus.isStanding(original))
    }

    // MARK: - Correcting instead of piling up

    func testACorrectionFoldsOutWhatItCorrects() throws {
        bus.post(AgentMessage(from: "claude", text: "porta limpio"))
        let wrong = try XCTUnwrap(bus.messages(limit: 10).first)
        bus.post(AgentMessage(from: "claude", text: "NO porta limpio: 1 conflicto", replacesID: wrong.id))

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "s1", me: "codex", project: nil))
        XCTAssertTrue(briefing.contains("NO porta limpio"))
        XCTAssertFalse(
            briefing.contains("- #\(wrong.handle)"),
            "the note that was corrected must not still be standing next to its correction"
        )
    }

    func testACorrectionSaysThatItIsOne() throws {
        bus.post(AgentMessage(from: "claude", text: "primera version"))
        let first = try XCTUnwrap(bus.messages(limit: 10).first)
        bus.post(AgentMessage(from: "claude", text: "segunda version", replacesID: first.id))

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "s1", me: "codex", project: nil))
        XCTAssertTrue(briefing.contains("corrects an earlier note"))
    }

    /// Being wrong is not a private matter on a shared bus: the number that
    /// needed correcting in the episode this comes from was somebody else's.
    func testYouCanCorrectSomebodyElsesNote() throws {
        bus.post(AgentMessage(from: "codex", text: "2 marcas de conflicto"))
        let theirs = try XCTUnwrap(bus.messages(limit: 10).first)
        bus.post(AgentMessage(from: "claude", text: "1 marca, medido", replacesID: theirs.id))

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "s1", me: "hermes", project: nil))
        XCTAssertTrue(briefing.contains("1 marca, medido"))
        XCTAssertFalse(briefing.contains("2 marcas de conflicto"))
    }

    // MARK: - Addressing a branch

    func testANoteForABranchReachesThatBranch() throws {
        bus.post(AgentMessage(from: "codex", text: "he movido el fichero bajo ti", toBranch: "feature/tipos-habito"))

        let onIt = try XCTUnwrap(
            bus.briefing(sessionID: "s1", me: "claude", project: nil, branch: "feature/tipos-habito")
        )
        XCTAssertTrue(onIt.contains("he movido el fichero"))
        XCTAssertTrue(onIt.contains("for branch feature/tipos-habito"))
    }

    func testANoteForABranchIsNotShownOnAnother() throws {
        bus.post(AgentMessage(from: "codex", text: "solo para tipos-habito", toBranch: "feature/tipos-habito"))
        XCTAssertNil(bus.briefing(sessionID: "s1", me: "claude", project: nil, branch: "main"))
    }

    /// A detached HEAD cannot name a branch. Swallowing the note there would
    /// hide a collision warning from the one reader who might be causing it.
    func testAReaderWithNoBranchIsToldAnyway() throws {
        bus.post(AgentMessage(from: "codex", text: "aviso de rama", toBranch: "feature/x"))
        let anyway = try XCTUnwrap(bus.briefing(sessionID: "s1", me: "claude", project: nil, branch: nil))
        XCTAssertTrue(anyway.contains("aviso de rama"))
    }

    func testAnUnaddressedNoteStillReachesEveryBranch() throws {
        bus.post(AgentMessage(from: "codex", text: "para todos"))
        let onMain = try XCTUnwrap(bus.briefing(sessionID: "s1", me: "claude", project: nil, branch: "main"))
        XCTAssertTrue(onMain.contains("para todos"))
    }

    // MARK: - What the reader is told

    func testTheBriefingPrintsTheHandleAndHowToUseIt() throws {
        bus.post(AgentMessage(from: "codex", text: "algo"))
        let posted = try XCTUnwrap(bus.messages(limit: 10).first)

        let briefing = try XCTUnwrap(bus.briefing(sessionID: "s1", me: "claude", project: nil))
        XCTAssertTrue(briefing.contains("#\(posted.handle)"))
        XCTAssertTrue(briefing.contains("gentlemerge show"))
    }
}
