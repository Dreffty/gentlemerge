import Foundation

/// Folding the worktree silos back into the repository they belong to.
///
/// Before identity went through `RepoIdentity`, every linked worktree was a
/// project of its own: its own handoff file, its own task list, its own corner
/// of the bus. Fixing identity stops new work being split that way, but it does
/// not go back for what the silos already collected — and a task list nobody
/// can see any more is worse than one that was never written.
///
/// So this walks the worktrees once and brings their open tasks home.
public enum WorktreeAdoption {
    public struct Report: Sendable, Equatable {
        public var repository: String
        /// The worktree handoff files that had something in them.
        public var sources: [String]
        public var tasksAdopted: Int
        /// Registry entries that stopped being projects of their own.
        public var projectsFolded: [String]

        public var changedSomething: Bool { tasksAdopted > 0 || !projectsFolded.isEmpty }
    }

    /// Every linked worktree of `repository` — the main checkout excluded,
    /// because that is the one we are folding *into*.
    public static func linkedWorktrees(of repository: String) -> [String] {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "worktree", "list", "--porcelain"],
            in: URL(fileURLWithPath: repository),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 20
        )
        guard output.succeeded else { return [] }
        return parseWorktreeList(output.stdout, excluding: repository)
    }

    /// Split out from the git call so the format can be tested without a
    /// repository. A `worktree` line opens each block; everything else in the
    /// block is about the checkout, not where it lives.
    static func parseWorktreeList(_ raw: String, excluding repository: String) -> [String] {
        let root = PathExtractor.normalized(repository)
        return raw
            .components(separatedBy: "\n")
            .compactMap { line in
                guard line.hasPrefix("worktree ") else { return nil }
                return PathExtractor.normalized(String(line.dropFirst("worktree ".count)))
            }
            .filter { $0 != root }
    }

    /// Brings the open tasks of every worktree handoff into the repository's
    /// own, and folds the worktree entries out of the project registry.
    ///
    /// Idempotent: tasks are matched by text the same way `addTask` matches
    /// them, so running it twice adopts nothing the second time. Nothing is
    /// deleted — the worktree files stay where they are, they simply stop being
    /// the only copy.
    @discardableResult
    public static func adopt(repository rawPath: String, registryURL: URL? = nil) -> Report {
        let repository = ProjectRegistry.canonicalPath(for: rawPath)
        var report = Report(repository: repository, sources: [], tasksAdopted: 0, projectsFolded: [])

        var handoff = ProjectRegistry.handoff(for: repository, refreshingCommits: false)

        for worktree in linkedWorktrees(of: repository) {
            let fileURL = ProjectHandoff.fileURL(for: worktree)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let orphan = HandoffMarkdown.parse(text, projectPath: worktree)

            // Only what is still open. A finished task is history the worktree
            // can keep; carrying it over would bury the live list under it.
            let adopted = orphan.openTasks.filter { candidate in
                !handoff.tasks.contains {
                    $0.text.caseInsensitiveCompare(candidate.text) == .orderedSame
                }
            }
            guard !adopted.isEmpty else { continue }

            handoff.tasks.append(contentsOf: adopted)
            report.sources.append(fileURL.path)
            report.tasksAdopted += adopted.count
        }

        if report.tasksAdopted > 0 {
            ProjectRegistry.save(handoff)
        }

        if let registryURL {
            var registry = ProjectRegistry(url: registryURL)
            report.projectsFolded = registry.foldWorktrees()
        }

        return report
    }
}
