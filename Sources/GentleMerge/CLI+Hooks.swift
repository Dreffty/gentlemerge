import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    /// What a hook prints back into its own session: where the project stood,
    /// and what the other agents are doing right now.
    ///
    /// Silence is the default. Injecting the same thing on every turn would burn
    /// context and teach the model to ignore it.
    static func sessionContext(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)

        var event = "SessionStart"
        var sessionSource: String?
        var sessionID: String?
        // No `--provider` means we do not know who this is, and guessing Claude
        // would hand a Claude session's messages to whoever ran the hook.
        var provider: AgentProvider?

        if let payloadPath = value(after: "--payload", in: arguments),
           let data = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)),
           let payload = try? JSONCoding.decoder().decode(JSONValue.self, from: data) {
            event = payload.string("hook_event_name") ?? event
            sessionID = payload.string("session_id")
            sessionSource = payload.string("source")
        }
        if let name = value(after: "--provider", in: arguments) {
            provider = AgentProvider(rawValue: name) ?? .unknown
        }

        // Who is reading: the label, resolved exactly as `brief --as` and every
        // other command resolve it — env label, then this checkout's worktree
        // label, then the provider as a last resort. Deriving `me` from the
        // *provider* alone meant every Claude Code session called itself
        // "claude", so `say --to hermes` (the label `project init --label`
        // creates and AGENT_PROTOCOL.md tells agents to use) was never
        // delivered to anybody, and two Claude worktrees each read the other's
        // mail. The hook has already resolved
        // GENTLEMERGE_LABEL — it is in the environment and in the envelope.
        let identity: Identity
        do {
            identity = try Identity.reconcile(
                explicit: value(after: "--as", in: arguments) ?? value(after: "--from", in: arguments),
                resolved: Identity.resolve(
                    cwd: checkoutDirectory(arguments, allowPositional: false),
                    provider: provider ?? .unknown,
                    paths: paths))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }

        // Where the project stands *now*, at the moment the session begins: this hook
        // is the one place that knows. Draining the spooled event later takes HEAD at
        // that later time (see `SessionRegistry.recordBaseline`).
        if event == "SessionStart", let sessionID, sessionSource == nil || ["startup", "resume"].contains(sessionSource!) {
            var registry = SessionRegistry(url: paths.sessions)
            registry.recordBaseline(
                id: sessionID, provider: provider ?? .unknown,
                projectPath: checkoutDirectory(arguments, allowPositional: false), at: Date(),
                label: identity.verified ? identity.label : nil)
        }

        // The briefing below reads what has been drained. With the app running
        // that lags by seconds; without it (Linux, or the app quit) nothing
        // drained between one `brief` and the next, so a turn's delta never
        // showed what the others had started and watches never fired.
        // A small backlog is drained here, waiting at most
        // a second for the lock; a big one is left to a command that no hook
        // timeout can cut off halfway.
        let spool = SpoolStore(paths: paths)
        if spool.runningAppPID() == nil, spool.pendingCount() <= 100 {
            InboxModel.drainHeadless(paths: paths, patience: 1)
        }

        var blocks: [String] = []

        // The handoff is worth its tokens once, at the start of a session.
        if event == "SessionStart",
           let handoff = ProjectRegistry.sessionContext(
               for: directory,
               claims: TaskClaims(paths: paths).active(for: directory)
           ) {
            blocks.append(handoff)
        }

        // The bus routes by label; the provider is only how this end happens to
        // spell it, so the translation belongs here and not inside the bus.
        //
        // SessionStart gets the full briefing; every other turn gets the delta —
        // only what changed since the last injection, capped, and empty when
        // there is nothing new. That is the whole point of the mode: the hook
        // already refuses to print an empty block, so a delta with no news
        // injects nothing at all and costs the session zero tokens.
        //
        // `--mode` overrides the event: `session-context --mode delta` is how
        // you ask what a turn would cost without starting a session for it.
        let briefMode: BriefingMode
        switch value(after: "--mode", in: arguments) {
        case "full": briefMode = .full
        case "delta": briefMode = .delta
        case let unknown?:
            FileHandle.standardError.write(Data("unknown --mode \"\(unknown)\" — say full or delta\n".utf8))
            return 64
        default: briefMode = event == "SessionStart" ? .full : .delta
        }
        // Who the reader is, in the two ways a mark can say it: the agent's
        // pid (the hook hands it over) and the session id. Without them a
        // session whose label did not match its own mark was told about itself.
        let environment = ProcessInfo.processInfo.environment
        if let briefing = AgentBus(paths: paths).briefing(
            sessionID: sessionID,
            me: identity.label,
            project: directory,
            mode: briefMode,
            persistCursor: true,
            selfPID: environment[Presence.pidEnvironmentKey].flatMap(Int.init),
            selfSessionID: sessionID ?? environment[Presence.sessionEnvironmentKey]
        ) {
            blocks.append(briefing)
        }

        // The coordination cost, recorded whether anything was handed out or
        // not: an empty delta is still a turn, and "3 non-empty of 6" only
        // means something when the 6 are counted too.
        let injected = blocks.joined(separator: "\n\n")
        Ledger(url: paths.ledger).append(LedgerEntry(
            at: Date(),
            kind: .note,
            sessionID: sessionID,
            project: directory,
            title: Stats.eventTitle,
            mode: briefMode == .full ? "full" : "delta",
            chars: injected.count
        ))

        guard !blocks.isEmpty else { return 0 }

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": event,
                "additionalContext": blocks.joined(separator: "\n\n"),
            ]
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return 0 }

        print(text)
        return 0
    }

    /// What the coordination costs: hook injections recorded in the ledger,
    /// counted up. Tokens are chars/4, always said as an estimate.
    static func stats(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        if isSet("--value", in: arguments) {
            print(Stats.valueLine(paths: paths))
            return 0
        }
        if let session = value(after: "--session", in: arguments) {
            let s = Stats.summary(paths: paths, session: session)
            print("session \(session): \(s.turns) briefings (\(s.nonEmpty) non-empty)"
                + " · ≈ \(s.estTokens) tokens total · ≈ \(s.avgPerTurn) tokens/turn (estimate: chars/4)")
            return 0
        }
        print(Stats.summaryLine(paths: paths))
        return 0
    }

    /// `advise` — the PreToolUse hook on the editing tools calls this with the
    /// agent's raw payload, and the answer is what the model sees *before* the
    /// edit lands.
    ///
    /// Checks path claims (explicit and implicit) plus HANDOFF.md Ownership for
    /// tool_input.file_path. Output shape follows Claude Code's hook JSON:
    ///   off   → print nothing
    ///   warn  → permissionDecision "allow" + additionalContext (default)
    ///   deny  → permissionDecision "deny" + reason (the agent must re-plan)
    /// Never blocks by accident: with no file, no project, and no news, the
    /// answer is silence and exit 0, same as every other path in the bridge.
    static func advise(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // The human escape hatch covers the edit-time advice too: skipped
        // means silent, the same as every other path in the bridge.
        guard !EscapeHatch.isActive() else { return 0 }
        let projectDirectory_ = projectDirectory(arguments, allowPositional: false)
        let checkout = checkoutDirectory(arguments, allowPositional: false)
        if let claimed = value(after: "--from", in: arguments) ?? value(after: "--as", in: arguments) {
            do {
                _ = try Identity.reconcile(explicit: claimed,
                    resolved: Identity.resolve(cwd: checkoutDirectory(arguments, allowPositional: false), provider: .unknown, paths: paths))
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
            }
        }

        guard let payloadPath = value(after: "--payload", in: arguments),
              let data = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)),
              let payload = try? JSONCoding.decoder().decode(JSONValue.self, from: data)
        else { return 0 }

        guard let file = payload["tool_input"]?.string("file_path")
            ?? payload["tool_input"]?.string("notebook_path"),
            !file.isEmpty
        else { return 0 }

        // Who is editing? The label of this checkout, resolved exactly as the
        // commit-time gate resolves it (env, then the worktree's own
        // `gentlemerge.label`, then the provider). The old code read the label
        // from the *repository root*, which in the documented five-worktrees
        // layout is the main checkout — so a worktree was judged as whoever
        // owned that one, and an agent editing its own zone heard nothing
        // while a claim held by somebody else was silently skipped as "mine".
        let provider = value(after: "--provider", in: arguments)
            .flatMap(AgentProvider.init(rawValue:))
        let me = WorktreeLabel.read(cwd: URL(fileURLWithPath: checkout))
            ?? provider.map(AgentBus.label(for:))
            ?? "agent"

        // Claims are per repository; the paths inside them are relative to the
        // *checkout* the hook is running in, not to the main tree. The hook
        // names an absolute path inside this worktree, and relativising it
        // against the canonical repository root produced `../wt-bob/lib/x.dart`
        // — which no glob can match, so the advice was silence for every agent
        // working in a worktree, i.e. exactly the layout the README teaches.
        // `recordImplicitPathClaims` already resolves the
        // checkout correctly; this now agrees with it.
        let project = ProjectRegistry.canonicalPath(for: checkout)
        let rel = ToolInputFormatter.relativeToCheckout(file, checkout: checkout)
            ?? ToolInputFormatter.relativePath(file, cwd: checkout)
                .trimmingCharacters(in: CharacterSet(charactersIn: "~"))

        // The same rules as the commit-time gate, decided before the edit
        // lands: a surprise at commit time is twenty minutes of wasted work.
        let claims = PathClaims(paths: paths).live(project: project)
        // Same reasoning as the commit-time gate: the file being edited cannot
        // also be the authority judging it.
        let ownership = Ownership.effective(
            project: project,
            paths: paths,
            handoffIsStaged: rel == Ownership.handoffRelativePath
        ).ownership
        let scopedAdvise = Requests(paths: paths).inProgress(assignedTo: me, project: project)
        let notes = Advise.check(
            path: rel,
            me: me,
            claims: claims,
            ownership: ownership,
            activeRequests: scopedAdvise,
            presence: Presence.marks(paths: paths),
            isPIDAlive: { Liveness.isProcessAlive($0, seenAt: $1) }
        )
        guard !notes.isEmpty else { return 0 }

        let scrubbed = Redactor.scrub(notes.map(\.text).joined(separator: "\n"))
        let text = scrubbed.text
        let policy = AppConfig.load(from: paths.config).claimsPolicy
        switch policy {
        case "off":
            return 0
        case "deny" where notes.contains(where: \.denies):
            // The refusal reason is the only part of a deny the model is shown,
            // so it carries the whole note.
            let output: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": text,
                ]
            ]
            printJSON(output)
        default:
            let output: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "additionalContext": text,
                ]
            ]
            printJSON(output)
        }
        let ledger = Ledger(url: paths.ledger)
        ledger.append(LedgerEntry(
            at: Date(),
            kind: .note,
            project: project,
            title: "advise",
            summary: "\(rel): \(notes.count) note(s), policy \(policy)"
        ))
        return 0
    }

    static func printJSON(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return }
        print(text)
    }
}
