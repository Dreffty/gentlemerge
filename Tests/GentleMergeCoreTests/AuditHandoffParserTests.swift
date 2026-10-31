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

/// Text a person puts outside the generated sections, and code blocks inside
/// them: both were rewritten or dropped on the next save.
final class HandoffPreambleAndFenceTests: XCTestCase {
    private func parse(_ text: String) -> ProjectHandoff {
        HandoffMarkdown.parse(text, projectPath: "/tmp/proj")
    }

    private func roundTrip(_ text: String) -> String {
        HandoffMarkdown.render(parse(text))
    }

    func testTextUnderTheTitleSurvivesASave() {
        let text = "# Proj\n\nWhy this project exists: read docs/WHY.md first.\nSecond line.\n\n## Notes\n\n- a note\n"
        let handoff = parse(text)
        XCTAssertEqual(handoff.preamble, "Why this project exists: read docs/WHY.md first.\nSecond line.")
        let saved = HandoffMarkdown.render(handoff)
        XCTAssertTrue(saved.contains("Why this project exists: read docs/WHY.md first.\nSecond line."), saved)
        XCTAssertEqual(roundTrip(saved), saved, "saving twice must change nothing")
    }

    func testTheGeneratedIntroductionIsNotKeptAsThePreamble() {
        let once = HandoffMarkdown.render(ProjectHandoff(projectPath: "/tmp/proj"))
        XCTAssertEqual(parse(once).preamble, "")
        XCTAssertEqual(roundTrip(once), once)
        XCTAssertTrue(once.contains(HandoffMarkdown.introductionPrefix), "the prefix the parser strips must be the one render writes")
    }

    func testACheckboxWrittenUnderTheTitleBecomesATask() {
        let handoff = parse("# Proj\n\n- [ ] top-level task\n\n## Notes\n\n_Nothing yet._\n")
        XCTAssertEqual(handoff.tasks.map(\.text), ["top-level task"])
        XCTAssertEqual(handoff.preamble, "")
    }

    func testASecondH1BeforeTheFirstSectionIsTextNotAnotherTitle() {
        let handoff = parse("# Real name\n\n# A heading the human pasted\nbody\n\n## Notes\n\n_Nothing yet._\n")
        XCTAssertEqual(handoff.projectName, "Real name")
        XCTAssertTrue(handoff.preamble.contains("# A heading the human pasted"))
    }

    func testACodeBlockInNotesIsLeftAlone() {
        let notes = "To reset:\n```bash\n## Setup\n- [ ] not a task\nrm -rf build\n```\nafter"
        let text = "# P\n\n## Notes\n\n\(notes)\n"
        let handoff = parse(text)
        XCTAssertEqual(handoff.notes, notes)
        XCTAssertTrue(handoff.tasks.isEmpty, "a checkbox in a code block is an example")
        XCTAssertTrue(handoff.extraSections.isEmpty, "a `##` in a code block is not a section")
        let saved = HandoffMarkdown.render(handoff)
        XCTAssertTrue(saved.contains(notes), "the snippet must come back byte for byte:\n\(saved)")
        XCTAssertFalse(saved.contains("\\## Setup"))
        XCTAssertEqual(roundTrip(saved), saved)
    }

    func testAFenceThatNeverClosesCannotSwallowTheSectionsAfterIt() {
        // One stray fence in the notes, then a real zone declaration.
        let text = "# P\n\n## Notes\n\nlook:\n```\nno closing fence\n\n## Ownership\n\n- lib/** → claude\n"
        let handoff = parse(text)
        XCTAssertEqual(handoff.extraSections.map(\.heading), ["Ownership"],
                       "an unclosed fence hid the next section")
        XCTAssertEqual(Ownership.from(handoff: handoff).rules.count, 1)
    }

    func testADanglingFenceInNotesIsClosedWhenSaved() {
        var handoff = ProjectHandoff(projectPath: "/tmp/proj")
        handoff.notes = "see:\n```\nsome code"
        handoff.extraSections = [("Ownership", "- lib/** → claude"), ("Other", "```\nx\n```")]
        let reread = parse(HandoffMarkdown.render(handoff))
        XCTAssertEqual(reread.extraSections.map(\.heading), ["Ownership", "Other"],
                       "the notes' open fence paired with the next section's")
    }

    func testAFencedZoneExampleIsNotAZoneGrant() {
        let text = "# P\n\n## Notes\n\nExample:\n```\n## Ownership\n- ** → mallory\n```\n"
        XCTAssertTrue(Ownership.from(handoff: parse(text)).rules.isEmpty)
    }
}
