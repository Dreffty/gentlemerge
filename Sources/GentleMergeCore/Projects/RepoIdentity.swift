import Foundation

/// Which repository a path belongs to — as opposed to which *working tree* it
/// is standing in.
///
/// `git rev-parse --show-toplevel` answers the second question, and inside a
/// linked worktree it answers it with the worktree's own root. For a restore
/// point that is exactly right: you snapshot the tree you are in. For identity
/// it is wrong, and wrong in the way that costs most — five agents in five
/// worktrees of one repository become five projects that cannot see each
/// other's notes, tasks or presence, and a collision warning addressed to one
/// of them by branch name gets filed where nobody will ever read it.
///
/// Identity therefore resolves through `--git-common-dir`: the one directory
/// every worktree of a repository shares.
public enum RepoIdentity {
    /// The main working tree of whatever repository `path` sits in, or nil when
    /// it is not inside a repository at all.
    ///
    /// One `git` process, same as the `--show-toplevel` call it replaces.
    public static func mainWorktreeRoot(for path: String) -> String? {
        guard !path.isEmpty else { return nil }

        var directory = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            directory = directory.deletingLastPathComponent()
        }

        // Order matters: rev-parse answers in the order it was asked, so line
        // one is the shared git directory and line two the checkout's own root.
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"],
            in: directory,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded else { return nil }

        let lines = output.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        return collapse(commonDirectory: lines[0], toplevel: lines[1])
    }

    /// The rule, split out so it can be tested without a repository.
    ///
    /// Collapsing only happens when the shared git directory is a plain `.git`
    /// sitting in a working tree. A submodule (`…/.git/modules/name`) and a
    /// bare repository (`…/repo.git`) both fail that test, and in both cases
    /// the parent directory is not somewhere a project should be filed — so
    /// they keep the checkout's own root, exactly as before.
    static func collapse(commonDirectory: String, toplevel: String) -> String {
        let checkout = PathExtractor.normalized(toplevel)
        let common = URL(fileURLWithPath: commonDirectory)
        guard common.lastPathComponent == ".git" else { return checkout }

        let candidate = PathExtractor.normalized(common.deletingLastPathComponent().path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return checkout }

        return candidate
    }

    /// The branch checked out at `path`.
    ///
    /// Worth its own answer now that every worktree of a repository shares one
    /// bus: the project says which code you are all working on, and the branch
    /// says which of you a given warning is actually about.
    ///
    /// nil on a detached HEAD and outside a repository — both mean "there is no
    /// branch to address this to", and a note aimed at a branch is delivered to
    /// a reader that cannot name one rather than swallowed.
    public static func currentBranch(at path: String) -> String? {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            in: URL(fileURLWithPath: path),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded else { return nil }
        let branch = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    /// True when `path` is a linked worktree rather than the repository's main
    /// checkout — the case whose notes used to go into a silo of their own.
    public static func isLinkedWorktree(_ path: String) -> Bool {
        guard let root = mainWorktreeRoot(for: path) else { return false }
        return root != PathExtractor.normalized(path)
    }
}
