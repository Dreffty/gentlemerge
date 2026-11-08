import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - requests (step 3)

    static func delegate(_ arguments: [String]) -> Int32 {
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

    static func request(_ arguments: [String]) -> Int32 {
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
                ?? (try? actingLabel(arguments, explicit: nil))
                ?? defaultAuthor()
            let rows: [AgentRequest]
            if isSet("--mine", in: arguments) {
                rows = store.mine(from: label, project: project)
            } else if isSet("--for-me", in: arguments) {
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

    static func presence(_ arguments: [String]) -> Int32 {
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
            capabilities: isSet("--capabilities", in: arguments)
                ? splitCSV(values(after: "--capabilities", in: arguments)) : nil
        )
        print("Presence recorded for \(label)")
        return 0
    }

    static func splitCSV(_ values: [String]) -> [String] {
        values.flatMap { value in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty }
    }

    /// `gentlemerge git-hooks install|uninstall [--project dir]` — the
    /// pre-commit gate in the repository's common dir, one hook for every
    /// worktree.
    static func gitHooks(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        // No default action: a bare `gentlemerge git-hooks` used to install, so
        // somebody asking what the command does found hooks written into their
        // repository. It says what it needs instead.
        guard let action = arguments.first, action == "install" || action == "uninstall" else {
            FileHandle.standardError.write(Data("usage: gentlemerge git-hooks install|uninstall [--project dir]\n".utf8))
            return 64
        }
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

    /// The directories an absolute path may be relative to: the worktree's own top
    /// level, and the repository's canonical root.
    static func repositoryRoots(for checkout: String) -> [String] {
        var roots: [String] = []
        if let top = GitSnapshot(anyPathInside: checkout)?.repository.path { roots.append(top) }
        roots.append(ProjectRegistry.canonicalPath(for: checkout))
        return roots
    }

    /// Who is acting, the way `say` and `task add` already decide it: the env label,
    /// then *this checkout's* worktree label, and only then the provider guess.
    ///
    /// `task claim`, `watch` and the session baseline asked `defaultAuthor()`
    /// instead — the provider the environment hints at — so an agent in the worktree
    /// labelled `hermes` claimed tasks and filed watches as `claude` (or as `you`),
    /// and the real `claude` could claim the same task without a word of conflict.
    /// `explicit` (`--as`) goes through `reconcile`, so nobody speaks as a label
    /// their worktree does not carry.
    static func actingLabel(_ arguments: [String], explicit: String?) throws -> String {
        let resolved = Identity.resolve(
            cwd: checkoutDirectory(arguments, allowPositional: false),
            provider: .unknown, paths: Paths.fromEnvironment())
        let identity = try Identity.reconcile(explicit: explicit, resolved: resolved)
        // A human at a plain shell resolves to "you"; an agent whose worktree has no
        // label keeps the provider guess it always had.
        return identity.source == .human && explicit == nil ? defaultAuthor() : identity.label
    }

    /// Agents run these commands themselves; the label is who to credit.
    /// `GENTLEMERGE_NAME` first, so a subagent can sign with its own name —
    /// see `AgentBus.label(in:)`.
    /// The running app, if there is one (see `SpoolStore.runningAppPID`).
    static func runningAppPID(paths: Paths = .fromEnvironment()) -> Int32? {
        SpoolStore(paths: paths).runningAppPID()
    }

    static func defaultAuthor() -> String {
        AgentBus.label(in: ProcessInfo.processInfo.environment)
    }

    /// Who an ownership change is credited to: the acting label, as for `say`
    /// and `task claim`. `defaultAuthor()` alone credited an agent known by its
    /// `GENTLEMERGE_LABEL` as `you`.
    static func ownershipAuthor(_ arguments: [String]) -> String {
        (try? actingLabel(arguments, explicit: nil)) ?? defaultAuthor()
    }

    /// Leaves this agent's mark before the command it was actually asked for.
    ///
    /// Never fails and never says anything: presence is a courtesy to the other
    /// agents, and a `say` that refused to send because it could not write a
    /// mark would be a worse tool than one that quietly forgets who is around.
    static func noteThatWeAreHere(_ arguments: [String]) {
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
        let label = identity ?? provider ?? defaultAuthor()
        // "you" is what nobody we can name resolves to: a person at a shell, or
        // a script. A one-off `say` from there is not an agent working, and its
        // mark was listed in briefings as one for half an hour (2026-10-21).
        guard label != "you" else { return }
        // The hook's payload carries the session id; a tool call has it in the
        // environment, which `record` reads by itself.
        let payloadSession = value(after: "--payload", in: arguments)
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONCoding.decoder().decode(JSONValue.self, from: $0) }
            .flatMap { $0.string("session_id") }
        Presence.record(
            label: label,
            project: ProjectRegistry.canonicalPath(for: checkout),
            branch: RepoIdentity.currentBranch(at: checkout),
            sessionID: payloadSession,
            paths: Paths.fromEnvironment(),
            capabilities: isSet("--capabilities", in: arguments)
                ? splitCSV(values(after: "--capabilities", in: arguments)) : nil
        )
    }
}
