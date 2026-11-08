import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - projects and handoff

    /// A directory named on the command line that is not there is a typo. Every
    /// command used to carry on with it: `say hola --project /no/such/dir` filed
    /// the note under a project called `dir`, and `handoff /no/such/dir` printed a
    /// handoff it had just made up.
    static func invalidDirectoryArgument(command: String?, rest: [String]) -> String? {
        func missing(_ raw: String, flag: String?) -> String? {
            let path = (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return nil
            }
            return (flag.map { "\($0) " } ?? "") + "\(raw): no such directory"
        }
        if let directory = value(after: "--project", in: rest), let problem = missing(directory, flag: "--project") {
            return problem
        }
        // The commands that take the directory as a bare argument.
        let bare: String?
        switch command {
        case "review", "handoff", "brief", "precommit": bare = positional(rest).first
        case "project": bare = ["init", "adopt-worktrees"].contains(rest.first ?? "") ? positional(rest).dropFirst().first : nil
        case "init": bare = positional(rest).first
        default: bare = nil
        }
        if let bare, let problem = missing(bare, flag: nil) { return problem }
        return nil
    }

    static func projectDirectory(_ arguments: [String], allowPositional: Bool = true) -> String {
        ProjectRegistry.canonicalPath(for: checkoutDirectory(arguments, allowPositional: allowPositional))
    }

    /// The same directory, before identity resolves it to the repository.
    ///
    /// The distinction matters for exactly one thing: which branch you are on.
    /// Every worktree of a repository is now one project, which is the point —
    /// but they are emphatically not one branch, and asking the repository root
    /// would hand every worktree the main checkout's answer.
    static func checkoutDirectory(_ arguments: [String], allowPositional: Bool = true) -> String {
        let explicit = value(after: "--project", in: arguments)
            ?? (allowPositional ? positional(arguments).first : nil)
        let raw = explicit ?? FileManager.default.currentDirectoryPath
        return (raw as NSString).expandingTildeInPath
    }

    static func projectList(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        var registry = ProjectRegistry(url: paths.projects)
        guard !registry.projects.isEmpty else {
            print("No projects yet. They appear as agents work in them, or run `gentlemerge project init`.")
            return 0
        }
        registry.refreshEstablished()
        let shown = isSet("--all", in: arguments) ? registry.projects : registry.visibleProjects()

        for summary in shown {
            let handoff = ProjectRegistry.handoff(for: summary.path, refreshingCommits: false)
            let open = handoff.openTasks.count
            var line = summary.name
            if open > 0 { line += "  · \(open) open" }
            if let last = handoff.commits.first {
                line += "  · \(HandoffMarkdown.dayFormatter.string(from: last.date)) \(last.subject)"
            }
            print(line)
            print("   \(summary.path)")
        }
        let hidden = registry.projects.count - shown.count
        if hidden > 0 {
            print("\(hidden) more: scratch folders, and plain folders nobody has worked in for a week."
                + " `gentlemerge projects --all` lists them.")
        }
        return 0
    }

    static func project(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "init":
            let directory = checkoutDirectory(Array(arguments.dropFirst()))
            do {
                let (handoff, skipped) = try ProjectRegistry.initializeReportingSkips(projectPath: directory)
                var registry = ProjectRegistry(url: Paths.fromEnvironment().projects)
                registry.seen(path: directory, provider: nil, at: Date())
                print("Handoff ready: \(ProjectHandoff.fileURL(for: handoff.projectPath).path)")
                print("Pointed CLAUDE.md / AGENTS.md at it where they exist"
                    + (skipped.isEmpty ? "." : ", except:"))
                for file in skipped {
                    print("  left \(file.name) alone: \(file.reason). Add a line pointing at .gentlemerge/HANDOFF.md yourself.")
                }
                // Generated files stay out of git; the ports module owns those
                // ignore lines, not the Core init. A line there does nothing for a
                // file git already follows, and untracking it is a change in
                // somebody's repository, so that part is said and left to them.
                WorktreeEnv.ensureGitignore(projectPath: directory)
                let inGit = Doctor.handoffInGit(project: handoff.projectPath)
                if inGit.level == .warn { print(inGit.detail) }

                // `--label <name>`: this worktree declares who it is, on the
                // shared bus. `--git-hooks`: the pre-commit in the common dir,
                // which covers every worktree of the repository at once.
                let paths = Paths.fromEnvironment()
                if let label = value(after: "--label", in: arguments) {
                    print(try WorktreeLabel.write(label: label, in: URL(fileURLWithPath: directory)))
                } else if isSet("--label", in: arguments) {
                    // `--label --git-hooks` (or nothing at all) used to be skipped without a
                    // word, leaving a worktree with no identity and a success exit.
                    FileHandle.standardError.write(Data("--label needs a name, e.g. --label claude\n".utf8))
                    return 64
                }
                if isSet("--git-hooks", in: arguments) {
                    print(try GitHookInstaller(paths: paths).install(repo: URL(fileURLWithPath: directory)))
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }

        case "adopt-worktrees":
            return adoptWorktrees(Array(arguments.dropFirst()))

        default:
            FileHandle.standardError.write(
                Data("usage: gentlemerge project init|adopt-worktrees [dir]\n".utf8)
            )
            return 64
        }
    }

    /// Brings home what the worktree silos collected while every checkout was a
    /// project of its own.
    ///
    /// One-shot and idempotent, so running it on a repository that was never
    /// split costs a `git worktree list` and says so. Nothing is deleted: the
    /// worktree files keep their copy, they simply stop being the only one.
    static func adoptWorktrees(_ arguments: [String]) -> Int32 {
        let directory = projectDirectory(arguments)
        let report = WorktreeAdoption.adopt(
            repository: directory,
            registryURL: Paths.fromEnvironment().projects
        )

        guard report.changedSomething else {
            print("Nothing to adopt: \(URL(fileURLWithPath: report.repository).lastPathComponent) already has one task list.")
            return 0
        }

        if report.tasksAdopted > 0 {
            let noun = report.tasksAdopted == 1 ? "task" : "tasks"
            print("Adopted \(report.tasksAdopted) open \(noun) into \(ProjectHandoff.fileURL(for: report.repository).path)")
            for source in report.sources {
                print("   from \(source)")
            }
        }
        if !report.projectsFolded.isEmpty {
            let noun = report.projectsFolded.count == 1 ? "worktree" : "worktrees"
            print("Folded \(report.projectsFolded.count) \(noun) back into the project:")
            for path in report.projectsFolded {
                print("   \(path)")
            }
        }
        return 0
    }

    /// Prints the whole handoff — what an agent should read before starting.
    static func handoff(_ arguments: [String]) -> Int32 {
        let directory = projectDirectory(arguments)
        let handoff = ProjectRegistry.handoff(for: directory)
        print(HandoffMarkdown.render(handoff))
        return 0
    }
}
