import Foundation

/// Turns a tool call into the smallest thing you can decide on without
/// switching to the terminal: a headline, one line of specifics, and the raw
/// evidence underneath.
public enum ToolInputFormatter {
    public struct Description: Sendable, Equatable {
        public var title: String
        public var summary: String
        public var detail: String?

        public init(title: String, summary: String, detail: String? = nil) {
            self.title = title
            self.summary = summary
            self.detail = detail
        }
    }

    public static func describe(
        toolName: String?,
        input: JSONValue,
        cwd: String?
    ) -> Description {
        let tool = toolName ?? "tool"

        switch tool {
        case "Bash":
            let command = input.string("command") ?? ""
            let description = input.string("description")
            let title = description?.nonEmpty ?? "Run a shell command"
            var detail = command
            if let timeout = input["timeout"]?.intValue {
                detail += "\n\n(timeout \(timeout) ms)"
            }
            return Description(
                title: title,
                summary: command.firstLine.truncated(to: 140),
                detail: detail.nonEmpty
            )

        case "Edit", "MultiEdit":
            let path = input.string("file_path") ?? ""
            let old = input.string("old_string") ?? ""
            let new = input.string("new_string") ?? ""
            var detail: String?
            if !old.isEmpty || !new.isEmpty {
                detail = "- " + old.truncated(to: 400).replacingOccurrences(of: "\n", with: "\n- ")
                    + "\n+ " + new.truncated(to: 400).replacingOccurrences(of: "\n", with: "\n+ ")
            }
            return Description(
                title: "Edit \(displayName(for: path))",
                summary: relativePath(path, cwd: cwd),
                detail: detail
            )

        case "Write":
            let path = input.string("file_path") ?? ""
            let content = input.string("content") ?? ""
            let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
            return Description(
                title: "Write \(displayName(for: path))",
                summary: "\(relativePath(path, cwd: cwd)) · \(lines) \(lines == 1 ? "line" : "lines")",
                detail: content.truncated(to: 800).nonEmpty
            )

        case "NotebookEdit":
            let path = input.string("notebook_path") ?? ""
            return Description(
                title: "Edit \(displayName(for: path))",
                summary: relativePath(path, cwd: cwd),
                detail: input.string("new_source")?.truncated(to: 800)
            )

        case "Read":
            let path = input.string("file_path") ?? ""
            return Description(
                title: "Read \(displayName(for: path))",
                summary: relativePath(path, cwd: cwd)
            )

        case "Glob", "Grep":
            let pattern = input.string("pattern") ?? ""
            let path = input.string("path")
            let scope = path.map { " in \(relativePath($0, cwd: cwd))" } ?? ""
            return Description(
                title: "\(tool) search",
                summary: pattern + scope
            )

        case "WebFetch":
            let url = input.string("url") ?? ""
            let host = URL(string: url)?.host ?? url
            return Description(
                title: "Fetch \(host)",
                summary: url.truncated(to: 160),
                detail: input.string("prompt")?.truncated(to: 400)
            )

        case "WebSearch":
            let query = input.string("query") ?? ""
            return Description(title: "Web search", summary: query.truncated(to: 160))

        case "Task", "Agent":
            let description = input.string("description") ?? "Subagent task"
            return Description(
                title: "Spawn subagent: \(description)",
                summary: input.string("subagent_type") ?? "",
                detail: input.string("prompt")?.truncated(to: 600)
            )

        case "Skill":
            let skill = input.string("skill") ?? ""
            return Description(title: "Run skill \(skill)", summary: input.string("args") ?? "")

        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
                let label = parts.count >= 3
                    ? "\(parts[1]) · \(parts.dropFirst(2).joined(separator: "_"))"
                    : tool
                return Description(
                    title: "Use \(label)",
                    summary: firstMeaningfulValue(in: input) ?? "",
                    detail: prettyJSON(input)
                )
            }
            return Description(
                title: "Run \(tool)",
                summary: firstMeaningfulValue(in: input) ?? "",
                detail: prettyJSON(input)
            )
        }
    }

    // MARK: - Helpers

    static func displayName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Paths read better as `Sources/App/Foo.swift` than as 90 characters of home directory.
    public static func relativePath(_ path: String, cwd: String?) -> String {
        guard !path.isEmpty else { return "" }
        if let cwd, !cwd.isEmpty {
            let normalized = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            if path == normalized { return "." }
            if path.hasPrefix(normalized + "/") {
                return String(path.dropFirst(normalized.count + 1))
            }
        }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private static func firstMeaningfulValue(in input: JSONValue) -> String? {
        guard let object = input.objectValue else { return input.displayText.firstLine.nonEmpty }
        for key in ["command", "query", "prompt", "url", "path", "file_path", "description", "message", "text"] {
            if let value = object[key]?.stringValue, !value.isEmpty {
                return value.firstLine.truncated(to: 140)
            }
        }
        return object.keys.sorted().first.flatMap { key in
            object[key].map { "\(key): \($0.displayText.firstLine.truncated(to: 120))" }
        }
    }

    static func prettyJSON(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8),
              text != "{}"
        else { return nil }
        return text.truncated(to: 1200)
    }
}

extension String {
    var firstLine: String {
        components(separatedBy: "\n").first ?? self
    }

    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + "…"
    }
}
