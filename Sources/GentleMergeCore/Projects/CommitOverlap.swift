import Foundation

/// What to look at before you commit: the files you have changed, next to the
/// commits that already changed them.
///
/// The question this answers is narrow on purpose. "Has this file got history?"
/// is useless — every file does. What matters is whether somebody committed to
/// it *while you were working on it*, because that is the change your write is
/// about to undo without either of you noticing.
///
/// Two windows say that, and both come from git rather than from trust:
///
/// 1. `baseline..HEAD` — the commits that landed since your session started.
///    The baseline is the revision GentleMerge recorded when the session opened,
///    so anything in that range arrived under you.
/// 2. `HEAD..@{upstream}` — commits that exist on the remote and not in your
///    branch at all. These are the ones a push turns into somebody's bad day.
///
/// A session with no baseline — Hermes, a fresh clone, a shell — falls back to
/// the last few commits, and the report says so rather than pretending.
public struct PrecommitReport: Sendable, Equatable {
    /// One file of yours, and the commits that already touched it.
    public struct Overlap: Sendable, Equatable {
        public var path: String
        public var commits: [CommitRecord]

        public init(path: String, commits: [CommitRecord]) {
            self.path = path
            self.commits = commits
        }
    }

    public var projectName: String
    public var isRepository: Bool
    /// The revision the session started on, when we knew it. Its absence is why
    /// `checkedRecentInstead` exists.
    public var baseline: String?
    /// Everything you have not committed: modified, staged, untracked, and the
    /// old name of anything you renamed.
    public var changed: [String]
    /// The commits compared against — `baseline..HEAD`, or the last few.
    public var landed: [CommitRecord]
    /// On the upstream, not in your branch.
    public var incoming: [CommitRecord]
    public var upstream: String?
    public var overlaps: [Overlap]

    public init(
        projectName: String,
        isRepository: Bool = true,
        baseline: String? = nil,
        changed: [String] = [],
        landed: [CommitRecord] = [],
        incoming: [CommitRecord] = [],
        upstream: String? = nil,
        overlaps: [Overlap] = []
    ) {
        self.projectName = projectName
        self.isRepository = isRepository
        self.baseline = baseline
        self.changed = changed
        self.landed = landed
        self.incoming = incoming
        self.upstream = upstream
        self.overlaps = overlaps
    }

    /// Said out loud in the report: without a baseline the commit window is a
    /// guess, and a reader should weigh it as one.
    public var checkedRecentInstead: Bool { baseline == nil }

    /// Nothing to look at before committing.
    public var isClear: Bool { overlaps.isEmpty && incoming.isEmpty }

    /// The files nobody else has been near.
    public var untouched: [String] {
        let flagged = Set(overlaps.map(\.path))
        return changed.filter { !flagged.contains($0) }
    }

    /// Whether this commit reached you from the remote rather than from your
    /// own branch — the difference between "read it" and "pull first".
    public func isIncoming(_ commit: CommitRecord) -> Bool {
        incoming.contains { $0.sha == commit.sha }
    }
}

/// Runs the check. Everything that touches git is in `run`; the part worth
/// testing is `report`, which is a pure function of what git said.
public enum PrecommitCheck {
    /// How far back to look when there is no session baseline to anchor on.
    public static let fallbackDepth = 8

    /// A range never has more than this many commits pulled out of it. A branch
    /// that is four hundred commits behind does not need four hundred lines to
    /// make its point.
    public static let rangeLimit = 40

    public static func run(
        in projectPath: String,
        baseline: String? = nil,
        depth: Int = fallbackDepth
    ) -> PrecommitReport {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent

        guard GitSnapshot.isRepository(projectPath) else {
            return PrecommitReport(projectName: name, isRepository: false)
        }

        let changed = parseStatus(
            git(["status", "--porcelain", "-z"], in: projectPath).stdout
        )

        // A baseline that is already HEAD means nothing landed under us, and
        // `HEAD..HEAD` is an empty log — the honest answer, not a fallback.
        let usableBaseline = baseline.flatMap { candidate -> String? in
            guard !candidate.isEmpty, isKnownRevision(candidate, in: projectPath) else { return nil }
            return candidate
        }

        let landed: [CommitRecord]
        if let usableBaseline {
            landed = ProjectRegistry.commits(
                in: projectPath,
                range: "\(usableBaseline)..HEAD",
                limit: rangeLimit
            )
        } else {
            landed = ProjectRegistry.recentCommits(in: projectPath, limit: depth)
        }

        let upstream = upstreamName(in: projectPath)
        let incoming = upstream == nil
            ? []
            : ProjectRegistry.commits(in: projectPath, range: "HEAD..@{upstream}", limit: rangeLimit)

        return report(
            projectName: name,
            baseline: usableBaseline,
            changed: changed,
            landed: landed,
            incoming: incoming,
            upstream: upstream
        )
    }

    /// The comparison itself: which of your files somebody already committed to.
    ///
    /// Exact path matching, and nothing cleverer. A near-miss warning that
    /// fires on a file you were never going to touch is how a check like this
    /// stops being read.
    public static func report(
        projectName: String,
        baseline: String?,
        changed: [String],
        landed: [CommitRecord],
        incoming: [CommitRecord],
        upstream: String?
    ) -> PrecommitReport {
        let mine = Array(Set(changed)).sorted()
        let candidates = landed + incoming

        let overlaps = mine.compactMap { path -> PrecommitReport.Overlap? in
            let touching = candidates.filter { $0.files.contains(path) }
            return touching.isEmpty ? nil : PrecommitReport.Overlap(path: path, commits: touching)
        }

        return PrecommitReport(
            projectName: projectName,
            isRepository: true,
            baseline: baseline,
            changed: mine,
            landed: landed,
            incoming: incoming,
            upstream: upstream,
            overlaps: overlaps
        )
    }

    // MARK: - Reading the working tree

    /// `git status --porcelain -z`, which is the one form of this output that
    /// never quotes, escapes or truncates a path.
    ///
    /// A rename yields both names: the new one is what you are about to commit,
    /// and the old one is what somebody else's commit would have been talking
    /// about.
    static func parseStatus(_ raw: String) -> [String] {
        let fields = raw.components(separatedBy: "\0").filter { !$0.isEmpty }
        var paths: [String] = []
        var index = 0

        while index < fields.count {
            let entry = fields[index]
            index += 1
            // "XY path" — two status characters, a space, then the path.
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))

            if status.contains("R") || status.contains("C"), index < fields.count {
                paths.append(fields[index])
                index += 1
            }
        }

        return paths
    }

    /// `origin/main`, or nil when the branch tracks nothing — which is the
    /// normal state of a local feature branch and not worth a warning.
    static func upstreamName(in projectPath: String) -> String? {
        let output = git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: projectPath
        )
        guard output.succeeded else { return nil }
        let name = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A baseline recorded against a different clone, or one that has been
    /// rebased away, is not a range we can ask git about.
    static func isKnownRevision(_ revision: String, in projectPath: String) -> Bool {
        git(["cat-file", "-e", "\(revision)^{commit}"], in: projectPath).succeeded
    }

    @discardableResult
    static func git(_ arguments: [String], in projectPath: String, timeout: TimeInterval = 15) -> Shell.Output {
        Shell.run(
            "/usr/bin/env",
            ["git"] + arguments,
            in: URL(fileURLWithPath: projectPath),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: timeout
        )
    }
}
