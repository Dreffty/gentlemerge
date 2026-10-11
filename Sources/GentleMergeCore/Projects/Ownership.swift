import Foundation

/// Default zones per agent, declared in HANDOFF.md:
///   ## Ownership
///   - lib/store/** → claude
///   - assets/** → codex
///   - lib/data/** → hermes
/// A live PathClaim always wins over ownership (claims are explicit and fresh).
public struct Ownership: Sendable, Equatable {
    public struct Rule: Sendable, Equatable, Codable {
        public let pattern: String
        public let owner: String
        public init(pattern: String, owner: String) {
            self.pattern = pattern
            self.owner = owner
        }
    }

    /// Where the rules in force came from. Pinned lives in the home, written
    /// by an explicit human command and audited in the ledger; handoff is the
    /// HANDOFF.md section in the working tree — convenient, visible, and
    /// editable by the very agent being judged, so never authoritative.
    public enum Authority: String, Sendable {
        case pinned
        case handoff
    }

    public var rules: [Rule]
    public static let heading = "Ownership"

    public init(rules: [Rule]) {
        self.rules = rules
    }

    /// Hand-written markdown: humans type "→", "->" and ":" for the same
    /// separator, and all three mean the same thing.
    public static func parse(section body: String) -> Ownership {
        var rules: [Rule] = []
        for raw in body.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") else { continue }
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
            for separator in ["→", "->", ":"] {
                if let range = line.range(of: separator) {
                    let pattern = line[..<range.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                    let owner = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !pattern.isEmpty, !owner.isEmpty {
                        rules.append(Rule(pattern: pattern, owner: owner))
                    }
                    break
                }
            }
        }
        return Ownership(rules: rules)
    }

    /// Sections someone else added are kept verbatim in the handoff file, so
    /// ownership travels with the repo without us ever eating their work.
    public static func from(handoff: ProjectHandoff) -> Ownership {
        guard let section = handoff.extraSections.first(where: {
            $0.heading.caseInsensitiveCompare(heading) == .orderedSame
        }) else { return Ownership(rules: []) }
        return parse(section: section.body)
    }

    // MARK: - Pinned authority

    /// File in the home holding the pinned zones per project. A local file any
    /// agent could rewrite — which is why every write below appends
    /// `ownership.changed` to the ledger with before and after: tampering
    /// leaves a signed trail instead of a silent grant.
    static func storeURL(paths: Paths) -> URL {
        paths.home.appendingPathComponent("ownership.json")
    }

    static func loadPinned(paths: Paths) -> [String: [Rule]] {
        guard let data = try? Data(contentsOf: storeURL(paths: paths)),
              let store = try? JSONCoding.decoder().decode([String: [Rule]].self, from: data)
        else { return [:] }
        return store
    }

    static func savePinned(_ store: [String: [Rule]], paths: Paths) throws {
        try AtomicFile.write(try JSONCoding.encoder(pretty: true).encode(store), to: storeURL(paths: paths))
    }

    /// The rules in force plus where they came from. Pinned wins when present;
    /// otherwise the HANDOFF.md section.
    ///
    /// `handoffIsStaged` is what makes the `Authority` doc comment true rather
    /// than aspirational. HANDOFF.md is a tracked file that the committing
    /// agent is itself editing, so treating its zones as authoritative let one
    /// agent stage an invasion of somebody's zone *and* the deletion of that
    /// zone's declaration in a single commit: the gate saw no zone, the commit
    /// landed, and the declaration was then gone from history for everybody —
    /// the next agent found the zone free (audit 2026-10-07).
    ///
    /// Narrowed to the threat it names (audit 2026-10-08): what must not rule
    /// is a zone the commit is *rewriting*, not any commit that happens to
    /// touch the file. Disarming on the file's presence switched the whole
    /// ownership layer off for the ordinary case — the task list lives in the
    /// same HANDOFF.md, `AGENT_PROTOCOL.md` tells every agent to write tasks
    /// there, and the tool itself rewrites the Recent-commits section, so the
    /// normal "I finished something, let me record it" commit sailed past every
    /// zone unchecked. Now the staged zones are compared with the ones at HEAD:
    /// unchanged (the overwhelmingly common case) keeps enforcing, and only a
    /// commit that actually rewrites them falls back to the pinned store, which
    /// lives in the home and cannot be reached from the worktree. Pinning stays
    /// opt-in; this just stops the unverified source from ruling when it is
    /// being rewritten under the judge's feet.
    public static func effective(
        project: String,
        paths: Paths,
        handoffIsStaged: Bool = false
    ) -> (ownership: Ownership, authority: Authority) {
        if let rules = loadPinned(paths: paths)[project], !rules.isEmpty {
            return (Ownership(rules: rules), .pinned)
        }
        let current = from(handoff: ProjectRegistry.handoff(for: project, refreshingCommits: false))
        guard handoffIsStaged else { return (current, .handoff) }
        // Fail closed: an answer we could not get is not permission.
        guard let atHead = rulesAtHead(project: project), atHead == current else {
            return (Ownership(rules: []), .handoff)
        }
        return (current, .handoff)
    }

    /// The zones as `HEAD` declares them, or nil when git could not say.
    ///
    /// `HEAD`, not the index: what is staged is about to be compared against
    /// the revision the current working tree grew from, and that is the one the
    /// last agent committed. nil (unborn HEAD, no repository, unreadable file)
    /// reads as "the zones are being rewritten" — the caller's safe direction.
    static func rulesAtHead(project: String) -> Ownership? {
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "show", "HEAD:\(handoffRelativePath)"],
            in: URL(fileURLWithPath: project),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded else { return nil }
        // Parse through the same path as the working tree, so a zone the
        // markdown round trip would drop is seen as dropped here too.
        return parse(
            section: HandoffMarkdown.parse(output.stdout, projectPath: project)
                .extraSections.first { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }?.body ?? ""
        )
    }

    /// The handoff file as git would name it in a diff — the one form the
    /// caller compares against a staged path.
    public static var handoffRelativePath: String {
        "\(ProjectHandoff.directoryName)/\(ProjectHandoff.fileName)"
    }

    /// Copy the HANDOFF.md zones into the pinned authority. Returns what was
    /// pinned, so the caller can say so — and the ledger can witness it.
    @discardableResult
    public static func pin(project: String, paths: Paths, by author: String) throws -> [Rule] {
        let rules = from(handoff: ProjectRegistry.handoff(for: project, refreshingCommits: false)).rules
        var store = loadPinned(paths: paths)
        let before = store[project] ?? []
        store[project] = rules
        try savePinned(store, paths: paths)
        Ledger(url: paths.ledger).append(LedgerEntry(
            at: Date(), kind: .note, project: project,
            title: "ownership.changed",
            summary: "\(author) pinned \(rules.count) rule(s) (was \(before.count))"
        ))
        return rules
    }

    /// Add or remove one rule in the pinned authority, audited the same way.
    public static func setRule(pattern: String, owner: String?, project: String, paths: Paths, by author: String) throws -> [Rule] {
        var store = loadPinned(paths: paths)
        var rules = store[project] ?? []
        rules.removeAll { $0.pattern == pattern }
        if let owner { rules.append(Rule(pattern: pattern, owner: owner)) }
        store[project] = rules
        try savePinned(store, paths: paths)
        Ledger(url: paths.ledger).append(LedgerEntry(
            at: Date(), kind: .note, project: project,
            title: "ownership.changed",
            summary: "\(author) \(owner.map { "set \(pattern) → \($0)" } ?? "removed \(pattern)")"
        ))
        return rules
    }

    /// Most specific rule wins (longest literal prefix).
    /// The most specific matching zone wins.
    ///
    /// "Specific" is `Glob.specificity`, not the literal prefix alone: ranking by
    /// the prefix threw away everything after the first wildcard, so a pattern
    /// naming an exact file could lose to one naming a directory, and two
    /// different patterns could tie and be separated only by their order in the
    /// file (audit Tier 4 #20). Ties keep the earliest declaration, as before.
    public func owner(of path: String) -> String? {
        rules.filter { Glob.matches($0.pattern, path) }
            .max {
                let a = Glob.specificity(of: $0.pattern)
                let b = Glob.specificity(of: $1.pattern)
                if a.longestRun != b.longestRun { return a.longestRun < b.longestRun }
                if a.literalCount != b.literalCount { return a.literalCount < b.literalCount }
                return a.prefix < b.prefix
            }?
            .owner
    }

    public func render() -> String {
        rules.map { "- \($0.pattern) → \($0.owner)" }.joined(separator: "\n")
    }
}
