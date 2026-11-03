import Foundation
import XCTest
@testable import GentleMergeCore

/// `who` listed `<ci-monitor-event>…` as an agent's current task.
final class PromptTaskTests: XCTestCase {
    func testAWrappedMessageIsNotATask() {
        XCTAssertTrue(PromptTask.isAutomated(#"<ci-monitor-event>"Auto-fix pull requests" was just enabled"#))
        XCTAssertTrue(PromptTask.isAutomated(#"<cross-session-message from="uds:/tmp/x.sock" from-name="peer">hola</cross-session-message>"#))
        XCTAssertTrue(PromptTask.isAutomated("\n  <system-reminder>\nrecuerda esto\n</system-reminder>"))
        XCTAssertTrue(PromptTask.isAutomated("<side-sessions-event>algo</side-sessions-event>"))
    }

    func testAnUnknownWrapperThatClosesItselfCountsToo() {
        XCTAssertTrue(PromptTask.isAutomated("<future-harness-event a=\"1\">cuerpo</future-harness-event>"))
    }

    func testTextAfterAWrapperIsStillTheirs() {
        let prompt = "<system-reminder>\nuna nota\n</system-reminder>\narregla el login\nsegunda línea"
        XCTAssertFalse(PromptTask.isAutomated(prompt))
        XCTAssertEqual(PromptTask.personalText(prompt), "arregla el login\nsegunda línea")
        XCTAssertEqual(PromptTask.personalText("<ci-monitor-event>\n sin cerrar"), nil, "a truncated envelope is not a task")
        XCTAssertEqual(PromptTask.personalText("\n  hola  "), "hola")
    }

    func testWhatAPersonTypesIsATask() {
        XCTAssertFalse(PromptTask.isAutomated("arregla el generador de misiones"))
        XCTAssertFalse(PromptTask.isAutomated(nil))
        XCTAssertFalse(PromptTask.isAutomated(""))
        // Markup in a person's own sentence: no closing tag at the end, or not a known wrapper.
        XCTAssertFalse(PromptTask.isAutomated("<div> no se centra"))
        XCTAssertFalse(PromptTask.isAutomated("<my-component> está roto"))
        XCTAssertFalse(PromptTask.isAutomated("<system-reminders-list> es una función mía"))
        XCTAssertFalse(PromptTask.isAutomated("1 < 2 y <ci-monitor-event> aparece a mitad de frase"))
    }
}

@MainActor
final class PromptTaskInModelTests: XCTestCase {
    private func envelope(session: String, prompt: String) -> SpoolEnvelope {
        SpoolEnvelope(
            id: UUID().uuidString, provider: .claudeCode, cwd: "/tmp/gameapp", tty: nil, pid: nil,
            payload: .object([
                "session_id": .string(session),
                "hook_event_name": .string("UserPromptSubmit"),
                "prompt": .string(prompt),
            ]))
    }

    func testAnAutomatedPromptKeepsTheTaskTheSessionHad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-task-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try Paths(home: root).createDirectories()
        let model = InboxModel(paths: paths)

        model.ingest(envelope(session: "s1", prompt: "arregla el generador de misiones"))
        model.ingest(envelope(session: "s1", prompt: #"<ci-monitor-event>CI failed</ci-monitor-event>"#))

        let activity = try XCTUnwrap(model.liveActivities.first { $0.id == "s1" })
        XCTAssertEqual(activity.currentTask, "arregla el generador de misiones")
        XCTAssertEqual(activity.state, .working, "the session is still active; only its description is kept")

        model.ingest(envelope(session: "s1", prompt: "ahora revisa los tests"))
        XCTAssertEqual(model.liveActivities.first { $0.id == "s1" }?.currentTask, "ahora revisa los tests")
    }
}
