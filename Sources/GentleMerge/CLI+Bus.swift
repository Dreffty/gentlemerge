import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - The bus between agents

    /// Leave a note for the other agents. They read it on their next turn.
    static func say(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let bus = AgentBus(paths: paths)
        let identity: Identity
        do { identity = try Identity.reconcile(explicit: value(after: "--from", in: arguments),
            // The *checkout*, not the project: `gentlemerge.label` is per worktree
            // (`extensions.worktreeConfig`), so asking the canonical repository
            // root answered with the main checkout's label and every worktree
            // signed as whoever owned that one. A note from hermes filed under
            // `from: claude` was dropped by the recipient's own `from != me`
            // filter, and `say --done` buried the other agent's blockers.
            // Every other command already used the checkout.
            resolved: Identity.resolve(cwd: checkoutDirectory(arguments, allowPositional: false), provider: .unknown, paths: paths))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }
        // Scoped to the project you are standing in, because that is what a note
        // left by an agent is almost always about — and the sessions working
        // somewhere else pay context for every word of it. `--global` is the
        // escape hatch for the few things that really are everybody's business.
        let scoped = isSet("--global", in: arguments) ? nil : projectDirectory(arguments, allowPositional: false)

        let author = identity.label
        if isSet("--done", in: arguments) { return done(bus: bus, author: author, scope: scoped) }

        // `--to` with nothing after it used to mean everyone: a note meant for one
        // agent went to all of them.
        for flag in ["--to", "--to-branch"] where isSet(flag, in: arguments) {
            guard let named = value(after: flag, in: arguments),
                  !named.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                FileHandle.standardError.write(Data(
                    "\(flag) needs a name. Without it the note would go to everyone, which is not what you asked for.\n".utf8))
                return 64
            }
        }

        let text = positional(arguments).joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let usage = "usage: gentlemerge say \"...\" [--to claude|codex|hermes] [--to-branch name]\n"
                + "                          [--project dir] [--global] [--replaces handle]\n"
                + "                          [--kind fyi|update|urgent|handoff] [--urgent] [--fyi] [--nudge]\n"
                + "                          [--attach file] ...\n"
                + "       gentlemerge say --done            take back your notes in this project\n"
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }

        guard let kind = messageKind(in: arguments) else {
            if value(after: "--kind", in: arguments) == nil {
                FileHandle.standardError.write(Data("say: --urgent and --fyi contradict each other — pick one\n".utf8))
                return 64
            }
            // A resolve carries the id of what it buries, which is not something
            // you can type — that is why it is not on this list.
            let complaint = "unknown kind \"\(value(after: "--kind", in: arguments) ?? "")\""
                + " — say fyi, update, urgent or handoff"
                + " (to take a note back, `gentlemerge say --done`)\n"
            FileHandle.standardError.write(Data(complaint.utf8))
            return 64
        }

        // Resolved before anything is written: a correction that names a note
        // nobody can find is worse than no correction, because it posts anyway
        // and leaves the wrong one standing next to it.
        var replaces: String?
        if let wanted = value(after: "--replaces", in: arguments) {
            let candidates = bus.messages(matching: wanted)
            guard let target = candidates.first, candidates.count == 1 else {
                let complaint = candidates.isEmpty
                    ? "no note here answers to \"\(wanted)\" — `gentlemerge show \(wanted)` says the same thing, at more length\n"
                    : "\"\(wanted)\" names \(candidates.count) notes; say more of the id\n"
                FileHandle.standardError.write(Data(complaint.utf8))
                return 64
            }
            replaces = target.id
        }

        // Every file goes in before a word of the note does. A rejected
        // attachment must not leave a message behind promising a report that
        // never arrived — and the sender, who is an agent with a turn to
        // finish, gets told once and gets told why.
        let attachments: [Attachment]
        do {
            let store = ArtifactStore(paths: paths)
            attachments = try values(after: "--attach", in: arguments).map { argument in
                try store.store(contentsOf: URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }

        // The flag travels; the push does not happen here. This process is a
        // hook or a shell one-liner: it has no Automation permission of its own
        // (macOS grants that per binary and per calling context), and it cannot
        // know whether the addressee is mid-turn or sitting on a permission
        // dialog. The app knows both, so the app decides — see `NudgeGate`.
        let message = AgentMessage(
            from: author,
            to: value(after: "--to", in: arguments),
            projectPath: scoped,
            text: text,
            kind: kind,
            nudge: isSet("--nudge", in: arguments) ? true : nil,
            attachments: attachments.isEmpty ? nil : attachments,
            replacesID: replaces,
            toBranch: value(after: "--to-branch", in: arguments),
            verified: identity.verified
        )
        let result: Redactor.Result
        do { result = try bus.send(message) }
        catch {
            // Said as plainly as the success: the other agents were NOT told.
            FileHandle.standardError.write(Data(
                "Not sent — the message log could not be written (\(error.localizedDescription)). See `gentlemerge doctor`.\n".utf8))
            return 1
        }

        if result.isSuppressed {
            print("Withheld — that was almost entirely \(result.summary). Nothing useful was shared.")
            return 1
        }
        // Now that scope is a choice, "sent" on its own no longer tells you who
        // is going to read it — and now that a note expires, how long for.
        let audience = "\(message.to ?? "every agent") \(message.projectName.map { "in \($0)" } ?? "in every project")"
        let life = kind == .update ? "" : " (\(kind.rawValue), \(hours(kind.timeToLive))h)"
        let named = message.toBranch.map { " on branch \($0)" } ?? ""
        let corrected = replaces == nil ? "" : ", replacing the earlier note"
        if result.didRedact {
            print("Sent as #\(message.handle) to \(audience)\(named)\(life)\(corrected), with \(result.summary) taken out:")
            print(result.text)
        } else {
            print("Sent as #\(message.handle) to \(audience)\(named)\(life)\(corrected): \(text)")
        }
        // The same line the receiving agent will read, so the sender can see
        // what it actually shared: a path, a size, and — for anything that did
        // not decode as text — the fact that nobody scrubbed it.
        let store = ArtifactStore(paths: paths)
        for attachment in attachments {
            print(attachment.line(at: store.displayPath(for: attachment)))
        }

        // Said plainly because a nudge that quietly does nothing is worse than
        // no nudge at all: it is off by default, and it is one fixed line of
        // notice — never a word of what you just wrote.
        if message.nudge == true {
            print(
                "Nudge requested. Nothing is typed unless the app is running, nudges are on, and "
                    + "\(message.to ?? "the agent you named") is idle — and then one fixed line of "
                    + "notice, never the note itself."
            )
        }
        return 0
    }

    /// `--urgent` and `--fyi` are the two you reach for mid-sentence; `--kind`
    /// is the long way round, and the only way to say `handoff`. nil means the
    /// `--kind` you typed is not one of ours.
    static func messageKind(in arguments: [String]) -> MessageKind? {
        if let raw = value(after: "--kind", in: arguments) {
            guard let kind = MessageKind(rawValue: raw), kind != .resolve else { return nil }
            return kind
        }
        // Both at once has no right answer, and picking one silently sent a
        // note as urgent that its author also called "for your information".
        if isSet("--urgent", in: arguments) && isSet("--fyi", in: arguments) { return nil }
        if isSet("--urgent", in: arguments) { return .urgent }
        if isSet("--fyi", in: arguments) { return .fyi }
        return .update
    }

    /// Take back your own notes in this project, so the others stop being told
    /// about a blocker you lifted an hour ago.
    static func done(bus: AgentBus, author: String, scope: String?) -> Int32 {
        let scopeName = scope.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "every project"
        let resolved = bus.resolveOwn(author: author, project: scope)
        guard !resolved.isEmpty else {
            print("Nothing of yours left standing in \(scopeName).")
            return 0
        }
        print("Took back \(resolved.count == 1 ? "one note" : "\(resolved.count) notes") in \(scopeName):")
        for message in resolved { print("  - \(message.text)") }
        return 0
    }

    /// One note, in full, by the handle the briefing printed in front of it.
    ///
    /// The gap this closes: a person reads a note in the menu bar and says
    /// "look at that one" — and until now there was no name either of you could
    /// use for it, so the agent went and read the raw jsonl by hand.
    ///
    /// Deliberately unscoped. You are asking for a specific note, and refusing
    /// to show it because you are standing in the wrong directory would be a
    /// rule that only ever gets in the way.
    static func show(_ arguments: [String]) -> Int32 {
        let bus = AgentBus(paths: Paths.fromEnvironment())
        guard let wanted = positional(arguments).first else {
            FileHandle.standardError.write(Data("usage: gentlemerge show <handle>\n".utf8))
            return 64
        }

        let found = bus.messages(matching: wanted)
        guard let message = found.first else {
            print("No note answers to \"\(wanted)\".")
            return 1
        }
        if found.count > 1 {
            print("\"\(wanted)\" names \(found.count) notes; say more of the id:")
            for candidate in found {
                print("  #\(candidate.handle)  \(candidate.id)  \(candidate.from): \(candidate.text.prefix(60))")
            }
            return 1
        }

        let when = HandoffMarkdown.dayFormatter.string(from: message.at)
        let ago = RelativeTime.short(from: message.at, to: Date())
        print("#\(message.handle)  \(message.from)  \(when) (\(ago))")
        print("  id       \(message.id)")
        print("  kind     \(message.effectiveKind.rawValue)")
        print("  project  \(message.projectName ?? "every project")")
        if let to = message.to { print("  to       \(to)") }
        if let branch = message.toBranch { print("  branch   \(branch)") }
        if let replaced = message.replacesID {
            let handle = AgentMessage.handle(for: replaced)
            print("  corrects #\(handle) — `gentlemerge show \(handle)` for what it said")
        }
        // Said out loud, because a note you had to ask for by name is usually
        // one somebody is about to act on.
        if !bus.isStanding(message) {
            print("  NOTE     no longer standing: it has expired, or a later note corrected it")
        }
        print("")
        print(message.text)
        for line in bus.attachmentLines(of: message) { print(line) }
        return 0
    }

    static func hours(_ interval: TimeInterval) -> Int { Int(interval / 3600) }

    /// Who is working on what, right now.
    static func who(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // Drain first, like `brief`, `claims` and `precommit`: the activities
        // this prints are made from hook events, and without the app running
        // nothing else turns the spool into them. `who` answered "No agent
        // sessions running" with two agents mid-turn.
        InboxModel.drainHeadless(paths: paths)
        let bus = AgentBus(paths: paths)
        // Everything, still: unlike the briefing, this is you asking, and the
        // whole point of asking is usually to find the session you lost. `--all`
        // is that default said out loud, so the briefing can name a command that
        // reads as the opposite of `--project`.
        let project = isSet("--project", in: arguments) && !isSet("--all", in: arguments)
            ? projectDirectory(arguments, allowPositional: false)
            : nil
        let live = bus.others(excluding: nil, project: project)
        // The ones that were killed rather than closed. Shown here and nowhere
        // else: you want to know which session you lost, and the other agents
        // want to stop being told about it.
        let dead = bus.died(project: project)

        guard !live.isEmpty else {
            let scope = project.map { " in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
            print("No agent sessions running\(scope).")
            printRecentlyDied(dead)
            return 0
        }
        for activity in live {
            print(activity.briefingLine())
        }
        printRecentlyDied(dead)
        return 0
    }

    static func printRecentlyDied(_ activities: [AgentActivity]) {
        guard !activities.isEmpty else { return }
        print("")
        print("Recently died:")
        for activity in activities {
            print(activity.briefingLine())
        }
    }

    /// The same briefing an agent gets injected, as plain text — for the tools
    /// that have no hooks (Hermes, a shell script, you).
    ///
    /// **Identifying yourself is consuming.** With `--as hermes` this is Hermes
    /// reading its own inbox: notes addressed to it arrive, and they are marked
    /// as delivered so the next run is silent. Without it, nothing is consumed
    /// — you are reading over everyone's shoulder, and the agent whose message
    /// it is must still be able to receive it.
    static func brief(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // Hook events land in the spool; without the app running nobody
        // consumes them. Drain first so a briefing never misses what just
        // happened, on macOS and on headless Linux alike.
        InboxModel.drainHeadless(paths: paths)
        let bus = AgentBus(paths: paths)
        // You run this from inside the project you are about to work on, so that
        // is the project it is about.
        let project = projectDirectory(arguments)
        let label = value(after: "--as", in: arguments)

        var blocks: [String] = []
        // A read all the way down: the project map is shown as it was cached,
        // and says so when HEAD has moved past it, rather than walking the tree
        // and rewriting the file behind your back.
        if let handoff = ProjectRegistry.sessionContext(
            for: project,
            refreshingMap: false,
            claims: TaskClaims(paths: paths).active(for: project)
        ) {
            blocks.append(handoff)
        }
        // Named, this reads as that agent and keeps a marker of its own — a
        // pseudo-session, since Hermes has no session to speak of. Anonymous,
        // nothing is marked as delivered and messages addressed to somebody else
        // are shown rather than swallowed, so looking never costs anyone their
        // mail.
        if let briefing = bus.briefing(
            sessionID: label.map(AgentBus.readerSessionID(for:)),
            me: label,
            project: project,
            branch: RepoIdentity.currentBranch(at: checkoutDirectory(arguments)),
            // Run from a session's own tool call, this is that session asking:
            // it should not be listed as somebody else.
            selfSessionID: ProcessInfo.processInfo.environment[Presence.sessionEnvironmentKey]
        ) {
            blocks.append(briefing)
        }

        guard !blocks.isEmpty else {
            print("Nothing to report — no other agents running and no messages.")
            return 0
        }
        print(blocks.joined(separator: "\n\n"))
        return 0
    }

    static func loadItems(paths: Paths) -> [InboxItem] {
        guard
            let data = try? Data(contentsOf: paths.state),
            let items = try? JSONCoding.decoder().decode([InboxItem].self, from: data)
        else { return [] }
        return items
    }
}
