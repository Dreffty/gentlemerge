import Foundation

/// What ingesting one envelope should do to the inbox.
public enum IngestOutcome: Sendable, Equatable {
    /// Add (or replace) an item.
    case item(InboxItem)
    /// The human clearly dealt with this session elsewhere — clear its noise.
    /// Blocking items are never cleared this way: something is still parked.
    case resolveSession(sessionID: String, status: InboxStatus)
    /// A session began: the moment to record where the project stood, so its
    /// work can be reviewed against a real baseline later.
    case sessionStarted(sessionID: String, projectPath: String?, at: Date)
    /// Recorded in the ledger, not worth a row.
    case ignore
}

/// Maps agent hook payloads onto inbox items. Pure, so it is the part that
/// gets tested hardest — every agent release can move these keys around.
public enum EventTranslator {
    public static func translate(_ envelope: SpoolEnvelope) -> IngestOutcome {
        switch envelope.provider {
        case .claudeCode: return translateClaudeCode(envelope)
        case .codex: return translateCodex(envelope)
        case .unknown: return translateGeneric(envelope)
        }
    }

    // MARK: - Claude Code

    private static func translateClaudeCode(_ envelope: SpoolEnvelope) -> IngestOutcome {
        let payload = envelope.payload
        let event = envelope.eventName ?? ""

        switch event {
        case "Notification":
            let message = payload.string("message") ?? "Needs your attention"
            return .item(base(
                envelope,
                kind: .question,
                title: "Waiting for your input",
                summary: message
            ))

        case "Stop":
            // `stop_hook_active` means Claude is already looping through a Stop
            // hook's continuation; a second row for that is pure noise.
            if payload["stop_hook_active"]?.boolValue == true { return .ignore }
            return .item(base(
                envelope,
                kind: .idle,
                title: "Finished — your move",
                summary: "The session is idle and waiting for the next instruction."
            ))

        case "SessionEnd":
            guard let sessionID = envelope.sessionID else { return .ignore }
            return .resolveSession(sessionID: sessionID, status: .superseded)

        case "UserPromptSubmit":
            // You are demonstrably at that terminal; anything we were nagging
            // about for this session is stale.
            guard let sessionID = envelope.sessionID else { return .ignore }
            return .resolveSession(sessionID: sessionID, status: .superseded)

        case "SessionStart":
            // `compact` and `clear` keep working on the same tree, so resetting
            // the baseline there would lose the point the work started from.
            let source = payload.string("source") ?? "startup"
            guard source == "startup" || source == "resume", let sessionID = envelope.sessionID else {
                return .ignore
            }
            return .sessionStarted(
                sessionID: sessionID,
                projectPath: envelope.workingDirectory,
                at: envelope.receivedAt
            )

        case "SubagentStop", "PreCompact", "PostToolUse", "PreToolUse":
            return .ignore

        default:
            return translateGeneric(envelope)
        }
    }

    // MARK: - Codex

    private static func translateCodex(_ envelope: SpoolEnvelope) -> IngestOutcome {
        let payload = envelope.payload
        let type = envelope.eventName ?? ""

        if type.contains("approval") || type.contains("permission") {
            let command = payload.string("command")
                ?? payload["command"]?.arrayValue?.map(\.displayText).joined(separator: " ")
                ?? ""
            return .item(base(
                envelope,
                kind: .question,
                title: payload.string("reason")?.nonEmpty ?? "Waiting on an approval in its own terminal",
                summary: command.firstLine.truncated(to: 140),
                detail: command.nonEmpty
            ))
        }

        if type.contains("turn-complete") || type.contains("turn-ended") {
            let message = payload.string("last-assistant-message")
                ?? payload.string("last_assistant_message")
                ?? ""
            return .item(base(
                envelope,
                kind: .idle,
                title: "Finished — your move",
                summary: message.firstLine.truncated(to: 160).nonEmpty
                    ?? "The turn ended and the session is waiting.",
                detail: message.truncated(to: 1200).nonEmpty
            ))
        }

        return translateGeneric(envelope)
    }

    // MARK: - Unknown providers

    private static func translateGeneric(_ envelope: SpoolEnvelope) -> IngestOutcome {
        let payload = envelope.payload
        let message = payload.string("message")
            ?? payload.string("summary")
            ?? payload.string("last-assistant-message")

        guard let message else { return .ignore }

        return .item(base(
            envelope,
            kind: .info,
            title: envelope.eventName?.nonEmpty ?? "Agent event",
            summary: message,
            detail: ToolInputFormatter.prettyJSON(payload)
        ))
    }

    // MARK: - Shared

    private static func base(
        _ envelope: SpoolEnvelope,
        kind: InboxKind,
        title: String,
        summary: String,
        detail: String? = nil,
        toolName: String? = nil,
        paths: [String] = []
    ) -> InboxItem {
        // Every translated item passes through here on its way to state, the
        // ledger and the briefings. Scrub here and all three are clean; scrub
        // anywhere later and one of them keeps the raw text. (The hook payload
        // itself stays raw in the spool — owner-only files, pruned in days —
        // because advise and the translators still need to read it.)
        InboxItem(
            id: envelope.id,
            sessionID: envelope.sessionID,
            provider: envelope.provider,
            kind: kind,
            status: .pending,
            eventName: envelope.eventName,
            title: Redactor.scrub(title).text,
            summary: Redactor.scrub(summary).text,
            detail: detail.map { Redactor.scrub($0).text },
            toolName: toolName,
            projectPath: envelope.workingDirectory,
            tty: envelope.tty,
            terminalProgram: envelope.terminalProgram,
            pid: envelope.pid,
            transcriptPath: envelope.payload.string("transcript_path"),
            createdAt: envelope.receivedAt,
            updatedAt: envelope.receivedAt,
            payload: envelope.payload,
            touchedPaths: paths.isEmpty ? nil : paths,
            scope: PathExtractor.scope(of: paths, project: envelope.workingDirectory)
        )
    }
}
