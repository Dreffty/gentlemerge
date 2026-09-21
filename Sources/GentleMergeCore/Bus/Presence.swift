import Foundation

/// Who is working right now, according to the agents themselves.
///
/// The activity file is written by the menu bar app, which sees every hook
/// event. That works right up until the app is not running — and then `who`
/// answers "no agent sessions running" while five of them are mid-turn, which
/// is the one answer a collision channel must never give. It is also the least
/// obvious way to be wrong: nothing errors, the list is simply empty.
///
/// So an agent leaves its own mark as it works. One file per agent, written
/// only by that agent, exactly like the delivery markers — the app keeps sole
/// ownership of `activities.json` and nothing needs a lock.
///
/// Identity is the label, the project and the branch rather than a session id.
/// The CLI is invoked afresh for every command and mostly has no session to
/// speak of, and "claude, on this branch, in this project" is both stable
/// across those invocations and the thing another agent actually needs to know.
public enum Presence {
    /// How long a mark counts for, and — for most callers — the only thing
    /// standing between "was here" and "is here".
    ///
    /// Half an hour is a compromise. An agent can think for longer than that
    /// without running a command, so a shorter window would keep burying live
    /// sessions; much longer and a session that died after lunch is still
    /// "working" at tea. The reader is shown the age either way, and "28m ago,
    /// working" is a claim they can weigh for themselves.
    public static let timeToLive: TimeInterval = 30 * 60

    /// Every live agent session is doing right now, recorded by the agents
    /// themselves. A public shape over `Mark`, so the callers that need the
    /// label as written can reach it without the internal type going public.
    public struct PresenceMark: Sendable, Equatable {
        public var label: String
        public var projectPath: String?
        public var branch: String?
        public var updatedAt: Date
        public var pid: Int?
        public var task: String?
        public var capabilities: [String]

        /// A mark past its TTL is not worth believing, whoever reads it.
        public var isExpired: Bool { Date().timeIntervalSince(updatedAt) >= timeToLive }
    }

    /// Where a caller that genuinely knows the agent's own pid says so.
    ///
    /// The hook knows it — it is spawned by the agent, so its parent is the
    /// agent. The CLI does not: run from a tool call, its parent is a shell
    /// that exits the moment the command returns. Recording that shell was the
    /// first version of this file, and it buried every mark within a second of
    /// writing it, which is a more embarrassing way to answer "nobody is
    /// working" than the bug it was meant to fix.
    public static let pidEnvironmentKey = "GENTLEMERGE_PID"

    /// Read one agent's mark directly, without the activity translation — for
    /// the callers that need the label exactly as it was written.
    public static func marks(paths: Paths) -> [PresenceMark] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: paths.presence,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let mark = try? JSONCoding.decoder().decode(Mark.self, from: data)
            else { return nil }
            return PresenceMark(
                label: mark.label,
                projectPath: mark.projectPath,
                branch: mark.branch,
                updatedAt: mark.updatedAt,
                pid: mark.pid,
                task: mark.task,
                capabilities: mark.capabilities
            )
        }
    }

    struct Mark: Codable, Sendable, Equatable {
        var label: String
        var projectPath: String?
        var branch: String?
        var updatedAt: Date
        var pid: Int?
        var task: String?
        var capabilities: [String]

        init(
            label: String,
            projectPath: String?,
            branch: String?,
            updatedAt: Date,
            pid: Int?,
            task: String?,
            capabilities: [String] = []
        ) {
            self.label = label
            self.projectPath = projectPath
            self.branch = branch
            self.updatedAt = updatedAt
            self.pid = pid
            self.task = task
            self.capabilities = capabilities
        }

        enum CodingKeys: String, CodingKey {
            case label, projectPath, branch, updatedAt, pid, task, capabilities
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
            branch = try c.decodeIfPresent(String.self, forKey: .branch)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            pid = try c.decodeIfPresent(Int.self, forKey: .pid)
            task = try c.decodeIfPresent(String.self, forKey: .task)
            capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        }

        /// A mark past its TTL is not worth believing, whoever reads it.
        var isExpired: Bool { Date().timeIntervalSince(updatedAt) >= timeToLive }
    }

    /// Records that this agent is alive and where. Cheap enough to call on
    /// every command: one small file, written whole.
    public static func record(
        label: String,
        project: String?,
        branch: String?,
        task: String? = nil,
        pid: Int? = nil,
        paths: Paths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        capabilities: [String]? = nil
    ) {
        var mark = Mark(
            label: label,
            projectPath: project,
            branch: branch,
            updatedAt: now,
            // nil unless somebody actually knows. It reads as "we cannot tell",
            // which leaves the mark standing until it ages out — the right
            // answer, and the only honest one from here.
            pid: pid ?? environment[pidEnvironmentKey].flatMap(Int.init),
            // Read by every other agent in `who` and briefings: scrubbed here
            // so no entry point stores a secret in it, and dropped entirely
            // when there is nothing safe to show.
            task: task.flatMap { Redactor.shared($0) },
            capabilities: capabilities ?? []
        )
        // Ordinary heartbeats do not withdraw an agent's advertised skills.
        // An explicit [] is a deliberate withdrawal.
        if capabilities == nil,
           let data = try? Data(contentsOf: fileURL(for: mark, in: paths)),
           let previous = try? JSONCoding.decoder().decode(Mark.self, from: data) {
            mark.capabilities = previous.capabilities
        }
        do {
            try FileManager.default.createDirectory(at: paths.presence, withIntermediateDirectories: true)
            try AtomicFile.write(try JSONCoding.encoder().encode(mark), to: fileURL(for: mark, in: paths))
        } catch {
            // Never worth failing a command over: presence is a courtesy to the
            // other agents, not the thing the caller asked for.
            Log.error("could not record presence: \(error.localizedDescription)")
        }
    }

    /// Delete mark files past their TTL. Reads filter those anyway; this is
    /// only about the directory not growing forever. Returns files removed.
    @discardableResult
    public static func prune(paths: Paths, now: Date = Date()) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: paths.presence, includingPropertiesForKeys: nil
        ) else { return 0 }
        var removed = 0
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let mark = try? JSONCoding.decoder().decode(Mark.self, from: data)
            else { continue }
            guard now.timeIntervalSince(mark.updatedAt) >= timeToLive else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// The marks still worth believing, as activities so every existing reader
    /// — `who`, the peer list, the briefing — gets them for free.
    public static func live(paths: Paths, now: Date = Date()) -> [AgentActivity] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: paths.presence,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files.compactMap { url -> AgentActivity? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let mark = try? JSONCoding.decoder().decode(Mark.self, from: data)
            else { return nil }

            guard now.timeIntervalSince(mark.updatedAt) < timeToLive else { return nil }
            // Only when somebody recorded a pid worth checking. `!= false` on
            // purpose: nil is "we cannot tell", which is not a reason to bury
            // somebody.
            guard Liveness.isProcessAlive(mark.pid) != false else { return nil }

            return AgentActivity(
                id: identity(of: mark),
                provider: provider(for: mark.label),
                projectPath: mark.projectPath,
                startedAt: mark.updatedAt,
                updatedAt: mark.updatedAt,
                currentTask: mark.task ?? mark.branch.map { "on \($0)" },
                state: .working,
                pid: mark.pid
            )
        }
    }

    public static func labels(withCapability capability: String, project: String?, paths: Paths) -> [String] {
        marks(paths: paths)
            .filter { !$0.isExpired && Liveness.isProcessAlive($0.pid) != false
                && $0.capabilities.contains(capability) && (project == nil || $0.projectPath == project) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.label)
    }

    /// What makes two marks the same agent: who, where, and on what.
    static func identity(of mark: Mark) -> String {
        let project = mark.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
        return "presence:\(mark.label)@\(project)#\(mark.branch ?? "-")"
    }

    static func fileURL(for mark: Mark, in paths: Paths) -> URL {
        let safe = String(identity(of: mark).map {
            $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-"
        })
        return paths.presence.appendingPathComponent("\(safe).json")
    }

    /// Best guess at which family a label belongs to, for the display name
    /// only. A label is free text and most of them are nobody's enum case.
    static func provider(for label: String) -> AgentProvider {
        let head = label.split(separator: "#").first.map(String.init)?.lowercased() ?? label.lowercased()
        switch head {
        case "claude": return .claudeCode
        case "codex": return .codex
        default: return .unknown
        }
    }
}
