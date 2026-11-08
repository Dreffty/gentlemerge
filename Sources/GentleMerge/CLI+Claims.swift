import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - path claims (step 2)

    /// Ports that do not collide: one range of a hundred per worktree label.
    /// Prints the shell lines; `--write` saves them as `.gentlemerge/env.sh`
    /// in this worktree (and keeps that file out of git).
    static func worktreeEnv(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        let cwd = checkoutDirectory(arguments, allowPositional: false)
        let config = AppConfig.load(from: paths.config)
        // Who is asking, resolved the way every other command resolves it:
        // `GENTLEMERGE_LABEL` first, then this worktree's label. Reading only the
        // worktree label meant agents told apart by the environment variable —
        // the documented way for several of them sharing one folder — were all
        // "you" here, and all got the same hundred ports.
        let label = (try? actingLabel(arguments, explicit: nil)) ?? defaultAuthor()
        let text = WorktreeEnv.render(WorktreeEnv.allocation(label: label, config: config))
        guard isSet("--write", in: arguments) else {
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
    static func pathClaim(_ arguments: [String]) -> Int32 {
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
        // Recorded relative to the repository: an absolute path under this checkout
        // is what an agent naturally writes, and stored as written it protected the
        // wrong thing (see `Glob.relativize`).
        let roots = repositoryRoots(for: checkoutDirectory(arguments, allowPositional: false))
        let recorded = patterns.map { Glob.relativize($0, roots: roots) }
        let intent = value(after: "--intent", in: arguments)
        // A claim that is born expired protects nothing and says it worked: `--ttl 0`
        // and `--ttl -5` both printed "Claimed … 0m left" and exited 0 while
        // `claims` listed nothing, and `--ttl abc` quietly became thirty minutes.
        // A ttl that is not a positive number of minutes is a mistake to report
        // (audit Tier 5 #26 clamped it, which only made the lie quieter).
        let ttl: TimeInterval
        if isSet("--ttl", in: arguments) {
            guard let raw = value(after: "--ttl", in: arguments),
                  let minutes = Double(raw), minutes.isFinite, minutes > 0, minutes <= 24 * 60 else {
                FileHandle.standardError.write(
                    Data("--ttl wants a number of minutes between 0 and 1440, e.g. --ttl 30\n".utf8))
                return 64
            }
            ttl = minutes * 60
        } else {
            ttl = PathClaims.explicitTTL
        }

        do {
            for pattern in recorded {
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
    static func pathRelease(_ arguments: [String]) -> Int32 {
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
        let roots = repositoryRoots(for: checkoutDirectory(arguments, allowPositional: false))
        let patterns = (value(after: "--paths", in: arguments) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Glob.relativize($0, roots: roots) }

        do {
            let store = PathClaims(paths: paths)
            let asked = patterns.isEmpty ? nil : patterns
            let released = try store.release(label: label, project: project, patterns: asked)
            print(store.releaseSummary(released: released, asked: asked, label: label, project: project))
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not release: \(error)\n".utf8))
            return 1
        }
    }

    /// `gentlemerge claims` — who holds what, across this project.
    static func claims(_ arguments: [String]) -> Int32 {
        let paths = Paths.fromEnvironment()
        InboxModel.drainHeadless(paths: paths)
        let directory = projectDirectory(arguments, allowPositional: false)
        let project = ProjectRegistry.canonicalPath(for: directory)
        let live = PathClaims(paths: paths).live(project: project)

        guard !live.isEmpty else {
            print("No live path claims in \(project).")
            return 0
        }

        if isSet("--json", in: arguments) {
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
}
