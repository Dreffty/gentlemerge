import Foundation

/// Early warning for branches that will collide at merge time.
///
/// Two phases, cheapest first. Phase one compares every candidate branch
/// against the landing target (O(n) — the conflict that actually matters at
/// land time). Phase two compares pairs, but only when their changed file
/// sets overlap: disjoint branches cannot conflict, so no merge-tree runs.
/// The first time a conflict is seen, the affected sides get a note on the
/// bus; the signature is then recorded, so the warning fires once no matter
/// how many drains see the same conflict.
///
/// What the radar sees: commits. Claims cover edits still in flight; work
/// that is uncommitted on another machine is visible to nobody.
///
/// Never an error: an old git, a missing repository, or a lock that cannot be
/// taken all end in `skipped` with the reason in the ledger, and the sweep
/// costs one small JSON read per project until its three minutes are up.
public enum ConflictRadar {
    /// At most one sweep per project per this interval, drains included.
    public static let throttle: TimeInterval = 3 * 60
    /// Signatures older than this are forgotten, so a conflict that outlives a
    /// month gets one repeat warning instead of a state file that grows forever.
    public static let announcedTTL: TimeInterval = 30 * 24 * 3600
    public static let branchPrefix = "agent/"
    public static let minimumGit = (major: 2, minor: 38, patch: 0)
    /// A warning that names more files than this stops naming them.
    public static let maxListedPaths = 8

    /// A sweep checks at most this many pairs. merge-tree is milliseconds, but
    /// pairs grow quadratically with branches — without a cap, a forest of
    /// agent branches would hold the drain for tens of seconds every three
    /// minutes. Rotation (see pairOffset) means every pair is still checked,
    /// just across consecutive sweeps.
    public static let maxPairsPerSweep = 64

    public enum SweepResult: Sendable, Equatable {
        case throttled
        case skipped(reason: String)
        case nothingToDo
        case done(announced: Int, pairs: Int)
    }

    // MARK: - Pure parts

    /// The branches worth comparing: local `agent/*` branches, sorted.
    public static func agentBranches(from refs: [String]) -> [String] {
        Array(Set(refs.filter { $0.hasPrefix(branchPrefix) && $0.count > branchPrefix.count })).sorted()
    }

    /// Every branch a live session stands on, whatever it is called, plus the
    /// `agent/*` locals: sorted, deduplicated. A session on `main` or on an
    /// `agent/*` branch adds nothing new.
    public static func candidates(agent: [String], presenceBranches: [String]) -> [String] {
        let extra = presenceBranches.filter { !$0.isEmpty && !agent.contains($0) }
        return Array(Set(agent + extra)).sorted()
    }

    /// Two change sets share at least one path. Disjoint branches cannot
    /// conflict, so the pair never reaches merge-tree.
    public static func overlaps(_ a: [String], _ b: [String]) -> Bool {
        !Set(a).isDisjoint(with: Set(b))
    }

    /// Every unordered pair, each ordered so the signature is stable whichever
    /// way the branches were listed.
    public static func pairs(of branches: [String]) -> [(String, String)] {
        var result: [(String, String)] = []
        for (index, first) in branches.enumerated() {
            for second in branches.dropFirst(index + 1) {
                result.append(first < second ? (first, second) : (second, first))
            }
        }
        return result
    }

    /// `merge-tree --name-only` prints the resulting tree oid first and the
    /// conflicted paths after it — on a clean merge, only the oid.
    public static func parseMergeTreeNameOnly(_ stdout: String) -> [String] {
        let lines = stdout
            .components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty })
        return Array(lines.dropFirst()).sorted()
    }

    /// The ordered pair plus a hash of the sorted paths: the same conflict
    /// announces once, a new file in the same pair announces again. The merge
    /// base joins the material when known: a rebase changes what the conflict
    /// means, so it announces again rather than staying silent on new facts.
    public static func signature(branchA: String, branchB: String, paths: [String], base: String? = nil) -> String {
        let ordered = [branchA, branchB].sorted()
        let material = (ordered + paths.sorted() + (base.map { [$0] } ?? [])).joined(separator: "\0")
        return "\(ordered[0])|\(ordered[1])|\(PortableSHA256.digest(Data(material.utf8)))"
    }

    /// Who a branch belongs to, by the project's own convention: the worktree
    /// on `agent/claude` was labelled `claude` at `init --label`. A deeper
    /// nesting addresses literally — exact match or nobody, never somebody
    /// else.
    public static func label(forBranch branch: String) -> String {
        guard branch.hasPrefix(branchPrefix) else { return branch }
        return String(branch.dropFirst(branchPrefix.count))
    }

    public static func warningText(other: String, paths: [String]) -> String {
        let sorted = paths.sorted()
        let listed = sorted.prefix(maxListedPaths).joined(separator: ", ")
        let tail = sorted.count > maxListedPaths ? "… +\(sorted.count - maxListedPaths) more" : ""
        return "⚠ your branch will conflict with \(other) on \(listed)\(tail). Coordinate before landing."
    }

    /// "git version 2.50.1 (Apple Git-155)" → (2, 50, 1).
    public static func parseGitVersion(_ stdout: String) -> (Int, Int, Int)? {
        let words = stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard words.count >= 3, words[0] == "git", words[1] == "version" else { return nil }
        let numbers = words[2].components(separatedBy: ".").compactMap(Int.init)
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : 0)
    }

    public static func supportsMergeTree(version: (Int, Int, Int)) -> Bool {
        if version.0 != minimumGit.major { return version.0 > minimumGit.major }
        if version.1 != minimumGit.minor { return version.1 > minimumGit.minor }
        return version.2 >= minimumGit.patch
    }

    // MARK: - Git

    @discardableResult
    static func git(_ arguments: [String], in repo: String, timeout: TimeInterval = 60) -> Shell.Output {
        Shell.run(
            "/usr/bin/env",
            ["git"] + arguments,
            in: URL(fileURLWithPath: repo),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: timeout
        )
    }

    public static func gitVersion(in repo: String) -> (Int, Int, Int)? {
        let output = git(["--version"], in: repo, timeout: 10)
        guard output.succeeded else { return nil }
        return parseGitVersion(output.stdout)
    }

    public static func agentBranchNames(in repo: String) -> [String] {
        let output = git(["for-each-ref", "--format=%(refname:short)", "refs/heads/\(branchPrefix)"], in: repo)
        guard output.succeeded else { return [] }
        return agentBranches(from: output.lines)
    }

    /// The paths `a` and `b` would conflict on, [] when they merge cleanly,
    /// nil when git could not answer (unknown ref, old git, wrong directory).
    public static func conflicts(between a: String, and b: String, in repo: String) -> [String]? {
        let output = git(
            ["merge-tree", "--write-tree", "--no-messages", "--name-only", a, b],
            in: repo
        )
        if output.succeeded { return [] }
        guard output.status == 1 else { return nil }
        let parsed = parseMergeTreeNameOnly(output.stdout)
        return parsed.isEmpty ? nil : parsed
    }

    /// Branches old enough to be archaeology stay out of the pair phase: a
    /// branch untouched for this long is abandoned, and its conflicts are
    /// somebody's history lesson, not a warning. The vs-main phase still sees
    /// it — that check is cheap and it is the one that matters at land time.
    public static let pruneAfter: TimeInterval = 90 * 24 * 3600

    static func mergeBase(_ a: String, _ b: String, in repo: String) -> String? {
        let output = git(["merge-base", a, b], in: repo, timeout: 10)
        guard output.succeeded else { return nil }
        let sha = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Paths changed on `tip` since `base`, nil when git could not answer.
    static func changedFiles(from base: String, to tip: String, in repo: String) -> [String]? {
        let output = git(["diff", "--name-only", "\(base)...\(tip)"], in: repo, timeout: 10)
        guard output.succeeded else { return nil }
        return output.lines.filter { !$0.isEmpty }
    }

    static func refExists(_ ref: String, in repo: String) -> Bool {
        git(["rev-parse", "--verify", "--quiet", "refs/heads/\(ref)"], in: repo, timeout: 10).succeeded
    }

    /// Seconds since the tip commit, nil when git could not answer.
    static func tipAge(_ branch: String, in repo: String, now: Date = Date()) -> TimeInterval? {
        let output = git(["log", "-1", "--format=%ct", branch], in: repo, timeout: 10)
        guard output.succeeded, let stamp = TimeInterval(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return now.timeIntervalSince(Date(timeIntervalSince1970: stamp))
    }

    // MARK: - State

    /// What the radar remembers: per-project throttle marks, and the conflict
    /// signatures it already announced. Forgiving on purpose — a file from a
    /// newer binary still decodes here, minus the keys this one never heard of.
    public struct State: Codable, Sendable {
        public var lastRun: [String: Date]
        public var announced: [String: Date]
        /// When an automatic landing last wrote down why it gave up, per
        /// project and branch. A broken branch emits one Stop per turn; the
        /// ledger gets one line per half hour, not one per turn.
        public var lastAutoNote: [String: Date]
        /// Where the next sweep's pair window starts, per project. The sweep
        /// checks at most maxPairsPerSweep pairs and rotates, so a capped
        /// sweep continues where it left off instead of re-checking the same
        /// first pairs forever.
        public var pairOffset: [String: Int]

        public init(
            lastRun: [String: Date] = [:],
            announced: [String: Date] = [:],
            lastAutoNote: [String: Date] = [:],
            pairOffset: [String: Int] = [:]
        ) {
            self.lastRun = lastRun
            self.announced = announced
            self.lastAutoNote = lastAutoNote
            self.pairOffset = pairOffset
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastRun = (try? container.decodeIfPresent([String: Date].self, forKey: .lastRun)) ?? [:]
            announced = (try? container.decodeIfPresent([String: Date].self, forKey: .announced)) ?? [:]
            lastAutoNote = (try? container.decodeIfPresent([String: Date].self, forKey: .lastAutoNote)) ?? [:]
            pairOffset = (try? container.decodeIfPresent([String: Int].self, forKey: .pairOffset)) ?? [:]
        }
    }

    static func loadState(paths: Paths) -> State {
        guard let data = try? Data(contentsOf: paths.radar),
              let state = try? JSONCoding.decoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    static func saveState(_ state: State, paths: Paths, now: Date = Date()) {
        var state = state
        state.announced = state.announced.filter { now.timeIntervalSince($0.value) < announcedTTL }
        if state.lastRun.count > 200 {
            let cutoff = state.lastRun.values.sorted().suffix(200).first ?? .distantPast
            state.lastRun = state.lastRun.filter { $0.value >= cutoff }
        }
        do {
            try AtomicFile.write(try JSONCoding.encoder(pretty: true).encode(state), to: paths.radar)
        } catch {
            Log.error("could not save radar state: \(error.localizedDescription)")
        }
    }

    // MARK: - Sweep

    /// Which pairs this sweep checks: `cap` pairs from `offset`, wrapping
    /// around, so consecutive capped sweeps cover everything exactly once
    /// before repeating. Pure, so the rotation is testable without git.
    static func window(of pairs: [(String, String)], offset: Int, cap: Int) -> (selected: [(String, String)], nextOffset: Int) {
        guard !pairs.isEmpty, cap > 0 else { return ([], offset) }
        let start = offset % pairs.count
        let count = min(cap, pairs.count)
        var selected: [(String, String)] = []
        selected.reserveCapacity(count)
        for step in 0..<count {
            selected.append(pairs[(start + step) % pairs.count])
        }
        return (selected, (start + count) % pairs.count)
    }

    /// One project, throttled. The whole read-modify-write holds the sidecar
    /// lock, so an app drain and a CLI run sweeping the same project cannot
    /// announce the same conflict twice.
    public static func sweep(
        project: String,
        paths: Paths,
        now: Date = Date(),
        ignoreThrottle: Bool = false,
        maxPairs: Int = maxPairsPerSweep
    ) -> SweepResult {
        do {
            return try LockedFile.withExclusiveLock(paths.radar) {
                var state = loadState(paths: paths)
                defer { saveState(state, paths: paths, now: now) }

                if !ignoreThrottle,
                   let last = state.lastRun[project],
                   now.timeIntervalSince(last) < throttle {
                    return .throttled
                }
                state.lastRun[project] = now

                let agent = agentBranchNames(in: project)
                let liveBranches = Presence.marks(paths: paths)
                    .filter { $0.projectPath == nil || $0.projectPath == project }
                    .compactMap(\.branch)
                    .filter { !agent.contains($0) && refExists($0, in: project) }
                let branches = candidates(agent: agent, presenceBranches: liveBranches)
                // One branch is enough: phase one warns it against main.
                // Checked before the git version: with nothing to compare,
                // merge-tree is never needed.
                guard !branches.isEmpty else { return .nothingToDo }

                let gitVersion = gitVersion(in: project)
                guard let supported = gitVersion, supportsMergeTree(version: supported) else {
                    let reason = gitVersion.map { "git \($0.0).\($0.1).\($0.2) < 2.38, merge-tree unavailable" }
                        ?? "git did not answer --version"
                    Ledger(url: paths.ledger).append(LedgerEntry(
                        at: now, kind: .note, project: project,
                        title: "radar.skipped", summary: reason
                    ))
                    return .skipped(reason: reason)
                }

                let bus = AgentBus(paths: paths)
                let ledger = Ledger(url: paths.ledger)
                var announced = 0

                @discardableResult
                func announce(_ conflicted: [String], mine: String, other: String, base: String?) -> Bool {
                    // Directional: one pair conflict warns both sides, once
                    // each. A shared key would let the first side's write
                    // silence the second side's warning.
                    let key = "\(mine)→\(other)|\(signature(branchA: mine, branchB: other, paths: conflicted, base: base))"
                    guard state.announced[key] == nil else { return false }
                    bus.post(AgentMessage(
                        from: "gentlemerge",
                        to: label(forBranch: mine),
                        projectPath: project,
                        text: warningText(other: other, paths: conflicted),
                        kind: .urgent,
                        toBranch: mine
                    ))
                    state.announced[key] = now
                    ledger.append(LedgerEntry(
                        at: now, kind: .note, project: project,
                        title: "radar.conflict",
                        summary: "\(mine) ↔ \(other): \(conflicted.count) file(s) (\(conflicted.sorted().prefix(3).joined(separator: ", ")))"
                    ))
                    return true
                }

                // Phase one: every branch against the landing target. O(n), and
                // the conflict that actually matters at land time. A branch
                // with nothing ahead is merged or empty — nothing to warn.
                let into = Landing.defaultInto(repo: project)
                if let into {
                    for branch in branches where branch != into {
                        guard Landing.aheadCount(branch: branch, into: into, repo: project) > 0 else { continue }
                        let base = mergeBase(branch, into, in: project)
                        guard let conflicted = conflicts(between: branch, and: into, in: project),
                              !conflicted.isEmpty
                        else { continue }
                        if announce(conflicted, mine: branch, other: into, base: base) { announced += 1 }
                    }
                }

                // Phase two: pairs, but only when their change sets overlap —
                // disjoint branches cannot conflict. Abandoned branches sit
                // out: the vs-main phase above already covers them.
                let pairable = branches.filter { branch in
                    branch != into && (tipAge(branch, in: project, now: now) ?? 0) < pruneAfter
                }
                let found = pairs(of: pairable)
                let (selected, nextOffset) = window(of: found, offset: state.pairOffset[project] ?? 0, cap: maxPairs)
                state.pairOffset[project] = nextOffset
                if selected.count < found.count {
                    ledger.append(LedgerEntry(
                        at: now, kind: .note, project: project,
                        title: "radar.capped",
                        summary: "checked \(selected.count) of \(found.count) pairs, continues next sweep"
                    ))
                }
                for (first, second) in selected {
                    guard let base = mergeBase(first, second, in: project),
                          let filesA = changedFiles(from: base, to: first, in: project),
                          let filesB = changedFiles(from: base, to: second, in: project),
                          overlaps(filesA, filesB),
                          let conflicted = conflicts(between: first, and: second, in: project),
                          !conflicted.isEmpty
                    else { continue }
                    // One conflict, two warnings: the count says conflicts.
                    if announce(conflicted, mine: first, other: second, base: base) { announced += 1 }
                    announce(conflicted, mine: second, other: first, base: base)
                }
                return .done(announced: announced, pairs: selected.count)
            }
        } catch {
            Log.error("radar sweep failed: \(error.localizedDescription)")
            return .skipped(reason: "could not lock radar state")
        }
    }

    /// Every known project, for the drain and for `gentlemerge radar`.
    public static func sweepAll(projects: [String], paths: Paths, now: Date = Date(), ignoreThrottle: Bool = false) -> [(project: String, result: SweepResult)] {
        projects.map { ($0, sweep(project: $0, paths: paths, now: now, ignoreThrottle: ignoreThrottle)) }
    }

    // MARK: - Automatic-landing notes

    /// How often a branch that keeps failing to land may say so in the ledger.
    public static let autoNoteThrottle: TimeInterval = 30 * 60

    static func autoNoteKey(branch: String, project: String) -> String { "\(project)|\u{1f}\(branch)" }

    /// True when the caller should write the skip line down: first failure, or
    /// the last note is older than the throttle. Marks either way.
    public static func noteAutoSkip(branch: String, project: String, paths: Paths, now: Date = Date()) -> Bool {
        do {
            return try LockedFile.withExclusiveLock(paths.radar) {
                var state = loadState(paths: paths)
                defer { saveState(state, paths: paths, now: now) }
                let key = autoNoteKey(branch: branch, project: project)
                if let last = state.lastAutoNote[key], now.timeIntervalSince(last) < autoNoteThrottle {
                    return false
                }
                state.lastAutoNote[key] = now
                return true
            }
        } catch {
            Log.error("radar auto-note failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A landing clears its branch's note mark, so the next failure is worth
    /// writing down again immediately.
    public static func clearAutoNote(branch: String, project: String, paths: Paths) {
        do {
            try LockedFile.withExclusiveLock(paths.radar) {
                var state = loadState(paths: paths)
                state.lastAutoNote.removeValue(forKey: autoNoteKey(branch: branch, project: project))
                saveState(state, paths: paths)
            }
        } catch {
            Log.error("radar auto-note clear failed: \(error.localizedDescription)")
        }
    }
}
