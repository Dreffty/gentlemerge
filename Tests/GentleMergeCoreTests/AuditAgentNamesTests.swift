import XCTest
@testable import GentleMergeCore

/// `who` and every briefing listed Hermes, Gemini and OpenCode alike as "Agent · repo".
final class AgentNameInListsTests: XCTestCase {
    func testAnAgentWithoutAKnownProviderIsListedUnderItsLabel() {
        let activity = AgentActivity(id: "a", provider: .unknown, projectPath: "/p/repo", label: "hermes")
        XCTAssertEqual(activity.displayName, "hermes")
        XCTAssertTrue(activity.briefingLine().hasPrefix("- hermes · repo"), activity.briefingLine())
    }

    func testAKnownProviderKeepsItsNameAndAddsADifferentLabel() {
        XCTAssertEqual(AgentActivity(id: "a", provider: .claudeCode, projectPath: "/p", label: "claude#exec1").displayName,
                       "Claude Code (claude#exec1)")
        XCTAssertEqual(AgentActivity(id: "a", provider: .claudeCode, projectPath: "/p", label: "claude").displayName,
                       "Claude Code", "the default label adds nothing")
        XCTAssertEqual(AgentActivity(id: "a", provider: .codex, projectPath: "/p").displayName, "Codex")
    }

    func testPresenceMarksCarryTheirLabelIntoTheList() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID())")
        let paths = try Paths(home: home).createDirectories()
        defer { try? FileManager.default.removeItem(at: home) }
        Presence.record(label: "hermes", project: "/p/repo", branch: "agent/hermes", pid: nil, paths: paths, environment: [:])
        Presence.record(label: "gemini", project: "/p/repo", branch: "agent/gemini", pid: nil, paths: paths, environment: [:])
        let names = Set(Presence.live(paths: paths).map(\.displayName))
        XCTAssertEqual(names, ["hermes", "gemini"])
    }

    func testAnOldActivityWithoutALabelStillDecodes() throws {
        let json = #"{"id":"x","provider":"codex","startedAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z","state":"working"}"#
        let activity = try JSONCoding.decoder().decode(AgentActivity.self, from: Data(json.utf8))
        XCTAssertNil(activity.label)
        XCTAssertEqual(activity.displayName, "Codex")
    }
}

/// `project init --label 日本語` said "label `agent` set": two agents named in
/// non-ASCII would both become `agent`, and neither was told.
final class LabelCleaningNoteTests: XCTestCase {
    func testAnUnchangedLabelAddsNothing() {
        XCTAssertEqual(WorktreeLabel.cleaningNote(asked: "claude#2", stored: "claude#2"), "")
    }

    func testACleanedLabelSaysWhatItWasCleanedFrom() {
        let note = WorktreeLabel.cleaningNote(asked: "ñandú pro", stored: Identity.safe("ñandú pro"))
        XCTAssertTrue(note.contains("cleaned from `ñandú pro`"), note)
    }

    func testALabelWithNothingUsableSaysItFellBack() {
        let note = WorktreeLabel.cleaningNote(asked: "日本語", stored: Identity.safe("日本語"))
        XCTAssertTrue(note.contains("generic `agent`"), note)
    }
}
