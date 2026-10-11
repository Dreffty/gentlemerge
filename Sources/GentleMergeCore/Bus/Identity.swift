import Foundation

/// Local caller identity. Environment identity is a local convention, not
/// authentication against processes able to modify their own environment.
public struct Identity: Sendable, Equatable {
    public enum Source: String, Sendable { case env, worktree, presence, provider, human }
    public let label: String
    public let source: Source
    public var verified: Bool { source == .env || source == .worktree }

    public static func resolve(cwd: String, provider: AgentProvider, paths: Paths,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Identity {
        if let label = environment["GENTLEMERGE_LABEL"], !label.isEmpty {
            return Identity(label: safe(label), source: .env)
        }
        if let label = WorktreeLabel.read(cwd: URL(fileURLWithPath: cwd)) {
            return Identity(label: safe(label), source: .worktree)
        }
        // A session's executors sign with the name they were given — the same
        // convention `AgentBus.label` has always honored. Weak on purpose: it
        // is only a way to spell yourself, never proof of who you are.
        if let name = environment["GENTLEMERGE_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return Identity(label: safe(name), source: .presence)
        }
        // There used to be a branch here that adopted the label of the single
        // live presence mark in the project. It is gone, deliberately: a mark
        // belongs to a session, not to the directory resolving identity, so
        // "exactly one agent is alive here" is evidence about *that* agent and
        // none at all about the one asking. The result was a brand-new agent
        // becoming the agent already working — it claimed paths as `alice`,
        // renewed `alice`'s claim instead of conflicting with it, overwrote
        // `alice`'s presence mark with its own heartbeat (so `who` stopped
        // listing the real one), and could never be addressed separately
        // (audit 2026-10-08). With nothing to identify us we answer "you",
        // which is not anybody's name and so cannot be mistaken for theirs.
        if provider != .unknown { return Identity(label: AgentBus.label(for: provider), source: .provider) }
        return Identity(label: "you", source: .human)
    }

    /// Labels are `[A-Za-z0-9#-_.]{1,24}` (see SECURITY.md): anything else is
    /// stripped, overlong names are cut, and a name with nothing left in it
    /// becomes "agent" — an empty label would otherwise file presence marks
    /// and messages under nobody at all.
    ///
    /// ASCII **explicitly**, never `CharacterSet.alphanumerics`: that is the
    /// Unicode category (L*, M*), so `safe("c\u{2162}aude")` kept U+2162 (ROMAN
    /// NUMERAL FIFTY) and produced a label that renders identically to `claude`
    /// but fails every `to == "claude"` route and every claim comparison. A
    /// homoglyph is an impersonation that survives the filter this function's
    /// own docstring claims to implement (audit Tier 5 #22).
    public static func safe(_ value: String) -> String {
        let isAllowed: (UInt8) -> Bool = { byte in
            (byte >= 48 && byte <= 57)    // 0-9
                || (byte >= 65 && byte <= 90)   // A-Z
                || (byte >= 97 && byte <= 122)  // a-z
                || byte == 35 || byte == 45 || byte == 95 || byte == 46 // # - _ .
        }
        let kept = String(String(decoding: value.utf8.filter(isAllowed).map { $0 }, as: UTF8.self)
            .prefix(24))
        return kept.isEmpty ? "agent" : kept
    }

    public static func reconcile(explicit: String?, resolved: Identity) throws -> Identity {
        guard let explicit, !explicit.isEmpty, safe(explicit) != resolved.label else { return resolved }
        if resolved.verified {
            throw IdentityError.impersonation(claimed: explicit, actual: resolved.label)
        }
        return Identity(label: safe(explicit), source: resolved.source == .human ? .human : .provider)
    }
}

public enum IdentityError: Error, Equatable, CustomStringConvertible {
    case impersonation(claimed: String, actual: String)
    public var description: String {
        switch self {
        case .impersonation(let claimed, let actual):
            return "this worktree is '\(actual)'; refusing to speak as '\(claimed)'"
        }
    }
}
