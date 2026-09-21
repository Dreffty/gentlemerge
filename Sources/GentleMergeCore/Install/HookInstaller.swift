import Foundation

/// Installs the bridge into the agents' own config files. Everything here is
/// idempotent, backed up before it is touched, and reversible with `uninstall`.
public struct HookInstaller: Sendable {
    /// Every entry we write carries this in its command, so we can find and
    /// remove exactly our own hooks and leave the rest of the file alone.
    public static let marker = "gentlemerge-hook.sh"

    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    public struct Plan: Sendable {
        /// Events that only report what happened.
        public var notifyEvents: [String]
        /// Events that also hand the session what the other agents are doing.
        /// These are the two moments a session can still act on it.
        public var contextEvents: [String]

        public init(
            notifyEvents: [String] = ["Notification", "Stop", "SessionEnd"],
            contextEvents: [String] = ["SessionStart", "UserPromptSubmit"]
        ) {
            self.notifyEvents = notifyEvents
            self.contextEvents = contextEvents
        }
    }

    public struct Result: Sendable {
        public var changed: Bool
        public var backup: URL?
        public var notes: [String]
    }

    // MARK: - Scripts

    /// Materialise the hook script. The app is the source of truth, so an app
    /// upgrade refreshes the script the next time you install.
    @discardableResult
    public func writeScripts() throws -> URL {
        try paths.createDirectories()
        try AtomicFile.write(Data(HookScript.source.utf8), to: paths.hookScript)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: paths.hookScript.path
        )
        linkExecutable()
        return paths.hookScript
    }

    /// The hook script needs a stable path to the binary to ask for a session's
    /// handoff; a symlink survives the app moving or being rebuilt.
    private func linkExecutable() {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }
        let link = paths.bin.appendingPathComponent("gentlemerge")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    }

    // MARK: - Claude Code

    public func installClaudeCode(plan: Plan, dryRun: Bool = false) throws -> Result {
        var notes: [String] = []
        if !dryRun { try writeScripts() }

        var settings = try readJSONObject(at: paths.claudeSettings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in plan.notifyEvents {
            hooks[event] = merged(
                into: hooks[event],
                entry: hookEntry(
                    command: "\(quoted(paths.hookScript.path)) --provider claude-code --mode notify",
                    timeout: 10,
                    matcher: nil
                )
            )
            notes.append("\(event) → reports it")
        }

        for event in plan.contextEvents {
            hooks[event] = merged(
                into: hooks[event],
                entry: hookEntry(
                    command: "\(quoted(paths.hookScript.path)) --provider claude-code --mode context",
                    timeout: 20,
                    matcher: nil
                )
            )
            notes.append("\(event) → tells this session what the others are doing")
        }

        // PostToolUse on the editing tools → notify mode. The app turns it into
        // an implicit PathClaim: the moment an agent edits a file, everyone
        // else can know, at zero cost to the agent.
        let editMatcher = "Edit|MultiEdit|Write|NotebookEdit"
        hooks["PostToolUse"] = merged(
            into: hooks["PostToolUse"],
            entry: hookEntry(
                command: "\(quoted(paths.hookScript.path)) --provider claude-code --mode notify",
                timeout: 5,
                matcher: editMatcher
            )
        )
        notes.append("PostToolUse (Edit|MultiEdit|Write|NotebookEdit) → records implicit path claims")

        // PreToolUse on the editing tools → advise mode. Warns *before* the
        // edit lands if someone else holds the path. Advisory by default (the
        // hook never blocks; policy is config.json's claimsPolicy).
        hooks["PreToolUse"] = merged(
            into: hooks["PreToolUse"],
            entry: hookEntry(
                command: "\(quoted(paths.hookScript.path)) --provider claude-code --mode advise",
                timeout: 5,
                matcher: editMatcher
            )
        )
        notes.append("PreToolUse (Edit|MultiEdit|Write|NotebookEdit) → advises on claimed paths")

        // Only our matcher-less entries are cleaned out here: those are the old
        // shape. The new entries above carry a matcher and are exactly what
        // uninstall looks for, so wiping every entry of ours would undo this
        // install the moment it was made.
        if let cleaned = removingOurMatcherlessEntries(from: hooks["PreToolUse"]) {
            hooks["PreToolUse"] = cleaned
        } else if !planAddsPreToolUse(hooks) {
            hooks.removeValue(forKey: "PreToolUse")
        }

        settings["hooks"] = hooks

        if dryRun {
            return Result(changed: false, backup: nil, notes: notes + ["(dry run — nothing written)"])
        }

        let backup = try backupIfPresent(paths.claudeSettings)
        try writeJSONObject(settings, to: paths.claudeSettings)
        return Result(changed: true, backup: backup, notes: notes)
    }

    public func uninstallClaudeCode() throws -> Result {
        var settings = try readJSONObject(at: paths.claudeSettings)
        guard var hooks = settings["hooks"] as? [String: Any] else {
            return Result(changed: false, backup: nil, notes: ["No hooks section in settings.json"])
        }

        var removed: [String] = []
        for event in hooks.keys {
            let cleaned = removingOurEntries(from: hooks[event])
            if cleaned == nil {
                hooks.removeValue(forKey: event)
                removed.append(event)
            } else if let cleaned, !areEqual(cleaned, hooks[event]) {
                hooks[event] = cleaned
                removed.append(event)
            }
        }

        guard !removed.isEmpty else {
            return Result(changed: false, backup: nil, notes: ["Nothing of ours was installed"])
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        let backup = try backupIfPresent(paths.claudeSettings)
        try writeJSONObject(settings, to: paths.claudeSettings)
        return Result(changed: true, backup: backup, notes: removed.map { "removed from \($0)" })
    }

    /// Which of our hooks are live right now, and in what mode.
    public func claudeCodeStatus() -> [String: String] {
        guard
            let settings = try? readJSONObject(at: paths.claudeSettings),
            let hooks = settings["hooks"] as? [String: Any]
        else { return [:] }

        var status: [String: String] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    guard let command = hook["command"] as? String,
                          command.contains(Self.marker) else { continue }
                    status[event] = command.contains("--mode context")
                        ? "shares context with this session"
                        : "reports it"
                }
            }
        }
        return status
    }

    // MARK: - Codex

    /// Codex calls one external program per event and passes the payload as the
    /// last argument. If something is already installed there, we call it too
    /// rather than stealing the slot.
    public func codexNotifyScript(chaining previous: [String]) -> String {
        var lines = [
            "#!/bin/sh",
            "# GentleMerge → Codex notify bridge (generated by `gentlemerge install --codex`).",
            "# Codex passes the event JSON as the last argument.",
            "set -u",
            "",
        ]

        if let existing = previous.first, !existing.isEmpty, !existing.contains(Self.marker) {
            let passthrough = ([existing] + previous.dropFirst())
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: " ")
            lines.append("# Whatever was configured before us still runs, first and unchanged.")
            lines.append("\(passthrough) \"$@\" >/dev/null 2>&1 || :")
            lines.append("")
        }

        lines.append("for last; do :; done")
        lines.append("printf '%s' \"${last:-}\" | \(quoted(paths.hookScript.path)) --provider codex --mode notify")
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Rewrites the `notify = [...]` line in Codex's config.toml, preserving the
    /// previous program by chaining. Returns the new file contents.
    public func codexConfigContents(
        original: String,
        scriptPath: String
    ) -> (contents: String, previous: [String]) {
        let replacement = "notify = [\"\(scriptPath)\"]"
        var previous: [String] = []
        var lines = original.components(separatedBy: "\n")
        var replaced = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("notify") else { continue }
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces) == "notify"
            else { continue }

            previous = parseTOMLStringArray(String(trimmed[trimmed.index(after: equals)...]))
            lines[index] = replacement
            replaced = true
            break
        }

        if !replaced {
            // Anything after the first [table] header belongs to that table, so
            // a top-level key has to go at the very top.
            lines.insert(replacement, at: 0)
        }

        return (lines.joined(separator: "\n"), previous)
    }

    func parseTOMLStringArray(_ text: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inString = false
        var escaped = false

        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                escaped = true
            case "\"":
                if inString {
                    values.append(current)
                    current = ""
                }
                inString.toggle()
            default:
                if inString { current.append(character) }
            }
        }
        return values
    }

    // MARK: - JSON plumbing

    func hookEntry(command: String, timeout: Int, matcher: String?) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [
                ["type": "command", "command": command, "timeout": timeout] as [String: Any]
            ]
        ]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    /// Replace our previous entry for this event, keep everyone else's.
    private func merged(into existing: Any?, entry: [String: Any]) -> [[String: Any]] {
        var groups = (removingOurEntries(from: existing) as? [[String: Any]]) ?? []
        groups.append(entry)
        return groups
    }

    /// Returns nil when the event has nothing left after our entries are gone.
    private func removingOurEntries(from value: Any?) -> Any? {
        guard let groups = value as? [[String: Any]] else { return value }
        var kept: [[String: Any]] = []

        for group in groups {
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            let survivors = hooks.filter { hook in
                guard let command = hook["command"] as? String else { return true }
                return !command.contains(Self.marker)
            }
            if survivors.isEmpty, !hooks.isEmpty { continue }
            var copy = group
            copy["hooks"] = survivors
            kept.append(copy)
        }

        return kept.isEmpty ? nil : kept
    }

    /// The old PreToolUse shape had no matcher — a bare entry of ours on the
    /// event. Those are cleaned on install so the config does not grow two
    /// generations of the same hook; the new matcher entries are kept.
    private func removingOurMatcherlessEntries(from value: Any?) -> Any? {
        guard let groups = value as? [[String: Any]] else { return value }
        var kept: [[String: Any]] = []

        for group in groups {
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            let survivors = hooks.filter { hook in
                guard let command = hook["command"] as? String, command.contains(Self.marker) else {
                    return true
                }
                // Ours: keep it only when it carries a matcher.
                return hook["matcher"] != nil
            }
            if survivors.isEmpty, !hooks.isEmpty { continue }
            var copy = group
            copy["hooks"] = survivors
            kept.append(copy)
        }

        return kept.isEmpty ? nil : kept
    }

    /// True when the hooks dictionary already holds a matcher entry of ours on
    /// PreToolUse — the just-installed advise hook, which must survive the
    /// cleanup above.
    private func planAddsPreToolUse(_ hooks: [String: Any]) -> Bool {
        let groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        return groups.contains { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { hook in
                (hook["command"] as? String)?.contains(Self.marker) == true && hook["matcher"] != nil
            }
        }
    }

    private func areEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys, .fragmentsAllowed])
        let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys, .fragmentsAllowed])
        return left == right
    }

    func readJSONObject(at url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadable(url.path)
        }
        return object
    }

    func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try AtomicFile.write(data, to: url)
    }

    @discardableResult
    public func backupIfPresent(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try paths.createDirectories()
        let stamp = ISO8601DateFormatter.gentleMerge.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = paths.backups
            .appendingPathComponent("\(url.lastPathComponent).\(stamp).bak")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}

public enum InstallError: LocalizedError {
    case unreadable(String)
    case notARepo(String)
    case hooksPathOutsideRepo(path: String, configured: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "\(path) is not a JSON object — refusing to rewrite it."
        case .notARepo(let path):
            return "\(path) is not a git repository — no hooks to install."
        case .hooksPathOutsideRepo(let path, let configured):
            return "core.hooksPath=\(configured) resolves outside this repo (\(path)): git would run the gate from a directory shared by every repository. Refusing — unset it, point it inside the repo (e.g. `git config core.hooksPath .githooks`), or install the gate there by hand."
        }
    }
}
