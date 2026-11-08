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
    static let commandsOfAWorkingAgent: Set<String> = [
        "say", "brief", "task", "tasks", "precommit", "handoff", "watch", "watches",
        "delegate", "request", "presence", "land",
        // The session-start hook, and the best mark of the lot: it is the one
        // caller that knows the agent's real pid.
        "session-context",
    ]

    static func run(_ arguments: [String]) -> Int32? {
        let command = arguments.dropFirst().first
        let rest = Array(arguments.dropFirst(2))

        // Asking about a command never runs it. No command looked for `--help`,
        // so they all ignored it and did their job: `uninstall --help` removed
        // the hooks, `compact --help` deep-cleaned, `land --help` merged.
        // Up here, before anything can act or leave a trace.
        if let command, command != "help", asksForHelp(rest) {
            printUsage(of: command)
            return 0
        }

        // An option the command does not know stops the line here, before it can
        // act or leave a trace. Exit 2, the usual answer to "that is not how you
        // call this". A flag where a command should be gets the same.
        if let command, let problem = CommandOptions.problem(command: command, arguments: rest) {
            FileHandle.standardError.write(Data("gentlemerge \(problem)\n".utf8))
            return 2
        }
        if let command, CommandArguments.looksLikeFlag(command), !["--help", "-h", "--version"].contains(command) {
            FileHandle.standardError.write(Data("gentlemerge: unknown option \(command). Nothing was done. See `gentlemerge help`.\n".utf8))
            return 2
        }

        if let problem = invalidDirectoryArgument(command: command, rest: rest) {
            FileHandle.standardError.write(Data("gentlemerge: \(problem)\n".utf8))
            return 64
        }

        if let command, commandsOfAWorkingAgent.contains(command) {
            noteThatWeAreHere(rest)
        }

        switch command {
        case nil:
            // Typed in a terminal, this started the app inside it and kept the
            // terminal busy. Help, as on Linux; the app itself, launched from
            // Finder or `open`, is the one place where nothing typed means "run".
            if launchedAsTheApp { return nil }
            printUsage()
            return 0
        case "app":
            return openApp()
        case "demo":
            do {
                let root = Demo.temporaryRoot()
                let paths = isSet("--home-real", in: rest) ? Paths.fromEnvironment() : Paths(home: root.appendingPathComponent("home"))
                _ = try MainActor.assumeIsolated {
                    try Demo.run(in: root, keep: isSet("--keep", in: rest), paths: paths,
                        // Not `arguments[0]`: that is the word the shell put in
                        // argv[0], which for a PATH-installed binary is just
                        // "gentlemerge" — it resolved to <cwd>/gentlemerge, the
                        // gate then reported "binary not found" on every demo
                        // commit and checked nothing, while the demo printed
                        // `commit ok` for the step the README shows blocked.
                        binary: CurrentExecutable.url) { print($0) }
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
            return projectList(rest)
        case "project":
            return project(rest)
        case "init":
            // Forgiving alias: the README teaches `project init`, but bare
            // `init` is what a newcomer types first. Same flags.
            return project(["init"] + rest)
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
            printUsage(of: rest.first)
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

    /// The binary inside `GentleMerge.app`, which is what Finder and `open` start.
    static var launchedAsTheApp: Bool {
        #if os(macOS)
        Bundle.main.bundleURL.pathExtension == "app"
        #else
        false
        #endif
    }

    /// `gentlemerge app`: the installed app when there is one, opened the way
    /// Finder would, so this terminal is free again at once. nil runs it here, in
    /// this process: inside the bundle, or when nothing is installed.
    static func openApp() -> Int32? {
        #if os(macOS)
        if launchedAsTheApp { return nil }
        // One app per home, before anything is opened or started.
        if let running = runningAppPID() {
            FileHandle.standardError.write(Data("GentleMerge is already running (pid \(running)); it is in the menu bar.\n".utf8))
            return 0
        }
        let home = Paths.userHome().path
        let installed = [home + "/Applications/GentleMerge.app", "/Applications/GentleMerge.app"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let installed else {
            FileHandle.standardError.write(Data(
                ("No GentleMerge.app installed (`make install-app`), so it runs here, in this terminal,"
                    + " without notifications. ⌃C stops it.\n").utf8))
            return nil
        }
        let opened = Shell.run("/usr/bin/open", [installed], timeout: 20)
        guard opened.succeeded else {
            FileHandle.standardError.write(Data("could not open \(installed): \(opened.text)\n".utf8))
            return 1
        }
        print("GentleMerge is in the menu bar (\(installed)).")
        return 0
        #else
        FileHandle.standardError.write(Data("The menu-bar app is macOS only; every command works without it.\n".utf8))
        return 1
        #endif
    }

    static func simulation(_ arguments: [String]) -> Int32 {
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

    static func mcp(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let directory = checkoutDirectory(arguments, allowPositional: false)
        do {
            let identity = try Identity.reconcile(explicit: value(after: "--label", in: arguments),
                resolved: Identity.resolve(cwd: directory, provider: .unknown, paths: paths))
            let label = identity.label
            _ = try paths.createDirectories()
            // Our parent is the agent that spawned this server over stdio, and
            // stays so for as long as the server lives.
            Presence.record(label: label, project: ProjectRegistry.canonicalPath(for: directory),
                branch: nil, task: nil, pid: Int(getppid()), paths: paths)
            var server = MCPServer(paths: paths, cwd: directory, identity: label,
                                   identityVerified: identity.verified)
            server.version = AppInfo.version
            server.serve()
            return 0
        } catch {
            FileHandle.standardError.write(Data(("mcp failed: " + Redactor.scrub(error.localizedDescription).text + "\n").utf8))
            return 1
        }
    }
}

enum AppInfo {
    static let version = "0.1.0"
}
