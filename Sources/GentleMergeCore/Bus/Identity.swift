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
        let project = ProjectRegistry.canonicalPath(for: cwd)
        let live = Presence.marks(paths: paths).filter { !$0.isExpired && $0.projectPath == project }
        if live.count == 1 { return Identity(label: safe(live[0].label), source: .presence) }
        if provider != .unknown { return Identity(label: AgentBus.label(for: provider), source: .provider) }
        return Identity(label: "you", source: .human)
    }

    /// Labels are `[A-Za-z0-9#-_.]{1,24}` (see SECURITY.md): anything else is
    /// stripped, overlong names are cut, and a name with nothing left in it
    /// becomes "agent" — an empty label would otherwise file presence marks
    /// and messages under nobody at all.
    public static func safe(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#-_."))
        let kept = String(String(value.unicodeScalars.filter { allowed.contains($0) }.map(Character.init)).prefix(24))
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
