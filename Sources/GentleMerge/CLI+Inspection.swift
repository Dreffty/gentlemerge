import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - inspection

    static func status() -> Int32 {
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

        if let value = runningAppPID(paths: paths) {
            print("app:             running (pid \(value))")
        } else {
            print("app:             not running")
        }

        let live = AgentBus(paths: paths).activities().filter(\.isLive)
        print("agents running:  \(live.isEmpty ? "none" : live.map { "\($0.displayName)/\($0.projectName)" }.joined(separator: ", "))")

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
    static func doctor(_ arguments: [String]) -> Int32 {
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
    static func compact() -> Int32 {
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
    static func config(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let (loaded, problem) = AppConfig.loadChecked(from: paths.config)
        var config = loaded
        // Said once, on stderr: a typo in the file used to read as a perfectly
        // healthy default config, so a `claimsPolicy` of "deny" showed up as
        // "warn" with nothing to explain why.
        if let problem {
            FileHandle.standardError.write(Data("warning: \(problem) — these are the defaults, not what the file says\n".utf8))
        }
        func show(_ key: String) -> Int32 {
            switch key {
            case "allowDispatch": print(config.allowDispatch)
            case "dispatchMode": print(config.dispatchMode)
            case "dispatchDailyBudgetMinutes": print(config.dispatchDailyBudgetMinutes)
            case "claimsPolicy": print(config.claimsPolicy)
            case "retentionDays": print(config.retentionDays)
            case "autoLand": print(config.autoLand)
            default:
                FileHandle.standardError.write(Data("unknown key \"\(key)\" — want allowDispatch, dispatchMode, dispatchDailyBudgetMinutes, claimsPolicy, retentionDays, autoLand\n".utf8))
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
        case "allowDispatch":
            // The master switch. `dispatchMode` only says how dispatch behaves
            // once this is on, so setting the mode alone (as the README shows)
            // changed nothing — and there was no way to turn this on from here.
            guard ["true", "false"].contains(value) else {
                FileHandle.standardError.write(Data("allowDispatch wants true or false\n".utf8))
                return 64
            }
            config.allowDispatch = value == "true"
        case "dispatchMode":
            guard ["off", "delegated", "strict"].contains(value) else {
                FileHandle.standardError.write(Data("dispatchMode wants off, delegated or strict\n".utf8))
                return 64
            }
            config.dispatchMode = value
        case "dispatchDailyBudgetMinutes":
            // The field is documented as "<= 0 means uncapped" and the gate reads
            // it as `> 0`, so 0 is the only way to turn the cap off — and the
            // shared positive-integer guard used to reject it, making the
            // documented value unreachable. Zero is accepted;
            // a negative stays refused, because that is a typo rather than an
            // intention.
            guard let minutes = Int(value), minutes >= 0 else {
                FileHandle.standardError.write(Data("\(key) wants 0 (uncapped) or a positive integer\n".utf8))
                return 64
            }
            config.dispatchDailyBudgetMinutes = minutes
        case "retentionDays":
            guard let days = Int(value), days > 0 else {
                FileHandle.standardError.write(Data("retentionDays wants a positive integer\n".utf8))
                return 64
            }
            config.retentionDays = days
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
        // Never write defaults over a file we could not read: its other keys
        // (the `agents` list above all) are the user's own work.
        if let problem {
            FileHandle.standardError.write(Data("refusing to change \(key): \(problem). Fix the file or move it away, then try again.\n".utf8))
            return 1
        }
        // Report the failure instead of printing the new value and exiting 0. A read-only
        // or full home used to make `config set` claim success while persisting
        // nothing, so the user believed a setting had changed.
        do {
            try config.save(to: paths.config)
        } catch {
            FileHandle.standardError.write(Data("could not save \(key): \(error.localizedDescription)\n".utf8))
            return 1
        }
        return show(key)
    }

    /// `gentlemerge ownership [--project dir]` — show the zones in force and
    /// where they came from. `pin` copies the HANDOFF.md zones into the pinned
    /// authority in the home; `add <pattern> <owner>` / `rm <pattern>` edit it.
    /// Every write is witnessed in the ledger: the gate reads pinned rules
    /// when present because the HANDOFF.md section is writable by the very
    /// agent being judged.
    static func ownership(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = projectDirectory(arguments, allowPositional: false)
        let project = ProjectRegistry.canonicalPath(for: directory)
        let positional = self.positional(arguments)
        do {
            switch positional.first {
            case nil:
                let (ownership, authority) = Ownership.effective(project: project, paths: paths)
                print("source: \(authority.rawValue) (\(ownership.rules.count) rule(s))")
                for rule in ownership.rules { print("- \(rule.pattern) → \(rule.owner)") }
            case "pin":
                let rules = try Ownership.pin(project: project, paths: paths, by: ownershipAuthor(arguments))
                print("pinned \(rules.count) rule(s) from HANDOFF.md")
            case "add":
                guard positional.count == 3 else {
                    print("usage: gentlemerge ownership add <pattern> <owner> [--project dir]")
                    return 64
                }
                let rules = try Ownership.setRule(pattern: positional[1], owner: positional[2], project: project, paths: paths, by: ownershipAuthor(arguments))
                print("now \(rules.count) rule(s) pinned")
            case "rm":
                guard positional.count == 2 else {
                    print("usage: gentlemerge ownership rm <pattern> [--project dir]")
                    return 64
                }
                let rules = try Ownership.setRule(pattern: positional[1], owner: nil, project: project, paths: paths, by: ownershipAuthor(arguments))
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

    static func list() -> Int32 {
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

    static func history(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // `-n abc` and `-n 0` used to fall back to 20 without a word, which reads
        // as "the last twenty are what you asked for".
        var limit = 20
        if let raw = value(after: "-n", in: arguments) {
            guard let asked = Int(raw), asked > 0 else {
                FileHandle.standardError.write(Data("history -n wants a positive number, not \"\(raw)\"\n".utf8))
                return 64
            }
            limit = asked
        } else if isSet("-n", in: arguments) {
            FileHandle.standardError.write(Data("history -n wants a number after it\n".utf8))
            return 64
        }
        let entries = Ledger(url: paths.ledger).recent(limit: limit)
        guard !entries.isEmpty else {
            print("No history yet.")
            return 0
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss"
        for entry in entries.reversed() {
            var line = "\(formatter.string(from: entry.at))  \(entry.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
            // `URL(fileURLWithPath: "")` is the *current directory*, so an entry with
            // no project used to show whatever folder you happened to be standing in.
            line += "  \(entry.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—")"
            if let title = entry.title { line += "  \(title)" }
            if let waited = entry.waitedSeconds { line += "  (waited \(Int(waited))s)" }
            print(line)
        }
        return 0
    }
}
