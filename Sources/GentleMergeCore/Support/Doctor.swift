import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One screen an agent can read without asking the coordinator: is the
/// machine-side of the coordination alive, and if not, what exactly is wrong.
/// Every line is `ok|warn|fail name: detail` — greppable, no tokens spent
/// waiting for instructions from a coordinator that may be dead.
///
/// Only `fail` means something is broken. `warn` means unprotected or stale:
/// the bus still works, but a protection the user believes in is not there.
public struct Doctor: Sendable {
    public struct Check: Sendable, Equatable {
        public enum Level: String, Sendable { case ok, warn, fail }
        public var name: String
        public var level: Level
        public var detail: String

        public var line: String { "\(level.rawValue) \(name): \(detail)" }
    }

    /// Oldest queued envelope before the spool counts as stuck: the drain
    /// runs on app launch and on every CLI command that touches the bus, so
    /// anything older sat through several chances to be read.
    public static let stuckAfter: TimeInterval = 30 * 60

    /// Minimum git for `merge-tree`: below it the radar and land refuse, and
    /// doctor is where an agent learns why without reading the radar's mind.
    public static let minimumGit = (major: 2, minor: 38)

    /// `gitVersion` is injected so tests can pin old/new git without
    /// installing one; nil runs `git --version` for real.
    public static func run(
        paths: Paths,
        project: String,
        repo: URL,
        gitVersion: String?? = nil,
        now: Date = Date()
    ) -> [Check] {
        [
            homeWritable(paths: paths),
            spool(paths: paths, now: now),
            presence(paths: paths),
            app(paths: paths),
            gitHooks(paths: paths, repo: repo),
            git(paths: paths, repo: repo, override: gitVersion),
            clock(paths: paths, now: now),
            ownership(paths: paths, project: project),
        ]
    }

    // MARK: - Checks

    static func homeWritable(paths: Paths) -> Check {
        let probe = paths.home.appendingPathComponent(".doctor-probe")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return Check(name: "home-writable", level: .ok, detail: paths.home.path)
        } catch {
            return Check(name: "home-writable", level: .fail, detail: "cannot write \(paths.home.path): \(error.localizedDescription)")
        }
    }

    static func spool(paths: Paths, now: Date) -> Check {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: paths.spool, includingPropertiesForKeys: [.contentModificationDateKey]
        ))?.filter { $0.pathExtension == "json" } ?? []
        guard !files.isEmpty else {
            return Check(name: "spool", level: .ok, detail: "empty — nothing waiting for the drain")
        }
        let oldest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.min()
        let age = oldest.map { now.timeIntervalSince($0) } ?? 0
        if age > stuckAfter {
            return Check(name: "spool", level: .warn,
                detail: "\(files.count) queued, oldest \(Int(age / 60))m — the drain has not run; start the app or run any bus command")
        }
        return Check(name: "spool", level: .ok, detail: "\(files.count) queued, oldest \(Int(age))s")
    }

    static func presence(paths: Paths) -> Check {
        let marks = Presence.marks(paths: paths)
        let live = marks.filter { Date().timeIntervalSince($0.updatedAt) < Presence.timeToLive }
        if live.isEmpty {
            return Check(name: "presence", level: .ok, detail: "none live — no agents running (marks: \(marks.count) stale)")
        }
        return Check(name: "presence", level: .ok,
            detail: "\(live.count) live: \(live.map(\.label).sorted().joined(separator: ", "))")
    }

    static func app(paths: Paths) -> Check {
        if let pid = try? String(contentsOf: paths.appPID, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = Int32(pid), kill(value, 0) == 0 {
            return Check(name: "app", level: .ok, detail: "running (pid \(value))")
        }
        return Check(name: "app", level: .ok, detail: "not running — the CLI works without it")
    }

    static func gitHooks(paths: Paths, repo: URL) -> Check {
        let installer = GitHookInstaller(paths: paths)
        let directory: URL
        let note: String?
        do {
            (directory, note) = try installer.targetHooksDir(for: repo)
        } catch {
            return Check(name: "git-hooks", level: .warn, detail: error.localizedDescription)
        }
        let missing = (GitHookInstaller.hookNames + ["post-commit"]).filter { name in
            let path = directory.appendingPathComponent(name)
            guard let body = try? String(contentsOf: path, encoding: .utf8) else { return true }
            let marker = name == "post-commit" ? GitHookInstaller.postCommitMarker : GitHookInstaller.marker
            return !body.contains(marker) || !FileManager.default.isExecutableFile(atPath: path.path)
        }
        if missing.isEmpty {
            // Hooks without a gate binary warn on every commit but check
            // nothing. That is exactly the state worth shouting about.
            let gate = ProcessInfo.processInfo.environment["GENTLEMERGE_BIN"]
                ?? (FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".gentlemerge/bin/gentlemerge").path)
            if !FileManager.default.isExecutableFile(atPath: gate) {
                return Check(name: "git-hooks", level: .warn,
                    detail: "hooks live in \(directory.path) but the gate binary is missing at \(gate) — commits pass unchecked. Reinstall (`gentlemerge install`) or set GENTLEMERGE_BIN.")
            }
            return Check(name: "git-hooks", level: .ok,
                detail: "pre-commit + pre-merge-commit + post-commit live in \(directory.path)" + (note.map { " (\($0))" } ?? ""))
        }
        return Check(name: "git-hooks", level: .warn,
            detail: "missing \(missing.joined(separator: ", ")) in \(directory.path) — run `gentlemerge git-hooks install --project \(repo.path)`")
    }

    static func git(paths: Paths, repo: URL, override: String??) -> Check {
        let raw: String?
        if let override {
            raw = override
        } else {
            let output = Shell.run("/usr/bin/env", ["git", "--version"], in: repo,
                environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: 10)
            raw = output.succeeded ? output.lines.first : nil
        }
        guard let raw, let version = parseGitVersion(raw) else {
            return Check(name: "git", level: .warn, detail: "could not read git version — radar and land need \(minimumGit.major).\(minimumGit.minor)+")
        }
        if version.major > minimumGit.major || (version.major == minimumGit.major && version.minor >= minimumGit.minor) {
            return Check(name: "git", level: .ok, detail: "\(raw) — merge-tree available")
        }
        return Check(name: "git", level: .warn,
            detail: "\(raw) < \(minimumGit.major).\(minimumGit.minor): radar and land refuse, everything else works")
    }

    static func parseGitVersion(_ raw: String) -> (major: Int, minor: Int)? {
        guard let match = raw.range(of: #"(\d+)\.(\d+)"#, options: .regularExpression) else { return nil }
        let parts = raw[match].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Zones the gate enforces: pinned is authoritative, HANDOFF.md is a
    /// convenience the judged agent could have written itself.
    static func ownership(paths: Paths, project: String) -> Check {
        let (ownership, authority) = Ownership.effective(project: project, paths: paths)
        if ownership.rules.isEmpty {
            return Check(name: "ownership", level: .ok, detail: "no zones declared")
        }
        if authority == .pinned {
            return Check(name: "ownership", level: .ok, detail: "\(ownership.rules.count) pinned rule(s) enforced")
        }
        return Check(name: "ownership", level: .warn,
            detail: "\(ownership.rules.count) rule(s) from HANDOFF.md — unprotected; run `gentlemerge ownership pin --project \(project)`")
    }

    static func clock(paths: Paths, now: Date) -> Check {        let probe = paths.home.appendingPathComponent(".doctor-clock")
        do {
            try Data("t".utf8).write(to: probe)
            defer { try? FileManager.default.removeItem(at: probe) }
            let mtime = try FileManager.default.attributesOfItem(atPath: probe.path)[.modificationDate] as? Date ?? now
            let skew = abs(now.timeIntervalSince(mtime))
            if skew > 5 {
                return Check(name: "clock", level: .warn, detail: "mismatch \(Int(skew))s between clock and filesystem — TTLs may misfire")
            }
            return Check(name: "clock", level: .ok, detail: "clock and filesystem agree")
        } catch {
            return Check(name: "clock", level: .warn, detail: "could not probe: \(error.localizedDescription)")
        }
    }
}
