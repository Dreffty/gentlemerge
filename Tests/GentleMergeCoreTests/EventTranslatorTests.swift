import XCTest
@testable import GentleMergeCore

final class EventTranslatorTests: XCTestCase {
    private func envelope(
        provider: AgentProvider = .claudeCode,
        payload: String,
        cwd: String = "/tmp/Projects/gameapp"
    ) throws -> SpoolEnvelope {
        let json = """
        {"schema":1,"id":"abc","provider":"\(provider.rawValue)",
         "received_at":"2026-08-13T10:00:00Z","cwd":"\(cwd)","tty":"/dev/ttys004",
         "pid":"4242","term_program":"iTerm.app","payload":\(payload)}
        """
        return try JSONCoding.decoder().decode(SpoolEnvelope.self, from: Data(json.utf8))
    }



    func testANotificationIsSomethingToKnowNotSomethingToApprove() throws {
        let question = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"Notification",
         "message":"Claude is waiting for your input"}
        """)
        guard case .item(let questionItem) = EventTranslator.translate(question) else {
            return XCTFail("expected an item")
        }
        XCTAssertEqual(questionItem.kind, .question)
        XCTAssertEqual(questionItem.projectName, "gameapp")
        XCTAssertEqual(questionItem.tty, "/dev/ttys004", "so the app can jump to that tab")
    }

    func testStopBecomesIdleButNotWhenItIsTheHooksOwnLoop() throws {
        let stop = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}
        """)
        guard case .item(let item) = EventTranslator.translate(stop) else {
            return XCTFail("expected an item")
        }
        XCTAssertEqual(item.kind, .idle)

        let looping = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"Stop","stop_hook_active":true}
        """)
        XCTAssertEqual(EventTranslator.translate(looping), .ignore)
    }

    func testTypingInTheTerminalClearsThatSession() throws {
        let prompt = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"keep going"}
        """)
        XCTAssertEqual(
            EventTranslator.translate(prompt),
            .resolveSession(sessionID: "s1", status: .superseded)
        )

        let ended = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"SessionEnd","reason":"clear"}
        """)
        XCTAssertEqual(
            EventTranslator.translate(ended),
            .resolveSession(sessionID: "s1", status: .superseded)
        )
    }

    func testSessionStartRecordsABaselineOnlyWhenTheWorkIsNew() throws {
        let started = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}
        """)
        XCTAssertEqual(
            EventTranslator.translate(started),
            .sessionStarted(
                sessionID: "s1",
                projectPath: "/tmp/Projects/gameapp",
                at: ISO8601DateFormatter.gentleMerge.date(from: "2026-08-13T10:00:00Z")!
            )
        )

        // Compacting keeps working on the same tree; moving the baseline there
        // would lose the point the work actually started from.
        let compacted = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}
        """)
        XCTAssertEqual(EventTranslator.translate(compacted), .ignore)
    }

    func testNoiseIsDropped() throws {
        for event in ["SubagentStop", "PreCompact", "PostToolUse", "PreToolUse"] {
            let envelope = try envelope(payload: """
            {"session_id":"s1","hook_event_name":"\(event)"}
            """)
            XCTAssertEqual(EventTranslator.translate(envelope), .ignore, "\(event) should be ignored")
        }
    }

    func testCodexTurnComplete() throws {
        let envelope = try envelope(
            provider: .codex,
            payload: """
            {"type":"agent-turn-complete","turn-id":"t1",
             "last-assistant-message":"Migrated the schema.\\nTests pass."}
            """
        )
        guard case .item(let item) = EventTranslator.translate(envelope) else {
            return XCTFail("expected an item")
        }
        XCTAssertEqual(item.provider, .codex)
        XCTAssertEqual(item.kind, .idle)
        XCTAssertEqual(item.summary, "Migrated the schema.")
        XCTAssertEqual(item.sessionID, "t1")
    }

}

extension EventTranslatorTests {
    /// A notification carrying a key must reach state, ledger and briefings
    /// with the key taken out — the translator is the single choke point, so
    /// scrubbing here covers all three at once.
    func testTranslatedItemsCarryNoRawSecrets() throws {
        let note = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"Notification",
         "message":"deploy with sk-proj-TEST0000000000000000FAKE now"}
        """)
        guard case .item(let item) = EventTranslator.translate(note) else {
            return XCTFail("expected an item")
        }
        XCTAssertFalse(item.summary.contains("sk-proj-TEST"), item.summary)
        XCTAssertFalse(item.title.contains("sk-proj-TEST"), item.title)
        XCTAssertTrue(item.summary.contains("deploy with"), item.summary)
        XCTAssertFalse(item.payload.displayText.contains("sk-proj-TEST"), item.payload.displayText)
    }

    func testTranslatedItemsRedactValuesUnderSensitiveKeysRecursively() throws {
        let note = try envelope(payload: """
        {"session_id":"s1","hook_event_name":"Notification",
         "message":"safe message",
         "nested":{"password":"FAKEalphabeticpassword"},
         "db_api_key":"FAKEKEY1234567890"}
        """)
        guard case .item(let item) = EventTranslator.translate(note),
              case .object(let payload) = item.payload,
              case .object(let nested) = payload["nested"] else {
            return XCTFail("expected a translated object payload")
        }

        XCTAssertEqual(nested["password"], .string("[redacted]"))
        XCTAssertEqual(payload["db_api_key"], .string("[redacted]"))
        XCTAssertFalse(item.payload.displayText.contains("FAKEalphabeticpassword"), item.payload.displayText)
    }
}
