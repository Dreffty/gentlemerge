import Foundation

public struct FileChange: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    /// `M`, `A`, `D`, `R`, or `??` for untracked.
    public var status: String
    public var added: Int
    public var removed: Int

    public var isUntracked: Bool { status == "??" }

    public init(path: String, status: String, added: Int, removed: Int) {
        self.path = path
        self.status = status
        self.added = added
        self.removed = removed
    }
}

/// What the agent actually changed, measured against where the session started.
public struct WorkSummary: Codable, Sendable, Equatable {
    public var projectPath: String
    public var isRepository: Bool
    /// The commit the session started from, when we saw it start.
    public var baseline: String?
    public var baselineIsHead: Bool
    public var changes: [FileChange]
    /// Paths the agent touched outside the project, seen through the hooks.
    public var outsidePaths: [String]

    public init(
        projectPath: String,
        isRepository: Bool,
        baseline: String? = nil,
        baselineIsHead: Bool = false,
        changes: [FileChange] = [],
        outsidePaths: [String] = []
    ) {
        self.projectPath = projectPath
        self.isRepository = isRepository
        self.baseline = baseline
        self.baselineIsHead = baselineIsHead
        self.changes = changes
        self.outsidePaths = outsidePaths
    }

    public var totalAdded: Int { changes.reduce(0) { $0 + $1.added } }
    public var totalRemoved: Int { changes.reduce(0) { $0 + $1.removed } }
    public var isEmpty: Bool { changes.isEmpty && outsidePaths.isEmpty }

    public var headline: String {
        guard !changes.isEmpty else { return "No file changes" }
        let files = "\(changes.count) \(changes.count == 1 ? "file" : "files")"
        return "\(files) · +\(totalAdded) −\(totalRemoved)"
    }
}

public struct CheckResult: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case passed
        case failed
        case timedOut
        case skipped
        case running
    }

    public var id: String { name }
    public var name: String
    public var command: String
    public var kind: Check.Kind
    public var status: Status
    public var exitCode: Int32?
    public var duration: TimeInterval
    /// The tail of what it printed — enough to see the failure, not a wall.
    public var output: String
    public var skipReason: String?

    public init(
        name: String,
        command: String,
        kind: Check.Kind,
        status: Status,
        exitCode: Int32? = nil,
        duration: TimeInterval = 0,
        output: String = "",
        skipReason: String? = nil
    ) {
        self.name = name
        self.command = command
        self.kind = kind
        self.status = status
        self.exitCode = exitCode
        self.duration = duration
        self.output = output
        self.skipReason = skipReason
    }

    public var symbol: String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .timedOut: return "clock.badge.exclamationmark.fill"
        case .skipped: return "minus.circle"
        case .running: return "circle.dotted"
        }
    }
}

public struct Review: Codable, Sendable, Equatable, Identifiable {
    public enum Verdict: String, Codable, Sendable {
        /// Everything that ran, passed. Never the whole story — see `openQuestions`.
        case passed
        case problems
        /// Nothing could be run, so nothing is known.
        case unverified
        case running
    }

    public var id: String
    public var sessionID: String?
    public var projectPath: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var work: WorkSummary
    public var checks: [CheckResult]
    /// What no command here can answer. The point of the whole feature.
    public var openQuestions: [String]

    public init(
        id: String = UUID().uuidString,
        sessionID: String? = nil,
        projectPath: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        work: WorkSummary,
        checks: [CheckResult] = [],
        openQuestions: [String] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.work = work
        self.checks = checks
        self.openQuestions = openQuestions
    }

    public var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }

    public var verdict: Verdict {
        if finishedAt == nil { return .running }
        if checks.contains(where: { $0.status == .failed || $0.status == .timedOut }) { return .problems }
        if checks.contains(where: { $0.status == .passed }) { return .passed }
        return .unverified
    }

    /// Deliberately never "all good": it says what ran, and what did not.
    public var headline: String {
        let ran = checks.filter { $0.status == .passed || $0.status == .failed || $0.status == .timedOut }
        switch verdict {
        case .running: return "Checking…"
        case .problems:
            let bad = checks.filter { $0.status == .failed || $0.status == .timedOut }
            return "\(bad.count) of \(ran.count) checks failed"
        case .passed:
            return "\(ran.count) \(ran.count == 1 ? "check" : "checks") passed"
        case .unverified:
            return "Nothing could be checked automatically"
        }
    }
}

/// Reads what changed and decides what a machine cannot answer about it.
public enum WorkInspector {
    public static func summarize(
        projectPath: String,
        baseline: String?,
        outsidePaths: [String] = []
    ) -> WorkSummary {
        let project = URL(fileURLWithPath: projectPath)
        guard let snapshot = GitSnapshot(anyPathInside: projectPath) else {
            return WorkSummary(
                projectPath: projectPath,
                isRepository: false,
                baseline: nil,
                baselineIsHead: false,
                changes: [],
                outsidePaths: outsidePaths
            )
        }

        let repository = snapshot.repository
        let head = git(["rev-parse", "HEAD"], in: repository).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseline?.nonEmpty ?? (head.isEmpty ? nil : head)

        var changes: [FileChange] = []
        if let base {
            // numstat against the session's starting commit covers both what was
            // committed during the session and what is still in the working tree.
            let numstat = git(["diff", "--numstat", base], in: repository)
            for line in numstat.lines {
                let fields = line.components(separatedBy: "\t")
                guard fields.count >= 3 else { continue }
                changes.append(
                    FileChange(
                        path: fields[2],
                        status: "M",
                        added: Int(fields[0]) ?? 0,
                        removed: Int(fields[1]) ?? 0
                    )
                )
            }
        }

        // Without --untracked-files=all git reports a new directory as one
        // entry, which would hide every file the agent just created in it.
        for line in git(["status", "--porcelain", "--untracked-files=all"], in: repository).lines {
            guard line.count > 3 else { continue }
            let status = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            let path = String(line.dropFirst(3))
            if status == "??" {
                let lines = countLines(at: repository.appendingPathComponent(path))
                changes.append(FileChange(path: path, status: "??", added: lines, removed: 0))
            } else if let index = changes.firstIndex(where: { $0.path == path }) {
                changes[index].status = status
            }
        }

        _ = project
        return WorkSummary(
            projectPath: repository.path,
            isRepository: true,
            baseline: base,
            baselineIsHead: base == head,
            changes: changes.sorted { $0.added + $0.removed > $1.added + $1.removed },
            outsidePaths: outsidePaths
        )
    }

    /// The honest part of the report: what changed that no command here checks.
    public static func openQuestions(for work: WorkSummary, checks: [CheckResult]) -> [String] {
        var questions: [String] = []

        if !work.isRepository {
            questions.append(
                "This project is not a git repository, so there is no before-and-after to compare."
            )
        } else if work.baseline == nil {
            questions.append("No baseline for this session, so the diff is against the current commit.")
        } else if !work.baselineIsHead {
            questions.append("The session also committed: this diff spans commits, not just uncommitted work.")
        }

        let paths = work.changes.map(\.path)

        let visual = paths.filter { path in
            let lower = path.lowercased()
            return lower.hasSuffix("view.swift") || lower.contains("/views/")
                || [".xib", ".storyboard", ".css", ".scss", ".html", ".tsx", ".jsx", ".vue", ".svelte"]
                    .contains { lower.hasSuffix($0) }
        }
        if !visual.isEmpty {
            questions.append(
                "\(visual.count) view \(visual.count == 1 ? "file" : "files") changed — nothing here can tell you how it looks."
            )
        }

        let tests = paths.filter { path in
            let lower = path.lowercased()
            return lower.contains("test") || lower.contains("spec") || lower.contains("__tests__")
        }
        let sources = paths.filter { path in
            ![".md", ".txt", ".json", ".yml", ".yaml", ".lock"].contains { path.hasSuffix($0) }
        }
        if tests.isEmpty, sources.count >= 3 {
            questions.append("\(sources.count) source files changed and no test file did.")
        }

        let lockfiles = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Cargo.lock",
                         "Package.resolved", "Podfile.lock", "poetry.lock", "go.sum"]
        if paths.contains(where: { path in lockfiles.contains(where: { path.hasSuffix($0) }) }) {
            questions.append("A dependency lockfile moved — worth reading that diff yourself.")
        }

        if paths.contains(where: { $0.lowercased().contains("migration") || $0.lowercased().contains("schema") }) {
            questions.append("Schema or migration files changed; nothing here ran them against real data.")
        }

        if !work.outsidePaths.isEmpty {
            let list = work.outsidePaths.prefix(4).joined(separator: ", ")
            questions.append("The agent reached outside the project: \(list).")
        }

        if !checks.contains(where: { $0.kind == .test && $0.status == .passed }) {
            questions.append("No test suite ran, so nothing confirmed behaviour — only that it builds.")
        }

        return questions
    }

    private static func countLines(at url: URL) -> Int {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            (attributes[.size] as? Int ?? 0) < 2_000_000,
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return 0 }
        return contents.isEmpty ? 0 : contents.components(separatedBy: "\n").count
    }

    private static func git(_ arguments: [String], in directory: URL) -> Shell.Output {
        Shell.run(
            "/usr/bin/env",
            ["git"] + arguments,
            in: directory,
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 30
        )
    }
}
