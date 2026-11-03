import Foundation

/// Which prompts say what a session is working on.
///
/// `UserPromptSubmit` also fires for text no person typed: the harness wraps a
/// message from another session, a CI event or a reminder in a tag and submits
/// it as a prompt. Taking its first line as "the task" made `who` and every
/// briefing read `<ci-monitor-event>"Auto-fix pull requests" was just enabled…`
/// as what an agent was busy with.
public enum PromptTask {
    /// Wrappers the harness is known to submit as prompts.
    private static let knownEnvelopes: [String] = [
        "cross-session-message", "ci-monitor-event", "side-sessions-event",
        "system-reminder", "task-notification", "teammate-message",
        "command-name", "command-message", "local-command-stdout",
    ]

    /// True when the prompt has text but none of it was written by a person. Such
    /// a prompt leaves the session's task as it was.
    public static func isAutomated(_ prompt: String?) -> Bool {
        guard let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return false
        }
        return personalText(text) == nil
    }

    /// What a person wrote in the prompt: the text with any harness wrappers
    /// taken off the front. Nil when nothing is left.
    public static func personalText(_ prompt: String?) -> String? {
        var text = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while text.first == "<" {
            guard let name = tagName(of: text) else { break }

            if knownEnvelopes.contains(name) {
                // A known wrapper with no closing tag is a truncated envelope:
                // nothing after it can be told apart from its body.
                guard let close = text.range(of: "</\(name)>") else { return nil }
                text = text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            // An unknown wrapper counts only when it is the whole prompt, so a
            // person's `<my-component> is broken` stays theirs.
            if (name.contains("-") || name.contains("_")) && text.hasSuffix("</\(name)>") { return nil }
            break
        }
        return text.isEmpty ? nil : text
    }

    /// The whole name in `<name>` or `<name …`, hyphens included, so the caller
    /// compares `system-reminders-list` against `system-reminder` as different
    /// names. Nil when what follows is not a tag.
    private static func tagName(of text: String) -> String? {
        let name = text.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard name.first?.isLowercase == true else { return nil }
        guard let next = text.dropFirst(1 + name.count).first else { return String(name) }
        return next == ">" || next == "/" || next.isWhitespace ? String(name) : nil
    }
}
