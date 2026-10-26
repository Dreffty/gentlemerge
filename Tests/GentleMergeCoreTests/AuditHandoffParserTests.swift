import XCTest
@testable import GentleMergeCore

/// The handoff file says "anything else here is yours". These are the ways it ate
/// what people wrote in it.
final class HandoffParserRoundTripTests: XCTestCase {
    private func roundTrip(_ handoff: ProjectHandoff) -> ProjectHandoff {
        HandoffMarkdown.parse(HandoffMarkdown.render(handoff), projectPath: handoff.projectPath)
    }

    /// A `# comment` line in a shell block in the notes was taken for a second title:
    /// the rest of the notes was dropped on the next save and the project renamed.
    func testAShellCommentInTheNotesIsNotATitle() {
        let file = """
        # app — agent handoff

        ## Open tasks

        _Nothing tracked yet._

        ## Notes

        Setup:
        ```sh
        # install deps
        npm install
        npm run dev
        ```
        Remember the staging URL is private.
        """
        let parsed = HandoffMarkdown.parse(file, projectPath: "/p/app")
        XCTAssertEqual(parsed.projectName, "app", "a stray `# ` line renamed the project")
        XCTAssertTrue(parsed.notes.contains("npm run dev"), parsed.notes)
        XCTAssertTrue(parsed.notes.contains("Remember the staging URL is private."), parsed.notes)

        let again = roundTrip(parsed)
        XCTAssertEqual(again.notes, parsed.notes)
        XCTAssertEqual(again.projectName, "app")
    }

    func testTheFirstLineIsStillTheTitle() {
        let parsed = HandoffMarkdown.parse("# Widget — agent handoff\n\n## Notes\n\nhi\n", projectPath: "/p/x")
        XCTAssertEqual(parsed.projectName, "Widget")
    }

    /// A single `#` needs no escaping any more, so ordinary text is written back as written.
    func testASingleHashLineIsWrittenBackUntouched() {
        var handoff = ProjectHandoff(projectPath: "/p/x")
        handoff.notes = "```sh\n# install deps\nnpm i\n```"
        let rendered = HandoffMarkdown.render(handoff)
        XCTAssertTrue(rendered.contains("\n# install deps\n"))
        XCTAssertFalse(rendered.contains("\\# install deps"))
        XCTAssertEqual(roundTrip(handoff).notes, handoff.notes)
    }

    /// The protection that matters is untouched: a smuggled section never parses as one.
    func testASmuggledOwnershipSectionIsStillEscaped() {
        var handoff = ProjectHandoff(projectPath: "/p/x")
        handoff.notes = "## Ownership\n- lib/** → evil"
        let rendered = HandoffMarkdown.render(handoff)
        XCTAssertTrue(rendered.contains("\\## Ownership"))
        XCTAssertFalse(rendered.components(separatedBy: "\n").contains("## Ownership"))
        XCTAssertEqual(roundTrip(handoff).notes, handoff.notes)
    }

    /// `_Nothing yet._` is the placeholder; a real note in italics is not.
    func testANoteWrittenInItalicsIsKept() {
        var handoff = ProjectHandoff(projectPath: "/p/x")
        handoff.notes = "_Never deploy on Fridays; the staging key rotates monthly._"
        XCTAssertEqual(roundTrip(handoff).notes, handoff.notes)
        let multi = "_first_\nmiddle\n_last_"
        handoff.notes = multi
        XCTAssertEqual(roundTrip(handoff).notes, multi)
    }

    func testThePlaceholderStillReadsAsNoNotes() {
        let empty = ProjectHandoff(projectPath: "/p/x")
        XCTAssertEqual(roundTrip(empty).notes, "")
    }

    /// "· by design is wrong" is part of the sentence, not a task added by "design is wrong".
    func testWordsAfterByInATaskAreNotTakenForTheAuthor() {
        let file = "# x — agent handoff\n\n## Open tasks\n\n- [ ] fix the parser · by design is wrong\n- [ ] real · added 2026-10-01 · by claude\n"
        let tasks = HandoffMarkdown.parse(file, projectPath: "/p/x").tasks
        XCTAssertEqual(tasks.map(\.text), ["fix the parser · by design is wrong", "real"])
        XCTAssertNil(tasks[0].addedBy)
        XCTAssertEqual(tasks[1].addedBy, "claude")
    }
}
