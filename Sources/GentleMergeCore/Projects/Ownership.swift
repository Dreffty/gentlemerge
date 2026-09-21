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
    /// otherwise the HANDOFF.md section, exactly as before.
    public static func effective(project: String, paths: Paths) -> (ownership: Ownership, authority: Authority) {
        if let rules = loadPinned(paths: paths)[project], !rules.isEmpty {
            return (Ownership(rules: rules), .pinned)
        }
        return (from(handoff: ProjectRegistry.handoff(for: project, refreshingCommits: false)), .handoff)
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
    public func owner(of path: String) -> String? {
        rules.filter { Glob.matches($0.pattern, path) }
            .max { Glob.literalPrefix($0.pattern).count < Glob.literalPrefix($1.pattern).count }?
            .owner
    }

    public func render() -> String {
        rules.map { "- \($0.pattern) → \($0.owner)" }.joined(separator: "\n")
    }
}
