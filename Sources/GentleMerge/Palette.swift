#if os(macOS)
import GentleMergeCore
import SwiftUI

/// One color means one thing, everywhere in the app:
///
/// - status: green working, orange waiting on you, red urgent or failing;
/// - who: purple Claude, teal Codex, blue you — and blue for an idle agent,
///   because idle means the next move is yours.
///
/// Everything else is primary or secondary text. Tertiary is not used for
/// anything you need to read: it measured 1.9:1 on white and 2.3:1 on the dark
/// window background, against the 4.5:1 text needs (`color.md` › Inclusive
/// color, `accessibility.md`).
extension AgentActivity.State {
    var tint: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .blue
        case .ended: return .secondary
        }
    }
}

enum Palette {
    /// The colour of whoever wrote a note — the same one their sessions use.
    static func tint(forAuthor author: String) -> Color {
        switch author {
        case "you": return .blue
        case "claude": return .purple
        case "codex": return .teal
        case "hermes": return .pink
        default: return .secondary
        }
    }

    static func tint(for provider: AgentProvider) -> Color {
        switch provider {
        case .claudeCode: return .purple
        case .codex: return .teal
        case .unknown: return .secondary
        }
    }
}
#endif
