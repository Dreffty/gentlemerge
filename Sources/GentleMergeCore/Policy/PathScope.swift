import Foundation

/// Where a tool call reaches. Agents that quietly step outside the directory you
/// pointed them at are the thing people notice too late.
public enum PathScope: String, Codable, Sendable {
    case inside
    case outside
    case unknown
}

public enum PathExtractor {
    /// Directories every toolchain touches constantly. Treating these as
    /// "outside your project" would make the warning meaningless.
    static let systemPrefixes = [
        "/usr/", "/bin/", "/sbin/", "/opt/", "/dev/", "/etc/", "/var/", "/tmp/",
        "/private/", "/System/", "/Library/", "/Applications/", "/nix/",
    ]

    /// Paths a tool call is about to act on. File tools state them outright;
    /// for shell commands this is a deliberately conservative guess.
    public static func paths(toolName: String?, input: JSONValue) -> [String] {
        var found: [String] = []

        for key in ["file_path", "notebook_path", "path", "directory", "cwd"] {
            if let value = input.string(key), !value.isEmpty {
                found.append(value)
            }
        }

        // MultiEdit-shaped payloads carry their own list.
        if let edits = input["edits"]?.arrayValue {
            for edit in edits {
                if let value = edit.string("file_path"), !value.isEmpty { found.append(value) }
            }
        }

        if toolName == "Bash", let command = input.string("command") {
            found.append(contentsOf: pathsMentioned(inCommand: command))
        }

        return found.map(expandingTilde)
    }

    /// Absolute-looking tokens in a shell command, minus the ones that are just
    /// the toolchain doing its job. Best effort by construction: a command is
    /// not a parseable thing, and pretending otherwise would produce warnings
    /// nobody trusts.
    static func pathsMentioned(inCommand command: String) -> [String] {
        var results: [String] = []
        let separators = CharacterSet(charactersIn: " \t\n;|&\"'`()<>")

        for rawToken in command.components(separatedBy: separators) {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ",:="))
            guard token.hasPrefix("/") || token.hasPrefix("~/") else { continue }
            let expanded = expandingTilde(token)
            guard !systemPrefixes.contains(where: { expanded.hasPrefix($0) }) else { continue }
            results.append(expanded)
        }

        return results
    }

    public static func scope(of paths: [String], project: String?) -> PathScope {
        guard let project, !project.isEmpty else { return paths.isEmpty ? .unknown : .unknown }
        guard !paths.isEmpty else { return .unknown }

        let root = normalized(project)
        for path in paths {
            let candidate = normalized(path)
            if candidate == root || candidate.hasPrefix(root + "/") { continue }
            return .outside
        }
        return .inside
    }

    static func expandingTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }

    /// Resolves `..`, symlinks and trailing slashes so containment checks cannot
    /// be walked around with `project/../../etc`.
    static func normalized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return standardized.hasSuffix("/") && standardized.count > 1
            ? String(standardized.dropLast())
            : standardized
    }
}
