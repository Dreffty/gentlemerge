import Foundation

/// One line of the PreToolUse answer.
public struct AdviseNote: Sendable, Equatable {
    public var text: String
    /// Whether policy "deny" refuses the edit on this note. A claim and a
    /// request scope are decisions, so they deny; an ownership zone is a
    /// default, so it only ever warns.
    public var denies: Bool

    public init(text: String, denies: Bool) {
        self.text = text
        self.denies = denies
    }
}

/// The PreToolUse answer, decided purely: what the model sees *before* the
/// edit lands. The same rules as `PrecommitGate` (claims, ownership, request
/// scope), the same reaping — the gate at commit time must never surprise an
/// edit the advice allowed, and the structural reason this exists at all is
/// that claims are advisory until `git commit`: without this, two agents edit
/// the same file for twenty minutes and the second learns it at commit time,
/// when the work is already spent.
public enum Advise {
    public static func check(
        path: String,
        me: String,
        claims: [PathClaim],
        ownership: Ownership,
        activeRequest: AgentRequest? = nil,
        now: Date = Date(),
        presence: [Presence.PresenceMark] = [],
        isPIDAlive: (@Sendable (Int) -> Bool?)? = nil
    ) -> [AdviseNote] {
        let live: [PathClaim]
        if let isPIDAlive {
            let (kept, _) = PathClaims.reap(
                claims.filter { $0.label != me },
                presence: presence, isPIDAlive: isPIDAlive, now: now
            )
            live = kept + claims.filter { $0.label == me }
        } else {
            live = claims
        }
        var notes: [AdviseNote] = []
        for holder in live.filter({ $0.isLive(at: now) && $0.label != me && Glob.matches($0.pattern, path) }) {
            notes.append(AdviseNote(
                text: "⚠ " + ClaimRejection.plan(holder: holder, path: path, now: now),
                denies: true
            ))
        }
        if let owner = ownership.owner(of: path), owner != me {
            let mine = live.contains {
                $0.isLive(at: now) && $0.label == me && !$0.implicit && Glob.matches($0.pattern, path)
            }
            if !mine {
                notes.append(AdviseNote(
                    text: "ℹ `\(path)` is in \(owner)'s zone per HANDOFF.md Ownership."
                        + " Claim it explicitly (`gentlemerge claim --paths \(path)`) if you must edit it.",
                    denies: false
                ))
            }
        }
        if let activeRequest, !activeRequest.mayTouch.isEmpty,
           !activeRequest.mayTouch.contains(where: { Glob.matches($0, path) }) {
            notes.append(AdviseNote(
                text: "✖ `\(path)` is outside your delegated request \(activeRequest.id)"
                    + " scope (\(activeRequest.mayTouch.joined(separator: ", ")))."
                    + " Finish the request first or ask for a wider scope.",
                denies: true
            ))
        }
        return notes
    }
}
