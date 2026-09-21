import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Everything you can do without the menu bar: install the bridge, inspect what
/// is queued, replay the ledger. Running with no arguments starts the app.
enum CLI {
    /// The commands only a working agent runs. Each one is a live agent saying
    /// something about itself, which is exactly what presence needs and exactly
    /// what nobody was recording while the menu bar app was closed.
    ///
    /// `who` and `show` are deliberately absent: those are you looking, and a
    /// person asking who is working should not thereby become one of them.
    private static let commandsOfAWorkingAgent: Set<String> = [
        "say", "brief", "task", "tasks", "precommit", "handoff", "watch", "watches",
        "delegate", "request", "presence", "land",
        // The session-start hook, and the best mark of the lot: it is the one
        // caller that knows the agent's real pid.
        "session-context",
    ]

    static func run(_ arguments: [String]) -> Int32? {
        let command = arguments.dropFirst().first
        let rest = Array(arguments.dropFirst(2))

        if let command, commandsOfAWorkingAgent.contains(command) {
            noteThatWeAreHere(rest)
        }

        switch command {
        case nil:
            return nil // fall through to the menu bar app
        case "demo":
            do {
                let root = Demo.temporaryRoot()
                let paths = rest.contains("--home-real") ? Paths.fromEnvironment() : Paths(home: root.appendingPathComponent("home"))
                _ = try MainActor.assumeIsolated {
                    try Demo.run(in: root, keep: rest.contains("--keep"), paths: paths,
                        binary: URL(fileURLWithPath: arguments[0]).standardizedFileURL) { print($0) }
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data(Redactor.scrub("demo: \(error.localizedDescription)\n").text.utf8))
                return 1
            }
        case "sim":
            return simulation(rest)
        case "mcp":
            return mcp(rest)
        case "install":
            return install(rest)
        case "uninstall":
            return uninstall()
        case "claim":
            return pathClaim(rest)
        case "release":
            return pathRelease(rest)
        case "claims":
            return claims(rest)
        case "git-hooks":
            return gitHooks(rest)
        case "status":
            return status()
        case "doctor":
            return doctor(rest)
        case "config":
            return config(rest)
        case "ownership":
            return ownership(rest)
        case "compact":
            return compact()
        case "list":
            return list()
        case "say":
            return say(rest)
        case "who":
            return who(rest)
        case "brief":
            return brief(rest)
        case "show":
            return show(rest)
        case "review":
            return review(rest)
        case "radar":
            return radar(rest)
        case "projects":
            return projectList()
        case "project":
            return project(rest)
        case "handoff":
            return handoff(rest)
        case "precommit":
            return precommit(rest)
        case "postcommit":
            return postcommit(rest)
        case "land":
            return land(rest)
        case "env":
            return worktreeEnv(rest)
        case "task", "tasks":
            return task(rest)
        case "watch", "watches":
            return watch(rest)
        case "delegate":
            return delegate(rest)
        case "request", "requests":
            return request(rest)
        case "presence":
            return presence(rest)
        case "session-context":
            return sessionContext(rest)
        case "stats":
            return stats(rest)
        case "advise":
            return advise(rest)
        case "snapshot", "snapshots":
            return snapshot(rest)
        case "history":
            return history(rest)
        case "test-event":
            return testEvent(rest)
        case "print-hook":
            print(HookScript.source)
            return 0
        case "help", "--help", "-h":
            printUsage()
            return 0
        case "--version", "version":
            print("gentlemerge \(AppInfo.version) (hook schema \(HookScript.version))")
            return 0
        default:
            FileHandle.standardError.write(Data("Unknown command: \(command ?? "")\n".utf8))
            printUsage()
            return 64
        }
    }

    private static func simulation(_ arguments: [String]) -> Int32 {
        guard let file = value(after: "--script", in: arguments),
              let directory = value(after: "--worktree", in: arguments) else {
            FileHandle.standardError.write(Data("usage: gentlemerge sim --script file.json --worktree dir\n".utf8))
            return 64
        }
        do {
            let script = try JSONDecoder().decode(SimScript.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            try MainActor.assumeIsolated {
                try SimAgent(paths: .fromEnvironment(), worktree: URL(fileURLWithPath: directory), script: script).run { print($0) }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((Redactor.scrub(error.localizedDescription).text + "\n").utf8))
            return 1
        }
    }

    private static func mcp(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = checkoutDirectory(arguments, allowPositional: false)
        do {
            let identity = try Identity.reconcile(explicit: value(after: "--label", in: arguments),
                resolved: Identity.resolve(cwd: directory, provider: .unknown, paths: paths))
            let label = identity.label
            _ = try paths.createDirectories()
            Presence.record(label: label, project: ProjectRegistry.canonicalPath(for: directory),
                branch: nil, task: nil, paths: paths)
            var server = MCPServer(paths: paths, cwd: directory, identity: label)
            server.version = AppInfo.version
            server.serve()
            return 0
        } catch {
            FileHandle.standardError.write(Data(("mcp failed: " + Redactor.scrub(error.localizedDescription).text + "\n").utf8))
            return 1
        }
    }

    // MARK: - install

    private static func install(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let installer = HookInstaller(paths: paths)
        let dryRun = arguments.contains("--dry-run")
        let minimal = arguments.contains("--minimal")
        let codex = arguments.contains("--codex")

        var plan = HookInstaller.Plan()
        if minimal {
            plan.notifyEvents = ["Stop"]
        }

        do {
            let result = try installer.installClaudeCode(plan: plan, dryRun: dryRun)
            print("Claude Code (\(paths.claudeSettings.path)):")
            for note in result.notes { print("  • \(note)") }
            if let backup = result.backup {
                print("  backup: \(backup.path)")
            }

            if codex {
                try installCodex(installer: installer, paths: paths, dryRun: dryRun)
            }

            if !dryRun {
                print("\nRestart your agent sessions to pick up the hooks.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("install failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func installCodex(
        installer: HookInstaller,
        paths: Paths,
        dryRun: Bool
    ) throws {
        let configURL = paths.codexConfig
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("\nCodex: no config at \(configURL.path) — skipped.")
            return
        }

        let original = try String(contentsOf: configURL, encoding: .utf8)
        let (contents, previous) = installer.codexConfigContents(
            original: original,
            scriptPath: paths.codexNotifyScript.path
        )
        let script = installer.codexNotifyScript(chaining: previous)

        print("\nCodex (\(configURL.path)):")
        if previous.isEmpty {
            print("  • notify → \(paths.codexNotifyScript.lastPathComponent)")
        } else {
            print("  • notify → \(paths.codexNotifyScript.lastPathComponent)")
            print("    (chained after your existing \(previous[0]))")
        }

        guard !dryRun else {
            print("  (dry run — nothing written)")
            return
        }

        try installer.writeScripts()
        try AtomicFile.write(Data(script.utf8), to: paths.codexNotifyScript)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: paths.codexNotifyScript.path
        )
        if let backup = try installer.backupIfPresent(configURL) {
            print("  backup: \(backup.path)")
        }
        try AtomicFile.write(Data(contents.utf8), to: configURL)
    }

    private static func uninstall() -> Int32 {
        let paths = Paths.fromEnvironment()
        let installer = HookInstaller(paths: paths)
        do {
            let result = try installer.uninstallClaudeCode()
            for note in result.notes { print("  • \(note)") }
            if let backup = result.backup { print("  backup: \(backup.path)") }
            print(result.changed ? "Claude Code hooks removed." : "Nothing to remove.")
            print("Codex: if you installed it, reset `notify` in ~/.codex/config.toml by hand.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("uninstall failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: - inspection

    private static func status() -> Int32 {
        let paths = Paths.fromEnvironment()
        let installer = HookInstaller(paths: paths)
        let config = AppConfig.load(from: paths.config)
        let spool = SpoolStore(paths: paths)

        print("home:            \(paths.home.path)")
        print("hook script:     \(FileManager.default.fileExists(atPath: paths.hookScript.path) ? "installed" : "missing")")

        let hooks = installer.claudeCodeStatus()
        if hooks.isEmpty {
            print("claude code:     not installed — run `gentlemerge install`")
        } else {
            for event in hooks.keys.sorted() {
                print("claude code:     \(event) → \(hooks[event] ?? "")")
            }
        }

        let codexInstalled = (try? String(contentsOf: paths.codexConfig, encoding: .utf8))?
            .contains(paths.codexNotifyScript.path) ?? false
        print("codex:           \(codexInstalled ? "notify bridge installed" : "not installed")")

        if let pid = try? String(contentsOf: paths.appPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let value = Int32(pid), kill(value, 0) == 0 {
            print("app:             running (pid \(value))")
        } else {
            print("app:             not running")
        }

        let live = AgentBus(paths: paths).activities().filter(\.isLive)
        print("agents running:  \(live.isEmpty ? "none" : live.map { "\($0.provider.displayName)/\($0.projectName)" }.joined(separator: ", "))")

        let queued = (try? FileManager.default.contentsOfDirectory(atPath: paths.spool.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
        print("queued events:   \(queued)")
        // Worth a line of its own: `say --nudge` does nothing at all while this
        // is off, and an agent that cannot see why would keep trying.
        print("nudges:          \(config.allowNudges ? "allowed (idle sessions only)" : "off")")
        _ = spool
        return 0
    }

    /// `gentlemerge doctor [--project dir]` — one screen an agent can read
    /// without asking the coordinator: home writable, spool stuck, presence,
    /// app, git hooks (honoring core.hooksPath), git version for merge-tree,
    /// clock skew. Exits 1 only when something is actually broken.
    private static func doctor(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let checkout = checkoutDirectory(arguments, allowPositional: true)
        let checks = Doctor.run(
            paths: paths,
            project: ProjectRegistry.canonicalPath(for: checkout),
            repo: URL(fileURLWithPath: checkout)
        )
        for check in checks { print(check.line) }
        return checks.contains(where: { $0.level == .fail }) ? 1 : 0
    }

    /// `gentlemerge compact` — deep clean for a home the app has not opened
    /// in months: finished requests, lapsed watches, stale presence, old
    /// dispatch logs, the processed spool, old messages. Only deletes what no
    /// reader will miss; prints what went away.
    private static func compact() -> Int32 {
        let paths = Paths.fromEnvironment()
        let config = AppConfig.load(from: paths.config)
        print("compacting \(paths.home.path) (dispatch older than \(config.retentionDays)d):")
        for line in Retention.compact(paths: paths, config: config).lines {
            print("  \(line)")
        }
        return 0
    }

    /// `gentlemerge config get <key>` / `set <key> <value>` — the knobs a human
    /// turns without the app. Allowlisted on purpose: arbitrary keys would be
    /// a footgun, and every knob here is documented in `config --help`.
    private static func config(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        var config = AppConfig.load(from: paths.config)
        func show(_ key: String) -> Int32 {
            switch key {
            case "dispatchMode": print(config.dispatchMode)
            case "dispatchDailyBudgetMinutes": print(config.dispatchDailyBudgetMinutes)
            case "claimsPolicy": print(config.claimsPolicy)
            case "retentionDays": print(config.retentionDays)
            case "autoLand": print(config.autoLand)
            default:
                FileHandle.standardError.write(Data("unknown key \"\(key)\" — want dispatchMode, dispatchDailyBudgetMinutes, claimsPolicy, retentionDays, autoLand\n".utf8))
                return 64
            }
            return 0
        }
        guard let action = arguments.first else {
            print("usage: gentlemerge config get <key> | set <key> <value>")
            return 64
        }
        if action == "get", arguments.count == 2 { return show(arguments[1]) }
        guard action == "set", arguments.count == 3 else {
            print("usage: gentlemerge config get <key> | set <key> <value>")
            return 64
        }
        let key = arguments[1], value = arguments[2]
        switch key {
        case "dispatchMode":
            guard ["off", "delegated", "strict"].contains(value) else {
                FileHandle.standardError.write(Data("dispatchMode wants off, delegated or strict\n".utf8))
                return 64
            }
            config.dispatchMode = value
        case "dispatchDailyBudgetMinutes", "retentionDays":
            guard let minutes = Int(value), minutes > 0 else {
                FileHandle.standardError.write(Data("\(key) wants a positive integer\n".utf8))
                return 64
            }
            if key == "dispatchDailyBudgetMinutes" { config.dispatchDailyBudgetMinutes = minutes }
            else { config.retentionDays = minutes }
        case "claimsPolicy":
            guard ["warn", "deny", "off"].contains(value) else {
                FileHandle.standardError.write(Data("claimsPolicy wants warn, deny or off\n".utf8))
                return 64
            }
            config.claimsPolicy = value
        case "autoLand":
            guard ["true", "false"].contains(value) else {
                FileHandle.standardError.write(Data("autoLand wants true or false\n".utf8))
                return 64
            }
            config.autoLand = value == "true"
        default:
            FileHandle.standardError.write(Data("unknown key \"\(key)\"\n".utf8))
            return 64
        }
        config.save(to: paths.config)
        return show(key)
    }

    /// `gentlemerge ownership [--project dir]` — show the zones in force and
    /// where they came from. `pin` copies the HANDOFF.md zones into the pinned
    /// authority in the home; `add <pattern> <owner>` / `rm <pattern>` edit it.
    /// Every write is witnessed in the ledger: the gate reads pinned rules
    /// when present because the HANDOFF.md section is writable by the very
    /// agent being judged.
    private static func ownership(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)
        let project = ProjectRegistry.canonicalPath(for: directory)
        var positional: [String] = []
        var i = 0
        while i < arguments.count {
            if arguments[i] == "--project" { i += 2; continue }
            if arguments[i].hasPrefix("--") { i += 1; continue }
            positional.append(arguments[i]); i += 1
        }
        do {
            switch positional.first {
            case nil:
                let (ownership, authority) = Ownership.effective(project: project, paths: paths)
                print("source: \(authority.rawValue) (\(ownership.rules.count) rule(s))")
                for rule in ownership.rules { print("- \(rule.pattern) → \(rule.owner)") }
            case "pin":
                let rules = try Ownership.pin(project: project, paths: paths, by: defaultAuthor())
                print("pinned \(rules.count) rule(s) from HANDOFF.md")
            case "add":
                guard positional.count == 3 else {
                    print("usage: gentlemerge ownership add <pattern> <owner> [--project dir]")
                    return 64
                }
                let rules = try Ownership.setRule(pattern: positional[1], owner: positional[2], project: project, paths: paths, by: defaultAuthor())
                print("now \(rules.count) rule(s) pinned")
            case "rm":
                guard positional.count == 2 else {
                    print("usage: gentlemerge ownership rm <pattern> [--project dir]")
                    return 64
                }
                let rules = try Ownership.setRule(pattern: positional[1], owner: nil, project: project, paths: paths, by: defaultAuthor())
                print("now \(rules.count) rule(s) pinned")
            default:
                print("usage: gentlemerge ownership [pin|add <pattern> <owner>|rm <pattern>] [--project dir]")
                return 64
            }
        } catch {
            FileHandle.standardError.write(Data("ownership failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
        return 0
    }

    private static func list() -> Int32 {
        let paths = Paths.fromEnvironment()
        let items = loadItems(paths: paths).filter(\.isPending).sorted(by: InboxItem.ordered)
        guard !items.isEmpty else {
            print("Nothing waiting.")
            return 0
        }
        for item in items {
            let marker = item.kind == .question ? "●" : "○"
            print("\(marker) \(item.projectName) · \(item.provider.displayName) · \(item.kind.rawValue)")
            print("   \(item.title)")
            if !item.summary.isEmpty { print("   \(item.summary)") }
            print("   id \(item.id)")
        }
        return 0
    }

    private static func history(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let limit = intValue(after: "-n", in: arguments) ?? 20
        let entries = Ledger(url: paths.ledger).recent(limit: limit)
        guard !entries.isEmpty else {
            print("No history yet.")
            return 0
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss"
        for entry in entries.reversed() {
            var line = "\(formatter.string(from: entry.at))  \(entry.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
            line += "  \(URL(fileURLWithPath: entry.project ?? "").lastPathComponent)"
            if let title = entry.title { line += "  \(title)" }
            if let waited = entry.waitedSeconds { line += "  (waited \(Int(waited))s)" }
            print(line)
        }
        return 0
    }


    // MARK: - The bus between agents

    /// Leave a note for the other agents. They read it on their next turn.
    private static func say(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let bus = AgentBus(paths: paths)
        let identity: Identity
        do { identity = try Identity.reconcile(explicit: value(after: "--from", in: arguments),
            resolved: Identity.resolve(cwd: projectDirectory(arguments, allowPositional: false), provider: .unknown, paths: paths))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }
        // Scoped to the project you are standing in, because that is what a note
        // left by an agent is almost always about — and the sessions working
        // somewhere else pay context for every word of it. `--global` is the
        // escape hatch for the few things that really are everybody's business.
        let scoped = arguments.contains("--global") ? nil : projectDirectory(arguments, allowPositional: false)

        let author = identity.label
        if arguments.contains("--done") { return done(bus: bus, author: author, scope: scoped) }

        let text = positional(arguments).joined(separator: " ")
        guard !text.isEmpty else {
            let usage = "usage: gentlemerge say \"...\" [--to claude|codex|hermes] [--to-branch name]\n"
                + "                          [--project dir] [--global] [--replaces handle]\n"
                + "                          [--kind fyi|update|urgent|handoff] [--urgent] [--fyi] [--nudge]\n"
                + "                          [--attach file] ...\n"
                + "       gentlemerge say --done            take back your notes in this project\n"
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }

        guard let kind = messageKind(in: arguments) else {
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
            nudge: arguments.contains("--nudge") ? true : nil,
            attachments: attachments.isEmpty ? nil : attachments,
            replacesID: replaces,
            toBranch: value(after: "--to-branch", in: arguments),
            verified: identity.verified
        )
        let result = bus.post(message)

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
    private static func messageKind(in arguments: [String]) -> MessageKind? {
        if let raw = value(after: "--kind", in: arguments) {
            guard let kind = MessageKind(rawValue: raw), kind != .resolve else { return nil }
            return kind
        }
        if arguments.contains("--urgent") { return .urgent }
        if arguments.contains("--fyi") { return .fyi }
        return .update
    }

    /// Take back your own notes in this project, so the others stop being told
    /// about a blocker you lifted an hour ago.
    private static func done(bus: AgentBus, author: String, scope: String?) -> Int32 {
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
    private static func show(_ arguments: [String]) -> Int32 {
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

    private static func hours(_ interval: TimeInterval) -> Int { Int(interval / 3600) }

    /// Who is working on what, right now.
    private static func who(_ arguments: [String]) -> Int32 {
        let bus = AgentBus(paths: Paths.fromEnvironment())
        // Everything, still: unlike the briefing, this is you asking, and the
        // whole point of asking is usually to find the session you lost. `--all`
        // is that default said out loud, so the briefing can name a command that
        // reads as the opposite of `--project`.
        let project = arguments.contains("--project") && !arguments.contains("--all")
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

    private static func printRecentlyDied(_ activities: [AgentActivity]) {
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
    private static func brief(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
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
            branch: RepoIdentity.currentBranch(at: checkoutDirectory(arguments))
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

    private static func loadItems(paths: Paths) -> [InboxItem] {
        guard
            let data = try? Data(contentsOf: paths.state),
            let items = try? JSONCoding.decoder().decode([InboxItem].self, from: data)
        else { return [] }
        return items
    }

    // MARK: - review (phase 2)

    /// The same review the menu bar runs, printed as text. Useful on its own,
    /// and the way the whole pipeline gets tested without a GUI.
    private static func review(_ arguments: [String]) -> Int32 {
        let path = positional(arguments).first ?? FileManager.default.currentDirectoryPath
        let project = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let includeSlow = arguments.contains("--slow")
        let baseline = value(after: "--since", in: arguments)

        let work = WorkInspector.summarize(projectPath: project.path, baseline: baseline)
        print("WHAT CHANGED")
        if !work.isRepository {
            print("  not a git repository")
        } else if work.changes.isEmpty {
            print("  nothing since \(baseline.map { String($0.prefix(8)) } ?? "HEAD")")
        } else {
            print("  \(work.headline)")
            for change in work.changes.prefix(15) {
                print("  \(change.status.padding(toLength: 3, withPad: " ", startingAt: 0)) \(change.path)"
                    + "  +\(change.added) −\(change.removed)")
            }
        }

        let planned = ProjectChecks.checks(for: project)
        let selected = planned.filter { includeSlow || !$0.optional }
        print("\nCHECKS")
        if planned.isEmpty {
            print("  none detected — add commands to \(ProjectChecks.configFileName)")
        }

        var results: [CheckResult] = []
        for check in planned where !selected.contains(check) {
            print("  ⏸ \(check.name) — skipped (slow; add --slow)")
            results.append(
                CheckResult(
                    name: check.name, command: check.command, kind: check.kind,
                    status: .skipped, exitCode: nil, duration: 0, output: "",
                    skipReason: "slow"
                )
            )
        }
        for check in selected {
            let output = Shell.sh(check.command, in: project, timeout: check.timeout)
            let status: CheckResult.Status = output.timedOut
                ? .timedOut
                : (output.succeeded ? .passed : .failed)
            let mark = status == .passed ? "✓" : (status == .timedOut ? "⏱" : "✗")
            print(String(format: "  \(mark) \(check.name)  %.1fs", output.duration))
            if status != .passed {
                for line in output.text.suffix(600).split(separator: "\n").suffix(8) {
                    print("      \(line)")
                }
            }
            results.append(
                CheckResult(
                    name: check.name, command: check.command, kind: check.kind,
                    status: status, exitCode: output.status, duration: output.duration,
                    output: output.succeeded ? "" : String(output.text.suffix(2_000))
                )
            )
        }

        let questions = WorkInspector.openQuestions(for: work, checks: results)
        if !questions.isEmpty {
            print("\nNEEDS YOUR EYES")
            for question in questions { print("  • \(question)") }
        }

        return results.contains { $0.status == .failed || $0.status == .timedOut } ? 1 : 0
    }

    // MARK: - projects and handoff

    private static func projectDirectory(_ arguments: [String], allowPositional: Bool = true) -> String {
        ProjectRegistry.canonicalPath(for: checkoutDirectory(arguments, allowPositional: allowPositional))
    }

    /// The same directory, before identity resolves it to the repository.
    ///
    /// The distinction matters for exactly one thing: which branch you are on.
    /// Every worktree of a repository is now one project, which is the point —
    /// but they are emphatically not one branch, and asking the repository root
    /// would hand every worktree the main checkout's answer.
    private static func checkoutDirectory(_ arguments: [String], allowPositional: Bool = true) -> String {
        let explicit = value(after: "--project", in: arguments)
            ?? (allowPositional ? positional(arguments).first : nil)
        let raw = explicit ?? FileManager.default.currentDirectoryPath
        return (raw as NSString).expandingTildeInPath
    }

    private static func projectList() -> Int32 {
        let paths = Paths.fromEnvironment()
        let registry = ProjectRegistry(url: paths.projects)
        guard !registry.projects.isEmpty else {
            print("No projects yet. They appear as agents work in them, or run `gentlemerge project init`.")
            return 0
        }

        for summary in registry.projects {
            let handoff = ProjectRegistry.handoff(for: summary.path, refreshingCommits: false)
            let open = handoff.openTasks.count
            var line = summary.name
            if open > 0 { line += "  · \(open) open" }
            if let last = handoff.commits.first {
                line += "  · \(HandoffMarkdown.dayFormatter.string(from: last.date)) \(last.subject)"
            }
            print(line)
            print("   \(summary.path)")
        }
        return 0
    }

    private static func project(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "init":
            let directory = checkoutDirectory(Array(arguments.dropFirst()))
            do {
                let handoff = try ProjectRegistry.initialize(projectPath: directory)
                var registry = ProjectRegistry(url: Paths.fromEnvironment().projects)
                registry.seen(path: directory, provider: nil, at: Date())
                print("Handoff ready: \(ProjectHandoff.fileURL(for: handoff.projectPath).path)")
                print("Pointed CLAUDE.md / AGENTS.md at it where they exist.")
                // Generated per-worktree ports stay out of git; the ports
                // module owns that ignore line, not the Core init.
                WorktreeEnv.ensureGitignore(projectPath: directory)

                // `--label <name>`: this worktree declares who it is, on the
                // shared bus. `--git-hooks`: the pre-commit in the common dir,
                // which covers every worktree of the repository at once.
                let paths = Paths.fromEnvironment()
                if let label = value(after: "--label", in: arguments) {
                    print(try WorktreeLabel.write(label: label, in: URL(fileURLWithPath: directory)))
                }
                if arguments.contains("--git-hooks") {
                    print(try GitHookInstaller(paths: paths).install(repo: URL(fileURLWithPath: directory)))
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }

        case "adopt-worktrees":
            return adoptWorktrees(Array(arguments.dropFirst()))

        default:
            FileHandle.standardError.write(
                Data("usage: gentlemerge project init|adopt-worktrees [dir]\n".utf8)
            )
            return 64
        }
    }

    /// Brings home what the worktree silos collected while every checkout was a
    /// project of its own.
    ///
    /// One-shot and idempotent, so running it on a repository that was never
    /// split costs a `git worktree list` and says so. Nothing is deleted: the
    /// worktree files keep their copy, they simply stop being the only one.
    private static func adoptWorktrees(_ arguments: [String]) -> Int32 {
        let directory = projectDirectory(arguments)
        let report = WorktreeAdoption.adopt(
            repository: directory,
            registryURL: Paths.fromEnvironment().projects
        )

        guard report.changedSomething else {
            print("Nothing to adopt: \(URL(fileURLWithPath: report.repository).lastPathComponent) already has one task list.")
            return 0
        }

        if report.tasksAdopted > 0 {
            let noun = report.tasksAdopted == 1 ? "task" : "tasks"
            print("Adopted \(report.tasksAdopted) open \(noun) into \(ProjectHandoff.fileURL(for: report.repository).path)")
            for source in report.sources {
                print("   from \(source)")
            }
        }
        if !report.projectsFolded.isEmpty {
            let noun = report.projectsFolded.count == 1 ? "worktree" : "worktrees"
            print("Folded \(report.projectsFolded.count) \(noun) back into the project:")
            for path in report.projectsFolded {
                print("   \(path)")
            }
        }
        return 0
    }

    /// Prints the whole handoff — what an agent should read before starting.
    private static func handoff(_ arguments: [String]) -> Int32 {
        let directory = projectDirectory(arguments)
        let handoff = ProjectRegistry.handoff(for: directory)
        print(HandoffMarkdown.render(handoff))
        return 0
    }

    /// What to read before you write a commit.
    ///
    /// Not a gate: it never fails, never blocks, and never touches the index.
    /// It answers one question — has anybody committed to the files I have
    /// open, since I started? — and then gets out of the way. A check that can
    /// stop you committing is a check you learn to skip.
    private static func precommit(_ arguments: [String]) -> Int32 {
        let directory = projectDirectory(arguments)
        let paths = Paths.fromEnvironment()
        if let claimed = value(after: "--as", in: arguments) ?? value(after: "--from", in: arguments) {
            do {
                _ = try Identity.reconcile(explicit: claimed,
                    resolved: Identity.resolve(cwd: checkoutDirectory(arguments), provider: .unknown, paths: paths))
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
            }
        }

        // `--enforce --staged` is the git pre-commit gate (step 2): staged
        // files checked against path claims, ownership and requests, exit 1 on
        // a blocking violation. The overlap report below stays first — it is
        // the context, the gate is the decision.
        if arguments.contains("--enforce") {
            return precommitEnforce(arguments, in: checkoutDirectory(arguments), paths: paths)
        }

        // `--since` for when you know better than we do: a rebase, a clone, or
        // a wrapper that kept its own note of where it came in.
        let baseline = value(after: "--since", in: arguments)
            ?? sessionBaseline(for: directory, paths: paths, arguments: arguments)

        let report = PrecommitCheck.run(in: directory, baseline: baseline)

        guard report.isRepository else {
            print("\(report.projectName) is not a git repository — nothing to check.")
            return 0
        }

        let window = report.baseline
            .map { "since this session started (\($0.prefix(7)))" }
            ?? "in the last \(report.landed.count) \(report.landed.count == 1 ? "commit" : "commits")"

        guard !report.changed.isEmpty else {
            print("Nothing uncommitted in \(report.projectName). \(behindLine(report) ?? "")"
                .trimmingCharacters(in: .whitespaces))
            return 0
        }

        print("\(report.projectName) — \(count(report.changed.count, "file")) uncommitted,"
            + " checked against what landed \(window).")
        if report.checkedRecentInstead {
            print("(No session baseline here, so this is the last few commits rather than"
                + " exactly the ones that landed under you.)")
        }

        if report.overlaps.isEmpty {
            print("\nNobody has committed to any of them. You are clear to commit.")
        } else {
            print("\n⚠️  \(count(report.overlaps.count, "file")) of yours already got committed to:")
            for overlap in report.overlaps {
                print("  \(overlap.path)")
                for commit in overlap.commits {
                    let who = commit.author.map { " · \($0)" } ?? ""
                    let remote = report.isIncoming(commit)
                        ? "  ← on \(report.upstream ?? "the remote"), not in your branch"
                        : ""
                    print("      `\(commit.shortSHA)` \(RelativeTime.short(from: commit.date))\(who)"
                        + " — \(commit.subject)\(remote)")
                }
            }
            if let first = report.overlaps.first, let commit = first.commits.first {
                print("\n  Read the change before you write over it:")
                print("      git show \(commit.shortSHA) -- \(first.path)")
            }

            let untouched = report.untouched
            if !untouched.isEmpty {
                print("\nNobody has been near: \(untouched.joined(separator: ", "))")
            }
        }

        if let behind = behindLine(report) { print("\n\(behind)") }
        return 0
    }

    /// "2 commits behind origin/main" — the other way work gets overwritten,
    /// and the one a file-by-file comparison cannot see.
    private static func behindLine(_ report: PrecommitReport) -> String? {
        guard !report.incoming.isEmpty else { return nil }
        return "Your branch is \(count(report.incoming.count, "commit")) behind"
            + " \(report.upstream ?? "its upstream") — pull before you push."
    }

    /// Bring this branch home: rebase onto main, run the project's checks,
    /// fast-forward main, and tell the bus what landed. Fails before touching
    /// main whenever anything is off — a dirty tree, a conflict (with the
    /// files and who touched them), a failed rebase, a failing check.
    private static func land(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // The branch lands from its own worktree: the rebase replays whatever
        // is checked out here, so `--branch` naming anything else is refused
        // down in Landing rather than here.
        let cwd = checkoutDirectory(arguments, allowPositional: false)
        let repo = URL(fileURLWithPath: cwd)
        let identity: Identity
        do {
            identity = try Identity.reconcile(
                explicit: value(after: "--from", in: arguments) ?? value(after: "--as", in: arguments),
                resolved: Identity.resolve(cwd: cwd, provider: .unknown, paths: paths))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }
        // The worktree's own label first: landing credits whoever owns this
        // checkout, not whoever happened to type the command.
        let label = WorktreeLabel.read(cwd: repo) ?? identity.label
        do {
            let report = try Landing.land(
                branch: value(after: "--branch", in: arguments),
                into: value(after: "--into", in: arguments),
                repo: repo,
                label: label,
                verified: identity.verified,
                paths: paths,
                skipChecks: arguments.contains("--skip-checks"),
                dryRun: arguments.contains("--dry-run"),
                fast: arguments.contains("--fast"),
                progress: { print($0) }
            )
            // The steps already printed on the way; a dry run ends on the plan.
            if report.dryRun { print(report.message) }
            return 0
        } catch let failure as Landing.Failure {
            FileHandle.standardError.write(Data((failure.description + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("land failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Check every `agent/*` branch pair for the merge conflicts they will hit
    /// later, and warn both sides on the bus — once per conflict. At most one
    /// sweep per project per three minutes; never fails, just says why not.
    private static func radar(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let force = arguments.contains("--force")
        let single = value(after: "--project", in: arguments) != nil || !positional(arguments).isEmpty
        let targets: [String]
        if single {
            targets = [projectDirectory(arguments)]
        } else {
            targets = ProjectRegistry(url: paths.projects).projects.map(\.path)
            guard !targets.isEmpty else {
                print("No projects yet. They appear as agents work in them, or run `gentlemerge project init`.")
                return 0
            }
        }
        for target in targets {
            let name = URL(fileURLWithPath: target).lastPathComponent
            switch ConflictRadar.sweep(project: target, paths: paths, ignoreThrottle: force) {
            case .throttled:
                print("\(name): swept recently — nothing due (add --force)")
            case .skipped(let reason):
                print("\(name): radar skipped (\(reason))")
            case .nothingToDo:
                print("\(name): fewer than two agent/* branches")
            case .done(let announced, let pairs):
                print("\(name): \(pairs) pair(s) checked, \(announced) new conflict(s) announced")
            }
        }
        return 0
    }

    /// `precommit --enforce` — the gate the git hook calls. The overlap report
    /// prints first (context), then the claims/ownership/request violations
    /// (decision): a blocking one exits 1, and git refuses the commit.
    private static func precommitEnforce(_ arguments: [String], in directory: String, paths: Paths) -> Int32 {
        let staged = arguments.contains("--staged")
        let repo = URL(fileURLWithPath: directory)
        let project = ProjectRegistry.canonicalPath(for: directory)

        // Identity: the worktree's own label first, then the one live presence
        // mark in this project — and none of the two means we say so once and
        // do not block, because enforcing claims against an unknown actor
        // would block a commit we cannot justify.
        let label = WorktreeLabel.read(cwd: repo) ?? presenceIdentity(project: project, paths: paths)

        // The existing overlap report, exactly as `precommit` prints it.
        let baseline = value(after: "--since", in: arguments)
            ?? sessionBaseline(for: directory, paths: paths, arguments: arguments)
        let report = PrecommitCheck.run(in: directory, baseline: baseline)
        if report.isRepository {
            if report.overlaps.isEmpty {
                print("Nobody has committed to any of the \(count(report.changed.count, "file")) staged/changed. You are clear so far.")
            } else {
                print("⚠️  \(count(report.overlaps.count, "file")) of yours already got committed to:")
                for overlap in report.overlaps {
                    print("  \(overlap.path)")
                }
            }
        }

        let gate = PrecommitGate(paths: paths)
        let files = staged ? gate.stagedFiles(repo: repo) : gate.dirtyFiles(repo: repo)
        let claims = PathClaims(paths: paths).live(project: project)
        let ownership = Ownership.effective(project: project, paths: paths).ownership
        let active = label.flatMap { Requests(paths: paths).inProgress(assignedTo: $0, project: project).first }
        let presence = Presence.marks(paths: paths)
        if let me = label {
            let (_, reaped) = PathClaims.reap(
                claims.filter { $0.label != me },
                presence: presence, isPIDAlive: { Liveness.isProcessAlive($0) }, now: Date()
            )
            if !reaped.isEmpty {
                Ledger(url: paths.ledger).append(LedgerEntry(
                    at: Date(),
                    kind: .note,
                    project: project,
                    title: "claim.reaped",
                    summary: reaped.map { "\($0.label):\($0.pattern)" }.joined(separator: ", ")
                ))
            }
        }
        let violations = PrecommitGate.evaluate(
            staged: files,
            me: label,
            claims: claims,
            ownership: ownership,
            activeRequest: active,
            presence: presence,
            isPIDAlive: { Liveness.isProcessAlive($0) }
        )

        if label == nil {
            print("gentlemerge: no label for this worktree (run `gentlemerge project init --label <name>`); claims not enforced")
        }
        for violation in violations {
            print("✖ \(violation.path): \(violation.reason)")
        }
        if violations.contains(where: { $0.blocking }) {
            // The human escape hatch lives here, not in the hook script, so a
            // skip is published instead of silent: the variable is documented
            // for humans (hook comment, README) and never printed where a
            // model reads, and the bus hears about every use.
            let skip = ProcessInfo.processInfo.environment["GENTLEMERGE_SKIP"]
            if skip != nil && !skip!.isEmpty {
                let who = label ?? "you"
                let summary = "\(who) skipped \(violations.count) blocking violation(s) on \(files.count) file(s)"
                AgentBus(paths: paths).post(AgentMessage(
                    from: who, projectPath: project,
                    text: "⚠ human override: \(summary). The commit went through."
                ))
                Ledger(url: paths.ledger).append(LedgerEntry(
                    at: Date(), kind: .note, project: project,
                    title: "precommit.skipped", summary: summary
                ))
                print("gentlemerge: override recorded on the bus; commit allowed.")
                return 0
            }
            print("gentlemerge: commit blocked. Coordinate via `gentlemerge say`.")
            Ledger(url: paths.ledger).append(LedgerEntry(
                at: Date(),
                kind: .note,
                project: project,
                title: "precommit.blocked",
                summary: "label \(label ?? "?"): \(violations.count) violation(s)"
            ))
            return 1
        }
        return 0
    }

    /// `gentlemerge postcommit [--project dir]` — the git post-commit hook
    /// calls this: release my claims on what just landed, so other agents are
    /// unblocked without waiting for the TTL. Never blocks, never fails: the
    /// exit is always 0, because a bookkeeping error must never break a commit.
    private static func postcommit(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)
        let project = ProjectRegistry.canonicalPath(for: directory)
        guard let label = WorktreeLabel.read(cwd: URL(fileURLWithPath: directory))
            ?? presenceIdentity(project: project, paths: paths) else { return 0 }
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"],
            in: URL(fileURLWithPath: directory),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        guard output.succeeded else { return 0 }
        let files = output.lines.filter { !$0.isEmpty }
        guard !files.isEmpty else { return 0 }
        let released = (try? PathClaims(paths: paths).releaseCovering(
            files: files, project: project, label: label
        )) ?? []
        if !released.isEmpty {
            Ledger(url: paths.ledger).append(LedgerEntry(
                at: Date(),
                kind: .note,
                project: project,
                title: "claim.released",
                summary: "\(label): \(released.count) path(s) landed"
            ))
        }
        return 0
    }

    /// The one live presence mark in a project, or nil — the weak identity of
    /// an agent that said "I am here" and the only one that did.
    private static func presenceIdentity(project: String, paths: Paths) -> String? {
        let live = Presence.marks(paths: paths).filter { !$0.isExpired && $0.projectPath == project }
        return live.count == 1 ? live[0].label : nil
    }

    /// The revision this session opened on, when GentleMerge saw it start.
    /// Absent for Hermes, for a plain shell, and for a session that began
    /// before the hooks were installed — all of which fall back to depth.
    private static func sessionBaseline(
        for directory: String,
        paths: Paths,
        arguments: [String]
    ) -> String? {
        let label = value(after: "--as", in: arguments) ?? defaultAuthor()
        guard let id = TaskClaims(paths: paths).currentSessionID(for: label, in: directory) else {
            return nil
        }
        return SessionRegistry(url: paths.sessions)[id]?.baselineCommit
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private static func task(_ arguments: [String]) -> Int32 {
        // Only `--project` selects the directory here: a bare word is the task
        // text, not a path.
        let directory = projectDirectory(arguments, allowPositional: false)

        switch arguments.first {
        case nil, "list":
            let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
            guard !handoff.tasks.isEmpty else {
                print("No tasks for \(handoff.projectName).")
                return 0
            }
            // Merged in at render time, never stored in the file: the list you
            // read is the task list plus whoever is on it right now.
            let claimed = TaskClaims(paths: Paths.fromEnvironment()).active(for: directory)
            for (index, task) in handoff.tasks.enumerated() {
                let box = task.done ? "x" : " "
                let who = task.addedBy.map { " (\($0))" } ?? ""
                let progress = task.progressLabel.map { " · \($0)" } ?? ""
                // A finished task nobody released is not news; the claim on it
                // died with the work.
                let claim = task.done ? nil : claimed[task.id].map { " · \($0.annotation())" }
                print("\(index). [\(box)] \(task.text)\(progress)\(who)\(claim ?? "")")
                // Numbered, because that is what the step commands take.
                for (position, step) in task.steps.enumerated() {
                    print("     \(position). [\(step.done ? "x" : " ")] \(step.text)")
                }
            }
            return 0

        case "add":
            let text = positional(Array(arguments.dropFirst())).joined(separator: " ")
            guard !text.isEmpty else {
                FileHandle.standardError.write(Data("usage: gentlemerge task add \"what is left\"\n".utf8))
                return 64
            }
            let author: String
            do { author = try Identity.reconcile(explicit: value(after: "--by", in: arguments),
                resolved: Identity.resolve(cwd: directory, provider: .unknown, paths: Paths.fromEnvironment())).label
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
            }
            let scrubbed = Redactor.scrub(text)
            guard !scrubbed.isSuppressed else {
                FileHandle.standardError.write(
                    Data("Not added — that was almost entirely \(scrubbed.summary).\n".utf8)
                )
                return 1
            }
            // Repeated `--step` rather than one string with separators in it:
            // an agent writing this line in bash gets quoting wrong far less
            // often than it gets embedded newlines or delimiters right.
            let steps = values(after: "--step", in: arguments)

            // Asked before the write, because `addTask` silently keeps the task
            // that was already there: without this, re-running the same command
            // would print a plan that never got recorded.
            let wanted = scrubbed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let existed = ProjectRegistry
                .handoff(for: directory, refreshingCommits: false)
                .tasks
                .contains { $0.text.caseInsensitiveCompare(wanted) == .orderedSame }

            let handoff = ProjectRegistry.addTask(text, to: directory, by: author, steps: steps)
            let filed = handoff.tasks.first { $0.text.caseInsensitiveCompare(wanted) == .orderedSame }

            if existed {
                let progress = filed?.progressLabel.map { " · \($0)" } ?? ""
                print("Already on \(handoff.projectName)'s list\(progress): \(scrubbed.text)")
                if !steps.isEmpty {
                    print("Nothing was changed. Add points with:"
                        + " gentlemerge task step add \"\(wanted)\" \"…\"")
                }
                return 0
            }

            print("Added to \(handoff.projectName): \(scrubbed.text)")
            if scrubbed.didRedact { print("(\(scrubbed.summary) taken out)") }

            if let added = filed, !added.steps.isEmpty {
                print("  \(added.steps.count) points, none done yet:")
                for (position, step) in added.steps.enumerated() {
                    print("     \(position). [ ] \(step.text)")
                }
            }
            return 0

        case "done", "undone", "rm":
            let action = arguments[0]
            let words = positional(Array(arguments.dropFirst()))
            guard !words.isEmpty else {
                FileHandle.standardError.write(
                    Data("usage: gentlemerge task \(action) <number|text of the task>\n".utf8)
                )
                return 64
            }

            let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
            let target = resolveTask(words, in: handoff)

            guard let target else {
                FileHandle.standardError.write(
                    Data("No task matching “\(words.joined(separator: " "))”. Run `gentlemerge task list`.\n".utf8)
                )
                return 1
            }
            if action == "rm" {
                _ = ProjectRegistry.removeTask(target.id, in: directory)
                print("Removed: \(target.text)")
            } else {
                _ = ProjectRegistry.setTask(target.id, done: action == "done", in: directory)
                print("\(action == "done" ? "Done" : "Reopened"): \(target.text)")
            }
            // Finishing or dropping a task ends every claim on it, whoever made
            // them. Nobody should have to remember to hand back something that
            // no longer exists — and a forgotten claim is what makes the next
            // agent wait for nothing.
            if action != "undone" {
                let released = (try? TaskClaims(paths: Paths.fromEnvironment())
                    .releaseAll(target.id, in: directory)) ?? []
                if !released.isEmpty {
                    print("(claim released)")
                }
            }
            return 0

        case "claim":
            // Name collision with `task claim <n>` (about *what*, hours):
            // `--paths` present means a path claim — about *where*, minutes.
            if arguments.contains("--paths") { return pathClaim(arguments) }
            return claim(arguments, in: directory)
        case "release":
            // Same collision: paths to hand back vs. a task number to drop.
            if arguments.contains("--paths") { return pathRelease(arguments) }
            return claim(arguments, in: directory)

        case "step", "steps":
            return step(Array(arguments.dropFirst()), in: directory)

        default:
            FileHandle.standardError.write(
                Data(
                    ("usage: gentlemerge task [list|add <text> [--step \"…\"]…|done <n>|undone <n>"
                        + "|rm <n>|claim <n>|release <n>|step add|done|undone <task> <step>]"
                        + " [--project dir]\n").utf8
                )
            )
            return 64
        }
    }

    /// `task claim` — say out loud that you are on this one, before two agents
    /// spend an hour on the same task and find out by collision.
    ///
    /// The hard rule of the whole tool applies here more than anywhere: it
    /// reports; it never gates. A conflict exits 1 so a script can notice, and
    /// says who has it and how long they have had it — because the next move is
    /// a conversation. Nothing stops the second agent doing the work anyway,
    /// and nothing here locks a single file.
    private static func claim(_ arguments: [String], in directory: String) -> Int32 {
        let action = arguments[0]
        let words = positional(Array(arguments.dropFirst()))
        guard !words.isEmpty else {
            FileHandle.standardError.write(
                Data("usage: gentlemerge task \(action) <number|text of the task> [--as label]\n".utf8)
            )
            return 64
        }

        let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
        guard let target = resolveTask(words, in: handoff) else {
            FileHandle.standardError.write(
                Data("No task matching “\(words.joined(separator: " "))”. Run `gentlemerge task list`.\n".utf8)
            )
            return 1
        }

        // `--as` for the cases `defaultAuthor()` cannot see: a wrapper running
        // on Hermes' behalf, or a subagent that wants its own name on it.
        let label = value(after: "--as", in: arguments) ?? defaultAuthor()
        let claims = TaskClaims(paths: Paths.fromEnvironment())

        do {
            if action == "claim" {
                let session = claims.currentSessionID(for: label, in: directory)
                if let held = try claims.claim(target, in: directory, by: label, sessionID: session) {
                    FileHandle.standardError.write(
                        Data("\(target.text) — \(held.conflictLine())\n".utf8)
                    )
                    return 1
                }
                print("Claimed by \(label): \(target.text)")
                print("The others see it on their next turn. It lapses on its own"
                    + " in \(hours(TaskClaims.lifetime))h, or when this session ends.")
                return 0
            }

            if try claims.release(target.id, in: directory, by: label) != nil {
                print("Released: \(target.text)")
                return 0
            }
            if let held = claims.active(for: directory)[target.id] {
                print("Not yours to release — \(held.conflictLine())")
                return 1
            }
            print("Nobody had claimed: \(target.text)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not \(action): \(error)\n".utf8))
            return 1
        }
    }

    /// The briefing gives agents the task *text*, not a number. Making them
    /// list first just to get an index is a step they will skip.
    private static func resolveTask(_ words: [String], in handoff: ProjectHandoff) -> TaskItem? {
        guard let first = words.first else { return nil }
        if let index = Int(first), words.count == 1 {
            return handoff.tasks.indices.contains(index) ? handoff.tasks[index] : nil
        }
        let needle = words.joined(separator: " ").lowercased()
        return handoff.tasks.first { $0.text.lowercased().contains(needle) }
            ?? handoff.tasks.first { needle.contains($0.text.lowercased()) }
    }

    /// Same rule one level down: a number is a position, anything else is
    /// matched against the text.
    private static func resolveStep(_ word: String, in task: TaskItem) -> Int? {
        if let index = Int(word), task.steps.indices.contains(index) { return index }
        let needle = word.lowercased()
        return task.steps.firstIndex { $0.text.lowercased().contains(needle) }
            ?? task.steps.firstIndex { needle.contains($0.text.lowercased()) }
    }

    /// `task step done <task> <step>` — the command that gets run mid-work, so
    /// both selectors take either a number from `task list` or a piece of the
    /// text the briefing already handed the agent.
    private static func step(_ arguments: [String], in directory: String) -> Int32 {
        let action = arguments.first ?? ""
        guard ["add", "done", "undone"].contains(action) else {
            FileHandle.standardError.write(
                Data("usage: gentlemerge task step [add|done|undone] \"<task>\" \"<step>\"\n".utf8)
            )
            return 64
        }

        let words = positional(Array(arguments.dropFirst()))
        guard words.count >= 2 else {
            FileHandle.standardError.write(
                Data("usage: gentlemerge task step \(action) \"<task>\" \"<step>\"\n".utf8)
            )
            return 64
        }

        let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
        guard let (task, stepText) = split(words, in: handoff, requiringStep: action != "add") else {
            FileHandle.standardError.write(
                Data("No task matching “\(words[0])”. Run `gentlemerge task list`.\n".utf8)
            )
            return 1
        }

        if action == "add" {
            let scrubbed = Redactor.scrub(stepText)
            guard !scrubbed.isSuppressed else {
                FileHandle.standardError.write(
                    Data("Not added — that was almost entirely \(scrubbed.summary).\n".utf8)
                )
                return 1
            }
            let before = task.steps.count
            let updated = ProjectRegistry.addStep(stepText, toTask: task.id, in: directory)
            guard let now = updated.tasks.first(where: { $0.id == task.id }) else { return 1 }
            // The registry keeps the point that was already there rather than
            // filing it twice, so the count is what says whether anything
            // actually happened.
            guard now.steps.count > before else {
                print("\(now.text) · \(now.progressLabel ?? "") — that point is already on the list.")
                return 0
            }
            print("\(now.text) · \(now.progressLabel ?? "") — added: \(scrubbed.text)")
            if scrubbed.didRedact { print("(\(scrubbed.summary) taken out)") }
            return 0
        }

        guard let index = resolveStep(stepText, in: task) else {
            FileHandle.standardError.write(
                Data("No step matching “\(stepText)” under “\(task.text)”.\n".utf8)
            )
            return 1
        }

        let updated = ProjectRegistry.setStep(
            at: index,
            ofTask: task.id,
            done: action == "done",
            in: directory
        )
        guard let now = updated.tasks.first(where: { $0.id == task.id }),
              now.steps.indices.contains(index)
        else { return 1 }
        print("\(action == "done" ? "Done" : "Reopened"): \(now.steps[index].text)")
        print("\(now.text) · \(now.progressLabel ?? "")\(now.done ? " · task complete" : "")")
        return 0
    }

    /// Where the task selector ends and the step selector begins.
    ///
    /// Quoting each of the two is what an agent writing a shell line gets
    /// wrong, so the split is found rather than demanded: every cut is tried,
    /// shortest task selector first, and the first one where *both* halves name
    /// something real wins. Requiring both is what stops a one-word task
    /// selector swallowing half of the step.
    private static func split(
        _ words: [String],
        in handoff: ProjectHandoff,
        requiringStep: Bool
    ) -> (task: TaskItem, step: String)? {
        var fallback: (task: TaskItem, step: String)?

        for length in 1..<words.count {
            guard let task = resolveTask(Array(words.prefix(length)), in: handoff) else { continue }
            let rest = words.dropFirst(length).joined(separator: " ")
            if !requiringStep || resolveStep(rest, in: task) != nil { return (task, rest) }
            // Kept so the failure can name the task it did find, which is a far
            // more useful thing to print than "no task matching …".
            if fallback == nil { fallback = (task, rest) }
        }

        return fallback
    }

    /// What a hook prints back into its own session: where the project stood,
    /// and what the other agents are doing right now.
    ///
    /// Silence is the default. Injecting the same thing on every turn would burn
    /// context and teach the model to ignore it.
    private static func sessionContext(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)

        var event = "SessionStart"
        var sessionID: String?
        // No `--provider` means we do not know who this is, and guessing Claude
        // would hand a Claude session's messages to whoever ran the hook.
        var provider: AgentProvider?

        if let payloadPath = value(after: "--payload", in: arguments),
           let data = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)),
           let payload = try? JSONCoding.decoder().decode(JSONValue.self, from: data) {
            event = payload.string("hook_event_name") ?? event
            sessionID = payload.string("session_id")
        }
        if let name = value(after: "--provider", in: arguments) {
            provider = AgentProvider(rawValue: name) ?? .unknown
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
        if let briefing = AgentBus(paths: paths).briefing(
            sessionID: sessionID,
            me: provider.map(AgentBus.label(for:)),
            project: directory,
            mode: briefMode,
            persistCursor: true
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
    private static func stats(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        if arguments.contains("--value") {
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
    private static func advise(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // The human escape hatch covers the edit-time advice too: skipped
        // means silent, the same as every other path in the bridge.
        guard ProcessInfo.processInfo.environment["GENTLEMERGE_SKIP"] == nil else { return 0 }
        let projectDirectory_ = projectDirectory(arguments, allowPositional: false)
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

        // Who is editing? The provider is what the hook says; a worktree label
        // beats it when there is one.
        let provider = value(after: "--provider", in: arguments)
            .flatMap(AgentProvider.init(rawValue:))
        let me = WorktreeLabel.read(cwd: URL(fileURLWithPath: projectDirectory_))
            ?? provider.map(AgentBus.label(for:))
            ?? "agent"

        // Claims are per repository; the file the hook names is usually inside
        // the checkout, which shares the repository with every other worktree.
        let project = ProjectRegistry.canonicalPath(for: projectDirectory_)
        let rel = ToolInputFormatter.relativePath(file, cwd: project)
            .trimmingCharacters(in: CharacterSet(charactersIn: "~"))

        // The same rules as the commit-time gate, decided before the edit
        // lands: a surprise at commit time is twenty minutes of wasted work.
        let claims = PathClaims(paths: paths).live(project: project)
        let ownership = Ownership.effective(project: project, paths: paths).ownership
        let active = Requests(paths: paths).inProgress(assignedTo: me, project: project).first
        let notes = Advise.check(
            path: rel,
            me: me,
            claims: claims,
            ownership: ownership,
            activeRequest: active,
            presence: Presence.marks(paths: paths),
            isPIDAlive: { Liveness.isProcessAlive($0) }
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

    private static func printJSON(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return }
        print(text)
    }

    // MARK: - path claims (step 2)

    /// Ports that do not collide: one range of a hundred per worktree label.
    /// Prints the shell lines; `--write` saves them as `.gentlemerge/env.sh`
    /// in this worktree (and keeps that file out of git).
    private static func worktreeEnv(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let cwd = checkoutDirectory(arguments, allowPositional: false)
        let config = AppConfig.load(from: paths.config)
        let label = WorktreeLabel.read(cwd: URL(fileURLWithPath: cwd)) ?? defaultAuthor()
        let text = WorktreeEnv.render(WorktreeEnv.allocation(label: label, config: config))
        guard arguments.contains("--write") else {
            print(text)
            return 0
        }
        let directory = URL(fileURLWithPath: cwd).appendingPathComponent(".gentlemerge", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try AtomicFile.write(Data((text + "\n").utf8), to: directory.appendingPathComponent("env.sh"))
            // The file lives in this worktree, so the ignore lives here too —
            // `init` covers the repository root, which is a different checkout.
            WorktreeEnv.ensureGitignore(projectPath: cwd)
            print("wrote \(directory.appendingPathComponent("env.sh").path)")
            print(text)
            return 0
        } catch {
            FileHandle.standardError.write(Data("env failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// `gentlemerge claim --paths <glob,glob> [--intent "..."] [--ttl 30]` —
    /// reserve paths before editing. The name collides with the existing
    /// `task claim <n>` (about *what*, hours); this one is about *where*,
    /// minutes, and only exists with `--paths` present.
    private static func pathClaim(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)
        let patterns = (value(after: "--paths", in: arguments) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !patterns.isEmpty else {
            FileHandle.standardError.write(
                Data(("usage: gentlemerge claim --paths <glob,glob> [--intent \"...\"] [--ttl minutes] [--project dir]\n"
                    + "       (task claims are `gentlemerge task claim <n|text>`)\n").utf8)
            )
            return 64
        }

        let label: String
        do {
            label = try Identity.reconcile(explicit: value(after: "--from", in: arguments),
                resolved: Identity.resolve(cwd: checkoutDirectory(arguments, allowPositional: false),
                    provider: value(after: "--provider", in: arguments).flatMap(AgentProvider.init(rawValue:)) ?? .unknown,
                    paths: paths)).label
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }

        let project = ProjectRegistry.canonicalPath(for: directory)
        let intent = value(after: "--intent", in: arguments)
        let ttl = (value(after: "--ttl", in: arguments) ?? "")
            .flatMap { Double($0) }.map { $0 * 60 } ?? PathClaims.explicitTTL

        do {
            for pattern in patterns {
                let claim = try PathClaims(paths: paths).claim(
                    pattern: pattern,
                    label: label,
                    project: project,
                    intent: intent,
                    ttl: ttl
                )
                let minutes = max(Int(claim.expires.timeIntervalSinceNow / 60), 0)
                print("Claimed \(claim.pattern) for \(label), \(minutes)m left")
            }
            return 0
        } catch let conflict as PathClaimConflict {
            // Exit 1 so a script can notice; the description says who has it
            // and for how long — the next move is a conversation.
            FileHandle.standardError.write(Data("\(conflict.description)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("could not claim: \(error)\n".utf8))
            return 1
        }
    }

    /// `gentlemerge release [--paths <glob,glob>]` — hand back what you were
    /// editing. No `--paths` releases everything of yours in this project.
    private static func pathRelease(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)
        let label: String
        do {
            label = try Identity.reconcile(explicit: value(after: "--from", in: arguments),
                resolved: Identity.resolve(cwd: checkoutDirectory(arguments, allowPositional: false),
                    provider: value(after: "--provider", in: arguments).flatMap(AgentProvider.init(rawValue:)) ?? .unknown,
                    paths: paths)).label
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }

        let project = ProjectRegistry.canonicalPath(for: directory)
        let patterns = (value(after: "--paths", in: arguments) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            try PathClaims(paths: paths).release(label: label, project: project, patterns: patterns.isEmpty ? nil : patterns)
            print(patterns.isEmpty ? "Released every claim by \(label) in \(project)" : "Released \(patterns.count) claim(s)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not release: \(error)\n".utf8))
            return 1
        }
    }

    /// `gentlemerge claims` — who holds what, across this project.
    private static func claims(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)
        let project = ProjectRegistry.canonicalPath(for: directory)
        let live = PathClaims(paths: paths).live(project: project)

        guard !live.isEmpty else {
            print("No live path claims in \(project).")
            return 0
        }

        if arguments.contains("--json") {
            let data = (try? JSONCoding.encoder(pretty: true).encode(live)) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return 0
        }

        print("Live path claims in \(project):")
        for claim in live.sorted(by: { $0.expires < $1.expires }) {
            let minutes = max(Int(claim.expires.timeIntervalSinceNow / 60), 0)
            let kind = claim.implicit ? "implicit" : "explicit"
            let intent = claim.intent.map { " — \($0)" } ?? ""
            print("  \(claim.label): `\(claim.pattern)`\(intent) [\(kind), \(minutes)m left]")
        }
        return 0
    }

    // MARK: - requests (step 3)

    private static func delegate(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = checkoutDirectory(arguments, allowPositional: false)
        let project = ProjectRegistry.canonicalPath(for: directory)
        guard let to = value(after: "--to", in: arguments),
              let title = value(after: "--title", in: arguments),
              let spec = value(after: "--spec", in: arguments)
        else {
            FileHandle.standardError.write(
                Data(("usage: gentlemerge delegate --to <label|capability:name> --title \"...\" --spec \"...\""
                    + " [--inputs a,b] [--expect path] [--may-touch glob] [--budget 15] [--project dir]\n").utf8)
            )
            return 64
        }

        let identity: Identity
        do { identity = try Identity.reconcile(explicit: value(after: "--from", in: arguments),
            resolved: Identity.resolve(cwd: directory, provider: .unknown, paths: paths))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }
        let inputs = splitCSV(values(after: "--inputs", in: arguments))
        let mayTouch = splitCSV(values(after: "--may-touch", in: arguments))
        let budget = intValue(after: "--budget", in: arguments) ?? 30

        do {
            let request = try AgentBus(paths: paths).delegate(
                from: identity.label,
                fromVerified: identity.verified,
                to: to,
                projectPath: project,
                title: title,
                spec: spec,
                inputs: inputs,
                expectedOutput: value(after: "--expect", in: arguments),
                mayTouch: mayTouch,
                budgetMinutes: budget
            )
            print("Created \(request.id) -> \(request.resolvedTo ?? request.to)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("delegate failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func request(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = checkoutDirectory(arguments, allowPositional: false)
        let project = ProjectRegistry.canonicalPath(for: directory)
        let store = Requests(paths: paths)
        switch arguments.first {
        case "show":
            guard let id = positional(Array(arguments.dropFirst())).first else {
                FileHandle.standardError.write(Data("usage: gentlemerge request show <id>\n".utf8))
                return 64
            }
            guard let request = store.load(id) else {
                FileHandle.standardError.write(Data("request \(id) not found\n".utf8))
                return 1
            }
            let data = (try? JSONCoding.encoder(pretty: true).encode(request)) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return 0
        case "list", nil:
            let label = value(after: "--as", in: arguments)
                ?? value(after: "--from", in: arguments)
                ?? WorktreeLabel.read(cwd: URL(fileURLWithPath: directory))
                ?? defaultAuthor()
            let rows: [AgentRequest]
            if arguments.contains("--mine") {
                rows = store.mine(from: label, project: project)
            } else if arguments.contains("--for-me") {
                rows = store.pending(for: label, project: project)
            } else {
                rows = store.all().filter { $0.projectPath == project }
            }
            guard !rows.isEmpty else {
                print("No requests.")
                return 0
            }
            for request in rows {
                print("\(request.id)  \(request.state.rawValue)  \(request.from) -> \(request.resolvedTo ?? request.to)  \(request.title)")
            }
            return 0
        case "accept", "done", "fail", "reject", "ack":
            let action = arguments[0]
            guard let id = positional(Array(arguments.dropFirst())).first else {
                FileHandle.standardError.write(
                    Data("usage: gentlemerge request \(action) <id> [--result \"...\"] [--as label]\n".utf8)
                )
                return 64
            }
            let me: String
            do {
                me = try Identity.reconcile(explicit: value(after: "--as", in: arguments) ?? value(after: "--from", in: arguments),
                    resolved: Identity.resolve(cwd: checkoutDirectory(arguments, allowPositional: false),
                        provider: .unknown, paths: paths)).label
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
            }
            do {
                print(try RequestActions.perform(
                    action: action,
                    id: id,
                    by: me,
                    result: value(after: "--result", in: arguments),
                    paths: paths
                ))
                return 0
            } catch {
                FileHandle.standardError.write(Data("request failed: \(error)\n".utf8))
                return 1
            }
        default:
            FileHandle.standardError.write(
                Data(("usage: gentlemerge request show <id> | list [--mine|--for-me] [--project dir]\n"
                    + "       gentlemerge request accept|done|fail|reject|ack <id> [--result \"...\"]\n").utf8)
            )
            return 64
        }
    }

    private static func presence(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = checkoutDirectory(arguments, allowPositional: false)
        let label: String
        do {
            label = try Identity.reconcile(explicit: value(after: "--label", in: arguments) ?? value(after: "--from", in: arguments),
                resolved: Identity.resolve(cwd: directory, provider: .unknown, paths: paths)).label
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1
        }
        Presence.record(
            label: label,
            project: ProjectRegistry.canonicalPath(for: directory),
            branch: RepoIdentity.currentBranch(at: directory),
            task: value(after: "--task", in: arguments),
            paths: paths,
            capabilities: arguments.contains("--capabilities")
                ? splitCSV(values(after: "--capabilities", in: arguments)) : nil
        )
        print("Presence recorded for \(label)")
        return 0
    }

    private static func splitCSV(_ values: [String]) -> [String] {
        values.flatMap { value in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty }
    }

    /// `gentlemerge git-hooks install|uninstall [--project dir]` — the
    /// pre-commit gate in the repository's common dir, one hook for every
    /// worktree.
    private static func gitHooks(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let action = arguments.first ?? "install"
        let directory = projectDirectory(Array(arguments.dropFirst()), allowPositional: false)
        let installer = GitHookInstaller(paths: paths)

        do {
            switch action {
            case "install":
                print(try installer.install(repo: URL(fileURLWithPath: directory)))
                return 0
            case "uninstall":
                print(try installer.uninstall(repo: URL(fileURLWithPath: directory)))
                return 0
            default:
                FileHandle.standardError.write(Data("usage: gentlemerge git-hooks install|uninstall [--project dir]\n".utf8))
                return 64
            }
        } catch {
            FileHandle.standardError.write(Data("git-hooks failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Agents run these commands themselves; the label is who to credit.
    /// `GENTLEMERGE_NAME` first, so a subagent can sign with its own name —
    /// see `AgentBus.label(in:)`.
    private static func defaultAuthor() -> String {
        AgentBus.label(in: ProcessInfo.processInfo.environment)
    }

    /// Leaves this agent's mark before the command it was actually asked for.
    ///
    /// Never fails and never says anything: presence is a courtesy to the other
    /// agents, and a `say` that refused to send because it could not write a
    /// mark would be a worse tool than one that quietly forgets who is around.
    private static func noteThatWeAreHere(_ arguments: [String]) {
        // `--project` or the working directory, and never a positional: the
        // first positional of `say` is the note itself, and the first version
        // of this filed every agent under a project named after whatever it had
        // just said.
        let checkout = checkoutDirectory(arguments, allowPositional: false)
        // `--provider` is how the hook says who it is; `--from`/`--as` is how a
        // shell wrapper does. Either beats guessing from the environment.
        let provider = value(after: "--provider", in: arguments)
            .flatMap(AgentProvider.init(rawValue:))
            .map(AgentBus.label(for:))
        // An impersonating `--from` must leave no mark: reconcile first, and a
        // refusal here simply skips the courtesy instead of failing the command.
        let identity: String?
        do {
            identity = try Identity.reconcile(
                explicit: value(after: "--from", in: arguments) ?? value(after: "--as", in: arguments),
                resolved: Identity.resolve(cwd: checkout,
                    provider: value(after: "--provider", in: arguments).flatMap(AgentProvider.init(rawValue:)) ?? .unknown,
                    paths: Paths.fromEnvironment())).label
        } catch { identity = nil }
        Presence.record(
            label: identity
                ?? provider
                ?? defaultAuthor(),
            project: ProjectRegistry.canonicalPath(for: checkout),
            branch: RepoIdentity.currentBranch(at: checkout),
            paths: Paths.fromEnvironment(),
            capabilities: arguments.contains("--capabilities")
                ? splitCSV(values(after: "--capabilities", in: arguments)) : nil
        )
    }

    // MARK: - watch (phase 6)

    /// "Tell me when Codex finishes that migration."
    ///
    /// Asked once, answered on the bus you already read: the app notices the
    /// event and posts a note to your label, which arrives on your next turn
    /// through the hook you already have. Nothing here waits on anything, and a
    /// rule nobody's event ever matches lapses on its own after 48h.
    private static func watch(_ arguments: [String]) -> Int32 {
        let watches = Watches(paths: Paths.fromEnvironment())

        switch arguments.first {
        case "session-end", "end":
            return addWatch(.sessionEnd, Array(arguments.dropFirst()), to: watches)
        case "idle":
            return addWatch(.sessionIdle, Array(arguments.dropFirst()), to: watches)
        case "task":
            return addWatch(.taskDone, Array(arguments.dropFirst()), to: watches)
        case nil, "list":
            return listWatches(watches)
        case "rm", "cancel":
            return removeWatch(Array(arguments.dropFirst()), from: watches)
        default:
            FileHandle.standardError.write(
                Data(
                    ("usage: gentlemerge watch [session-end <id|label>|idle <label>|task <n|text>]"
                        + " [--note \"…\"] [--project dir] [--global] [--as label]\n"
                        + "       gentlemerge watch list | rm <id>\n").utf8
                )
            )
            return 64
        }
    }

    private static func addWatch(
        _ kind: WatchRule.Kind,
        _ arguments: [String],
        to watches: Watches
    ) -> Int32 {
        let words = positional(arguments)
        guard !words.isEmpty else {
            let form: String
            switch kind {
            case .sessionEnd: form = "session-end <session id or agent label>"
            case .sessionIdle: form = "idle <agent label>"
            case .taskDone: form = "task <number|text of the task>"
            }
            FileHandle.standardError.write(Data("usage: gentlemerge watch \(form) [--note \"…\"]\n".utf8))
            return 64
        }

        // Scoped to the project you are standing in, like `say`: a watch that
        // fires on any agent finishing anywhere is the noise this replaces.
        let directory = projectDirectory(arguments, allowPositional: false)
        let scoped = arguments.contains("--global") ? nil : directory
        // Whoever asks is who gets told. `--as` covers the cases the environment
        // cannot see — a wrapper asking on Hermes' behalf, mostly.
        let owner = value(after: "--as", in: arguments) ?? defaultAuthor()

        // Written by a human or by an agent, and it ends up in somebody else's
        // context: scrubbed here as well as on its way onto the bus.
        var note: String?
        if let raw = value(after: "--note", in: arguments) {
            let scrubbed = Redactor.scrub(raw)
            guard !scrubbed.isSuppressed else {
                FileHandle.standardError.write(
                    Data("Not watched — that note was almost entirely \(scrubbed.summary).\n".utf8)
                )
                return 1
            }
            note = scrubbed.text
        }

        var target = words.joined(separator: " ")
        var subject: String

        if kind == .taskDone {
            let handoff = ProjectRegistry.handoff(for: directory, refreshingCommits: false)
            guard let task = resolveTask(words, in: handoff) else {
                FileHandle.standardError.write(
                    Data("No task matching “\(target)”. Run `gentlemerge task list`.\n".utf8)
                )
                return 1
            }
            guard !task.done else {
                // Filing it would be a rule that can only fire on the day
                // somebody reopens the task — never what was meant.
                print("Already done: \(task.text)")
                return 0
            }
            // The id and not the text: a task renamed by hand is a different
            // task, and telling you it finished would be a lie.
            target = task.id
            subject = "“\(task.text)” is ticked off"
        } else {
            target = words[0]
            subject = kind == .sessionEnd ? "\(target)'s session ends" : "\(target) finishes a turn"
        }

        let rule = WatchRule(
            owner: owner,
            projectPath: scoped,
            kind: kind,
            target: target,
            note: note
        )
        do {
            try watches.add(rule)
        } catch {
            FileHandle.standardError.write(Data("could not file that watch: \(error)\n".utf8))
            return 1
        }

        let scope = rule.projectName.map { "in \($0)" } ?? "in every project"
        print("Watching \(scope): \(subject) → \(owner)")
        print("It fires once, as a note on the bus you already read,"
            + " and lapses on its own in \(hours(Watches.timeToLive))h. Nothing waits on it.")
        print("id \(rule.shortID) — call it off with `gentlemerge watch rm \(rule.shortID)`")
        return 0
    }

    private static func listWatches(_ watches: Watches) -> Int32 {
        // Standing rules only. What has already fired is on the bus, where the
        // owner reads it; repeating it here would be two places to look.
        let standing = watches.pending()
        guard !standing.isEmpty else {
            print("Nothing being watched. `gentlemerge watch idle codex` and you will be told.")
            return 0
        }
        print("Standing watches — each fires once, then lapses:")
        for rule in standing { print("  \(rule.listLine())") }
        return 0
    }

    private static func removeWatch(_ arguments: [String], from watches: Watches) -> Int32 {
        guard let prefix = positional(arguments).first else {
            FileHandle.standardError.write(Data("usage: gentlemerge watch rm <id>\n".utf8))
            return 64
        }

        let found = watches.matching(prefix: prefix)
        guard !found.isEmpty else {
            FileHandle.standardError.write(
                Data("No standing watch starting with “\(prefix)”. Run `gentlemerge watch list`.\n".utf8)
            )
            return 1
        }
        guard found.count == 1 else {
            FileHandle.standardError.write(Data("“\(prefix)” names \(found.count) watches — type more of the id.\n".utf8))
            return 1
        }

        do {
            // An append, not a rewrite: this runs in an agent's shell, and the
            // app is the only process that compacts the file.
            let cancelled = try watches.retire(ids: [found[0].id])
            print(cancelled.isEmpty ? "Already gone." : "Called off: \(found[0].listLine())")
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not call that watch off: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - snapshots (phase 3)

    private static func snapshot(_ arguments: [String]) -> Int32 {
        let projectPath = value(after: "--project", in: arguments)
            ?? FileManager.default.currentDirectoryPath
        guard let git = GitSnapshot(anyPathInside: projectPath) else {
            FileHandle.standardError.write(Data("\(projectPath) is not inside a git repository.\n".utf8))
            return 1
        }

        switch arguments.first {
        case nil, "list":
            let snapshots = git.list()
            if snapshots.isEmpty { print("No restore points.") }
            for snapshot in snapshots {
                print("\(snapshot.id)  \(snapshot.commit.prefix(8))  \(snapshot.label)")
            }
            return 0

        case "create":
            let label = positional(Array(arguments.dropFirst())).first ?? "manual"
            do {
                let reference = try git.create(label: label)
                print("\(reference.id)  \(reference.commit.prefix(8))  \(reference.dirtyFiles) changed files")
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }

        case "restore":
            guard let id = arguments.dropFirst().first,
                  let reference = git.list().first(where: { $0.id.hasPrefix(id) }) else {
                FileHandle.standardError.write(Data("usage: gentlemerge snapshot restore <id>\n".utf8))
                return 64
            }
            do {
                let report = try git.restore(reference)
                print("Restored “\(reference.label)”: \(report.summary).")
                for path in report.restored.prefix(20) { print("  ← \(path)") }
                for path in report.created.prefix(20) { print("  left in place: \(path)") }
                if let safety = report.safety {
                    print("Undo this restore with: gentlemerge snapshot restore \(safety.id)")
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return 1
            }

        default:
            FileHandle.standardError.write(Data("usage: gentlemerge snapshot [list|create|restore <id>]\n".utf8))
            return 64
        }
    }

    // MARK: - test

    /// Fires a synthetic event through the real hook script, so this exercises
    /// the same path a live agent takes.
    private static func testEvent(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let installer = HookInstaller(paths: paths)
        let blocking = arguments.contains("--blocking")

        do {
            try installer.writeScripts()
        } catch {
            FileHandle.standardError.write(Data("could not write hook script: \(error)\n".utf8))
            return 1
        }

        let payload: String
        if blocking {
            payload = """
            {"session_id":"test-session","hook_event_name":"PreToolUse","cwd":"\(FileManager.default.currentDirectoryPath)",\
            "tool_name":"Bash","tool_input":{"command":"rm -rf build/ && swift build -c release",\
            "description":"Rebuild from scratch"},"permission_mode":"default"}
            """
        } else {
            payload = """
            {"session_id":"test-session","hook_event_name":"Notification",\
            "cwd":"\(FileManager.default.currentDirectoryPath)",\
            "message":"Claude needs your permission to use Bash"}
            """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            paths.hookScript.path,
            "--provider", "claude-code",
            "--mode", blocking ? "blocking" : "notify",
            "--timeout", "60",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("could not run hook: \(error)\n".utf8))
            return 1
        }
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()

        if blocking {
            print("Parked a permission request in the inbox. Answer it in the menu bar…")
        }
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            print(blocking
                ? "Hook returned nothing — the decision went back to the terminal."
                : "Event queued.")
        } else {
            print("Hook replied to the agent with:\n\(text)")
        }
        return 0
    }

    // MARK: - helpers

    private static func intValue(after flag: String, in arguments: [String]) -> Int? {
        value(after: flag, in: arguments).flatMap(Int.init)
    }

    /// Every occurrence of a repeatable flag, in the order they were written —
    /// the order the steps end up in.
    // Taking a command line apart lives in `CommandArguments`, where a test can
    // reach it. These stay as the shape every call site already uses.

    private static func values(after flag: String, in arguments: [String]) -> [String] {
        CommandArguments(arguments).values(after: flag)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        CommandArguments(arguments).value(after: flag)
    }

    private static func positional(_ arguments: [String]) -> [String] {
        CommandArguments(arguments).positional
    }

    private static func printUsage() {
        print("""
        gentlemerge — one place for every agent that needs you.

        USAGE
          gentlemerge                       start the menu bar app
          gentlemerge install [options]     install the hook bridge
          gentlemerge uninstall             remove our hooks (yours stay)
          gentlemerge status                what is installed and running
          gentlemerge config get|set k [v]  knobs without the app: dispatchMode,
                                              dispatchDailyBudgetMinutes,
                                              claimsPolicy, retentionDays,
                                              autoLand
          gentlemerge doctor [--project dir]  one screen an agent can read: home,
                                              spool, presence, app, git hooks,
                                              git version, clock skew
          gentlemerge compact               deep clean: finished requests,
                                              lapsed watches, stale presence,
                                              old dispatch logs and messages
          gentlemerge list                  pending items, as text
          gentlemerge history [-n 20]       what you authorized, and when
          gentlemerge test-event            fire a synthetic event
          gentlemerge print-hook            print the hook script

        THE BUS — what the other agents are doing, and what they left you
          gentlemerge who [--all]           who is working on what, right now,
                                            and which sessions died in the last
                                            six hours without saying so
          gentlemerge who --project [dir]   only the agents in one project
          gentlemerge brief [dir]           the briefing a hook would inject,
                                            as plain text — for the tools that
                                            have no hooks (Hermes, a script, you).
                                            A read: nothing is consumed, and
                                            notes for other agents are shown
          gentlemerge brief --as hermes     ...as that agent: what is addressed
                                            to it arrives, and arrives once.
                                            Identifying yourself is consuming
          gentlemerge stats [--session id]  what the coordination costs: hook
                                            injections counted off the ledger.
                                            Tokens are chars/4, always an
                                            estimate. --value counts what it
                                            saved: blocked commits, announced
                                            conflicts, cleared claims
          gentlemerge show <handle>         one note in full, by the #abcd the
                                            briefing prints in front of it. So
                                            "look at 3f8a" is a thing you can both
                                            say, and neither of you has to go
                                            reading the raw log by hand
          gentlemerge say "..." [--to claude|codex|hermes] [--project dir]
                                            leave a note for the others, scoped
                                            to the project you are standing in
          gentlemerge say "..." --global    ...for every project, when it really
                                            is everybody's business
          gentlemerge say "..." --urgent    read first, and kept for 72h; --fyi
                                            is the opposite (4h), and the default
                                            update lasts a day. --kind handoff
                                            for the long form
          gentlemerge say "..." --attach f  leave a file with the note: the others
                                            get the path and the first lines, and
                                            open it themselves. Repeatable, 2 MB
                                            each; text is stored scrubbed.
          gentlemerge say "..." --nudge     ask the app to type one fixed line
                                            of notice into their terminal — only
                                            if they are idle, at most one every
                                            ten minutes, and only with nudges
                                            turned on (they are off by default).
                                            Your text is never typed anywhere
          gentlemerge say "..." --replaces <handle>
                                            correct a note instead of adding a
                                            second one next to it. The original is
                                            folded out of every later read, so the
                                            reader is never left guessing which of
                                            the two numbers was the true one.
                                            Anyone can correct anyone: being wrong
                                            is not a private matter on a shared bus
          gentlemerge say "..." --to-branch <name>
                                            for whoever is standing on that branch.
                                            `--to` routes by model, which answers
                                            "who are you"; a collision is about what
                                            you are standing on. Now that every
                                            worktree of a repo shares one bus, this
                                            is how you reach just one of them
          gentlemerge say --done            take back your notes in this project:
                                            the others stop being told about a
                                            blocker you already lifted

        AVÍSAME CUANDO — ask once instead of polling the briefing
          gentlemerge watch session-end <id|label> [--note "..."]
                                            tell me when that session is over,
                                            whether it says goodbye or dies
          gentlemerge watch idle <label>    ...when it finishes its turn and the
                                            next move is somebody else's
          gentlemerge watch task <n|text>   ...when that task gets ticked off,
                                            by whoever ticks it off
          gentlemerge watch list            what is still being watched
          gentlemerge watch rm <id>         call one off
                                            A watch fires once, as a note to you
                                            on the bus you already read, and
                                            lapses on its own after 48h. It is
                                            scoped to the project you are
                                            standing in unless you say --global,
                                            and it never makes anybody wait

        AGENTS WITHOUT HOOKS, AND SUBAGENTS
          Hermes is one-shot: it has no hooks and no session, and inventing them
          would mean inventing a daemon. The wrapper that launches it does the
          two things a hook would have done, either side of the run:

            BRIEF=$(gentlemerge brief --as hermes --project "$PWD")
            hermes -z "$BRIEF

            <what you want done>"
            gentlemerge say --from hermes "what it did"
            gentlemerge say --from hermes --done

          GENTLEMERGE_NAME=claude#exec1     what this process calls itself, for
                                            `say`, `task claim` and `brief --as`.
                                            A session launching executors gives
                                            each one a name; `--to claude` still
                                            reaches all of them, `--to
                                            claude#exec1` reaches exactly one

        AFTER THE AGENT (phase 2)
          gentlemerge review [dir] [--since <commit>] [--slow]
                                            what changed, what its checks say,
                                            and what no command can answer
          gentlemerge radar [--project dir] [--force]
                                            merge every agent/* branch pair in
                                            memory and warn both sides on the
                                            bus about the ones that would
                                            conflict — once per conflict, at
                                            most one sweep per project per 3 min
          gentlemerge land [--branch agent/x] [--into main] [--dry-run] [--skip-checks] [--fast]
                                            bring a branch home: rebase onto
                                            main, run the project's checks,
                                            fast-forward main, tell the bus.
                                            The worktree must be clean; a
                                            conflict prints the files and who
                                            touched them. --dry-run checks and
                                            shows the plan without touching
                                            anything. --fast lands only what
                                            fast-forwards: no rebase, no checks

        PROJECTS — shared state between sessions and models
          gentlemerge projects              every project, with open task counts
          gentlemerge handoff [dir]         print what the next session should know
          gentlemerge precommit [dir]       BEFORE EVERY COMMIT. Which of the files
                                            you have changed somebody already
                                            committed to since your session
                                            started, and whether your branch is
                                            behind its upstream. Never blocks and
                                            never fails — it only tells you what
                                            to read before you write over it
                                            --since <rev>  anchor somewhere else
                                            --as <label>   whose session to use
          gentlemerge ownership [--project dir]
                                            zones in force and where from;
                                            pin|add|rm edits the pinned set
          gentlemerge task list [--project dir]
          gentlemerge task add "what is left" [--by claude]
          gentlemerge task add "smoke test" --step "one" --step "two" --step "three"
                                            file the points before you start, so
                                            a session that dies mid-way still
                                            leaves the score behind
          gentlemerge task step done|undone "<task>" "<step>"
          gentlemerge task step add "<task>" "one more point"
                                            task and step take either the number
                                            from `task list` or part of the text
          gentlemerge task done|undone|rm <number>
          gentlemerge task claim|release <number|text> [--as label]
                                            say you are on it before you start.
                                            Somebody else already on it? You are
                                            told who and since when — never
                                            stopped. Lapses after 2h, or when the
                                            session that took it ends
          gentlemerge project init [dir]    create the handoff and point CLAUDE.md at it
          gentlemerge project adopt-worktrees [dir]
                                            one-shot, for a repository worked in
                                            through git worktrees before they were
                                            understood to be the same project: brings
                                            the tasks their handoffs collected into
                                            the repository's own, and folds them out
                                            of the project list. Deletes nothing, and
                                            adopts nothing twice
          gentlemerge env [--write]         this worktree's ports: one range of a
                                            hundred per label, so two agents'
                                            dev servers never collide. --write
                                            saves .gentlemerge/env.sh to source
                                            before running them

        GUARDRAILS (phase 3)
          gentlemerge snapshot [list|create <label>|restore <id>] [--project dir]

        SIMULATION (zero tokens)
          gentlemerge sim --script file.json --worktree dir
          gentlemerge demo [--keep] [--home-real]
                                            isolated temporary home by default;
                                            --keep preserves the demo files;
                                            --home-real opts into your real inbox

        INSTALL OPTIONS
          --minimal             only Notification and Stop hooks
          --codex               also bridge Codex's notify program
          --dry-run             show what would change, write nothing
        """)
    }
}

enum AppInfo {
    static let version = "0.1.0"
}
