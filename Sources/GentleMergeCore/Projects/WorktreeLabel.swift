import Foundation

/// The label a worktree declares for itself, set by `gentlemerge init --label`:
/// git config with `extensions.worktreeConfig`, so five worktrees of one repo
/// are five labels on one shared bus.
///
/// The label is the identity every consumer compares: the gate judges `me`
/// against a claim's `label`, `--to` routing matches it, presence marks are
/// filed under it. All of those go through `Identity.safe`, so a raw value
/// that safe would alter must never reach them — with `--label "🚀rocket"` the
/// claim was filed as `rocket` while the gate read `🚀rocket`, so the committer
/// was told *"`a.txt` is claimed by rocket … say --to rocket"* about its own
/// claim, for the life of the claim (audit 2026-10-08).
public enum WorktreeLabel {
    /// `extensions.worktreeConfig` is a repository-wide setting that has to live
    /// in a **working tree's** config. In a linked worktree of a *bare*
    /// repository there is none: `git config` writes it into the bare common
    /// config, git then concludes that every linked worktree of that repository
    /// is bare too, and every command dies with `fatal: this operation must be
    /// run in a work tree` (audit 2026-10-08). Refusing costs one `git config`
    /// read; the alternative bricks the user's repository.
    public struct BareRepository: Error, LocalizedError, CustomStringConvertible {
        public let path: String
        public var description: String { errorDescription ?? "" }
        public var errorDescription: String? {
            "\(path) is a bare repository, so `--label` cannot use per-worktree "
            + "git config (it would make git refuse every worktree). "
            + "Use `GENTLEMERGE_LABEL` in each worktree's shell instead."
        }
    }

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
        guard let label, !label.isEmpty else { return nil }
        // Safe on read as well as on write: the config is hand-editable and a
        // value written by an older binary (or by hand) still has to agree with
        // the label claims and presence are filed under.
        return Identity.safe(label)
    }

    private static func isBare(_ repo: URL) -> Bool {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "config", "--get", "core.bare"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 5
        )
        return output.succeeded
            && output.lines.first?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    /// `init --label <name>`: the once-per-repo worktree config, then the label
    /// in this worktree. The stored value is the safe one, so what git reports
    /// and what every reader computes are the same string.
    @discardableResult
    public static func write(label: String, in repo: URL) throws -> String {
        guard !isBare(repo) else { throw BareRepository(path: repo.path) }
        let safe = Identity.safe(label)
        _ = Shell.run(
            "/usr/bin/env",
            ["git", "config", "extensions.worktreeConfig", "true"],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 5
        )
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "config", "--worktree", "gentlemerge.label", safe],
            in: repo,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 5
        )
        guard output.succeeded else {
            // Its own error, not `InstallError.unreadable`: that one is about a
            // config file and its text reads "… is not a JSON object — refusing
            // to rewrite it", which is a lie about a git failure
            // (audit 2026-10-08).
            throw LabelError.gitRefused(path: repo.path,
                                       detail: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return "label `\(safe)` set for this worktree"
    }
}

/// The worktree's label could not be written.
public enum LabelError: Error, LocalizedError, CustomStringConvertible {
    case gitRefused(path: String, detail: String)

    public var description: String { errorDescription ?? "" }
    public var errorDescription: String? {
        switch self {
        case .gitRefused(let path, let detail):
            return "could not set the label for \(path) — git said:"
                + " \(detail.isEmpty ? "(nothing)" : detail)"
        }
    }
}
