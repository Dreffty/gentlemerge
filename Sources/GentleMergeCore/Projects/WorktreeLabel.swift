import Foundation

/// The label a worktree declares for itself, set by `gentlemerge init --label`:
/// git config with `extensions.worktreeConfig`, so five worktrees of one repo
/// are five labels on one shared bus.
public enum WorktreeLabel {
    public static func read(cwd: URL) -> String? {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "config", "--get", "gentlemerge.label"],
            in: cwd,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 5
        )
        guard output.succeeded else { return nil }
        let label = output.lines.first?.trimmingCharacters(in: .whitespaces)
        return (label?.isEmpty == false) ? label : nil
    }

    /// `init --label <name>`: the once-per-repo worktree config, then the label
    /// in this worktree.
    @discardableResult
    public static func write(label: String, in repo: URL) throws -> String {
        _ = Shell.run(
            "/usr/bin/env",
            ["git", "config", "extensions.worktreeConfig", "true"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 5
        )
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "config", "--worktree", "gentlemerge.label", label],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 5
        )
        guard output.succeeded else {
            throw InstallError.unreadable(repo.path)  // ADAPTED: reuse of the only install error there is
        }
        return "label `\(label)` set for this worktree"
    }
}
