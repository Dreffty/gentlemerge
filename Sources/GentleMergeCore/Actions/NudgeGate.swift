import Foundation

/// Whether it is safe, right now, to type into another agent's terminal — and
/// what exactly gets typed.
///
/// A hook only injects the bus into an agent's context when that agent takes a
/// turn. A session sitting idle at its prompt takes no turns, so "do not touch
/// that file, I am migrating it" waits there until a human types something.
/// `TerminalBridge` has always been able to push a line into another session;
/// this is the judgement that has to come with it.
///
/// Pure on purpose. Everything it looks at is passed in, so the rule that keeps
/// us out of a running turn can be tested without a terminal, without the app,
/// and without asking macOS for permission to drive one.
public enum NudgeGate {
    /// One nudge per session per ten minutes. Long enough that three agents all
    /// finishing at once cost one interruption instead of three, short enough
    /// that a genuinely new blocker half an hour later still gets through.
    public static let quietPeriod: TimeInterval = 10 * 60

    /// Why we did or did not type. The string goes to the ledger, never to the
    /// window: a nudge is plumbing, and a person who never asked for one should
    /// not be told about it.
    public enum Decision: Sendable, Equatable {
        case nudge
        /// Preferred over `.nudge`: the notice travels over the session's own
        /// socket, which arrives even while idle and never types into a tty.
        case nudgeSocket(path: String)
        case skipped(String)

        public var reason: String? {
            if case .skipped(let reason) = self { return reason }
            return nil
        }

        public var isSocket: Bool {
            if case .nudgeSocket = self { return true }
            return false
        }
    }

    /// The one question the app asks before pushing over the tty. A socket
    /// decision is never a tty decision: exactly one channel is ever chosen.
    public static func shouldNudge(
        message: AgentMessage,
        activity: AgentActivity,
        config: AppConfig,
        lastNudgedAt: Date?,
        now: Date
    ) -> Bool {
        decide(message: message, activity: activity, config: config, lastNudgedAt: lastNudgedAt, now: now) == .nudge
    }

    /// The same question with its answer written out, for the ledger.
    public static func decide(
        message: AgentMessage,
        activity: AgentActivity,
        config: AppConfig,
        lastNudgedAt: Date?,
        now: Date
    ) -> Decision {
        guard message.nudge == true else { return .skipped("no nudge was asked for") }
        guard config.allowNudges else { return .skipped("nudges are off") }

        // A broadcast has no addressee, and "everyone idle" is not an audience
        // — it is every terminal on the machine. Nudging is a thing you do to
        // somebody in particular.
        guard let to = message.to?.trimmingCharacters(in: .whitespaces), !to.isEmpty else {
            return .skipped("not addressed to anybody")
        }

        let me = AgentBus.label(for: activity.provider)
        guard addressee(to, reaches: me) else { return .skipped("not for this session") }
        // Your own words coming back at you are not news, and delivery drops
        // them for the same reason.
        guard message.from != me else { return .skipped("their own message") }

        // Scope matched the way a briefing matches it: a note pinned to one
        // project is only for the sessions in it, and a session whose project we
        // never learned is not evidence of a mismatch.
        if let scope = message.projectPath, let project = activity.projectPath, scope != project {
            return .skipped("another project")
        }

        // The socket first: it reaches a session without interrupting anything,
        // so unlike the tty it needs no `.idle` — only a verifiably live
        // process and the quiet period. When there is no socket, the rules
        // below decide about the terminal exactly as before.
        if let socket = activity.socketPath, !socket.isEmpty {
            guard Liveness.isProcessAlive(activity.pid) == true else { return .skipped("process is gone") }
            if let lastNudgedAt, now.timeIntervalSince(lastNudgedAt) < quietPeriod {
                return .skipped("nudged \(RelativeTime.compact(from: lastNudgedAt, to: now)) ago")
            }
            return .nudgeSocket(path: socket)
        }

        // The whole safety argument lives in this one line.
        //
        // `.working` is the obvious one: a turn is in flight, and text typed at
        // its prompt lands in the middle of somebody's thought.
        //
        // `.waiting` is the dangerous one, and the reason this is a whitelist
        // rather than "not working". A waiting session is stopped on a question
        // in its own terminal — very often a permission dialog — and whatever
        // gets typed there is an *answer* to it. Typing a notice into a "may I
        // run this command?" prompt would be GentleMerge approving tool calls on
        // its own, which is precisely the failure this project exists to avoid.
        //
        // `.ended` has nothing at the other end but a shell.
        guard activity.state == .idle else { return .skipped("recipient is \(activity.stateLabel)") }

        // `== true` and not `!= false`: unknown is not good enough here. Every
        // other reader treats a missing pid as "assume alive" because the cost
        // of being wrong is a stale line in a briefing; here the cost is typing
        // into whatever inherited that terminal after the agent left it.
        guard Liveness.isProcessAlive(activity.pid) == true else { return .skipped("process is gone") }

        #if os(macOS)
        guard let tty = activity.tty, !tty.isEmpty else { return .skipped("no terminal on record") }
        #endif

        if let lastNudgedAt, now.timeIntervalSince(lastNudgedAt) < quietPeriod {
            return .skipped("nudged \(RelativeTime.compact(from: lastNudgedAt, to: now)) ago")
        }

        #if os(macOS)
        return .nudge
        #else
        // No terminal injection on Linux; a future socket transport can opt in.
        return .skipped("no delivery channel on this platform")
        #endif
    }

    /// Whether a session calling itself `label` is inside the audience the note
    /// named. Exactly the rule that decides delivery, for the reason that makes
    /// the nudge honest: the line we type promises the note will be in their
    /// next briefing, so it may only be typed into a session that will actually
    /// be handed it.
    ///
    /// So `--to claude` reaches the director and any executor of it, and
    /// `--to claude#exec1` reaches neither anybody else nor the director — a
    /// subagent shares its director's terminal but not its audience, and the
    /// director's briefing will never carry that line. Today an activity's label
    /// is always the bare provider name and the `#` half of the rule is dormant
    /// here; it is written down anyway, so that the day a session reports a name
    /// of its own it is nudged by the same rule that briefs it.
    static func addressee(_ to: String, reaches label: String) -> Bool {
        AgentBus.addresses(to, label)
    }

    // MARK: - What gets typed

    /// The whole of it. A fixed sentence and a name — never the note.
    ///
    /// This is not a style choice. The addressee is an agent with tools, sitting
    /// at a prompt, and anything typed there is read as an instruction from its
    /// human. Forwarding another agent's text into it would be handing any
    /// message on the bus the power to make Claude do something. The content
    /// travels the way it always did: through the bus, into the briefing the
    /// hook injects on the turn this line provokes, scrubbed on the way.
    public static func text(from author: String) -> String {
        let line = "GentleMerge: new message from \(safeLabel(author)) — it will be in your next briefing"
        // Belt and braces: nothing that reaches here should be secret, but this
        // crosses into another agent's context and everything that does is
        // scrubbed first.
        return Redactor.scrub(line).text
    }

    /// The socket send threw — where, if anywhere, the notice goes instead.
    /// Back to the tty on macOS when the session is idle there (the socket
    /// never interrupts, and neither may the fallback), nowhere otherwise:
    /// a mid-turn session keeps the briefing as its channel, and Linux has no
    /// tty to fall back to.
    public static func fallsBackToTTY(activity: AgentActivity) -> Bool {
        #if os(macOS)
        return activity.state == .idle
        #else
        return false
        #endif
    }

    /// A sender's name is free text — `--from` takes whatever you type — so it
    /// is the one part of the line an attacker controls, and it lands at an
    /// agent's prompt. Letters, digits and the three characters a label really
    /// uses; everything else goes, and what is left is short enough that it
    /// cannot carry a sentence, let alone an instruction.
    static func safeLabel(_ author: String) -> String {
        let kept = author.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "#-_.".unicodeScalars.contains(scalar)
        }
        let label = String(String.UnicodeScalarView(kept)).prefix(24)
        return label.isEmpty ? "another agent" : String(label)
    }
}
