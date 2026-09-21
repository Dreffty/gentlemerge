import Foundation

public enum BriefingMode: String, Sendable {
    /// SessionStart: everything relevant to start working.
    case full
    /// UserPromptSubmit: only what changed since the cursor. Empty string if nothing.
    case delta
}

/// Hard budget so the per-turn injection can never balloon.
/// ~4 chars/token → 1200 chars ≈ 300 tokens.
public enum BriefingBudget {
    public static let deltaMaxChars = 1200
    public static let fullMaxChars = 4000
    public static let maxLinesPerSection = 6
    /// One peer message never costs more than this per line, however much log
    /// somebody pastes into it.
    public static let maxCharsPerLine = 500
}

/// What this reader touches: their live claim patterns plus the scope of
/// their in-progress requests. Empty means no signal — a reader with no
/// footprint gets the whole picture, never a filtered one.
public enum BriefingRelevance {
    public static func scope(myClaimPatterns: [String], mayTouch: [String]) -> [String] {
        (myClaimPatterns + mayTouch).filter { !$0.isEmpty }
    }

    /// Whether somebody else's claim can matter to this reader: the patterns
    /// may overlap. Conservative by construction — `mayOverlap` answers
    /// "could these share a file", never "do they".
    public static func touchesScope(pattern: String, scope: [String]) -> Bool {
        scope.isEmpty || scope.contains { Glob.mayOverlap($0, pattern) }
    }

    /// N out-of-scope broadcasts from one sender, folded to one line. The
    /// notes stay on the bus for `brief --as` — this spends no tokens on
    /// them, it does not delete them.
    public static func coalescedLine(from sender: String, count: Int, me: String) -> String {
        "- \(sender): \(count) note\(count == 1 ? "" : "s") outside your scope"
            + " — `gentlemerge brief --as \(me)` for the full text"
    }
}

/// Pure renderer. Takes already-filtered inputs, returns markdown.
/// Keeping it pure keeps it testable without disk.
public struct BriefingRenderer: Sendable {
    public struct Section: Sendable {
        public var heading: String
        public var lines: [String]
        public init(heading: String, lines: [String]) { self.heading = heading; self.lines = lines }
        public var isEmpty: Bool { lines.isEmpty }
    }

    /// Peer text enters a briefing as data, never as structure. Two rules, both
    /// cheap: a line that would become a heading is escaped (`\##` renders as
    /// literal text, so a message cannot spoof sections or smuggle an
    /// `## Ownership` grant into the injected context), and no line survives
    /// past `maxCharsPerLine` (a pasted log must not eat the turn budget).
    /// Headings built by our own code never pass through here.
    public static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            var line = String(raw)
            if line.count > BriefingBudget.maxCharsPerLine {
                line = String(line.prefix(BriefingBudget.maxCharsPerLine)) + "…"
            }
            if let hash = line.firstIndex(of: "#"),
               line[..<hash].allSatisfy({ $0 == " " || $0 == "\t" }) {
                line.insert(contentsOf: "\\", at: hash)
            }
            return line
        }.joined(separator: "\n")
    }

    public static func render(mode: BriefingMode, sections: [Section]) -> String {
        let nonEmpty = sections.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }   // delta with nothing new → inject nothing

        var out: [String] = []
        out.append(mode == .full ? "# GentleMerge — briefing" : "# GentleMerge — since last turn")
        for s in nonEmpty {
            out.append("## \(s.heading)")
            let shown = Array(s.lines.prefix(BriefingBudget.maxLinesPerSection))
            out.append(contentsOf: shown.map { "- \($0)" })
            let hidden = s.lines.count - shown.count
            if hidden > 0 { out.append("- …\(hidden) more; run `gentlemerge brief`") }
        }
        let text = out.joined(separator: "\n")
        return cap(text, mode: mode)
    }

    /// Budget cap for an already-rendered briefing.
    ///
    /// ADAPTED: the plan renders the whole briefing through `render(sections:)`,
    /// but the existing briefing builds its lines itself (peer list, messages)
    /// and already caps those by count. This is what that renderer applies so
    /// the per-turn injection can never balloon: delta caps tighter than full,
    /// because delta is paid for on every single turn.
    ///
    /// `keeping` exempts the first lines from the cut: conflict-class news
    /// enters even when the rest of the budget is spent.
    public static func cap(_ text: String, mode: BriefingMode, keeping firstLines: Int = 0) -> String {
        truncate(text, to: mode == .full ? BriefingBudget.fullMaxChars : BriefingBudget.deltaMaxChars, keeping: firstLines)
    }

    static func truncate(_ text: String, to cap: Int, keeping firstLines: Int = 0) -> String {
        guard text.count > cap else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard firstLines < lines.count else { return text }
        let kept = lines.prefix(firstLines).joined(separator: "\n")
        lines.removeFirst(firstLines)
        // Untouched path when nothing is kept: byte-identical to the old cut.
        let budget = kept.isEmpty ? cap : cap - kept.count - 1
        let rest = lines.joined(separator: "\n")
        guard rest.count > budget else { return text }
        let cut = String(rest.prefix(max(budget, 0)))
        // cut at the last complete line so we never emit half a bullet
        let safe = cut.lastIndex(of: "\n").map { String(cut[..<$0]) } ?? cut
        let tail = "\n- …truncated; run `gentlemerge brief` for the full picture"
        return kept.isEmpty ? safe + tail : kept + "\n" + safe + tail
    }
}
