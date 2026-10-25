import Foundation

public struct SimStep: Codable, Sendable {
    public var action: String
    public var paths: [String]?
    public var text: String?
    public var to: String?
    public var mayTouch: [String]?
    public var seconds: Double?
    public var expectBlocked: Bool?
    public init(action: String, paths: [String]? = nil, text: String? = nil, to: String? = nil,
                mayTouch: [String]? = nil, seconds: Double? = nil, expectBlocked: Bool? = nil) {
        self.action = action; self.paths = paths; self.text = text; self.to = to
        self.mayTouch = mayTouch; self.seconds = seconds; self.expectBlocked = expectBlocked
    }
}
public struct SimScript: Codable, Sendable {
    public var label: String
    public var capabilities: [String]
    public var steps: [SimStep]
    public init(label: String, capabilities: [String], steps: [SimStep]) {
        self.label = label; self.capabilities = capabilities; self.steps = steps
    }
}
public enum SimError: Error, LocalizedError {
    case expectationFailed(String)
    public var errorDescription: String? {
        switch self { case .expectationFailed(let text): return Redactor.scrub(text).text }
    }
}

/// The demo builds a throwaway repository and commits in it, and `Shell` merges
/// the inherited environment into every git call it makes — including the ones
/// made by the nested CLI processes it spawns. So the environment has to be
/// dealt with before anything is written. There are two kinds, and they want
/// opposite treatment.
///
/// **Refused**: the variables that point git at a *different* repository,
/// index or config. Nothing good can come of running the demo under those —
/// at best it fails confusingly, at worst it commits into the repository the
/// user is standing in. Named, never valued, so a refusal cannot disclose a
/// path somebody set in secret.
///
/// **Neutralised**: the variables that only decide whether git stops to talk
/// to a human. Refusing those was over-broad and it cost the project its
/// front door: `GIT_EDITOR` is set by Claude Code itself (`GIT_EDITOR=true`),
/// so `gentlemerge demo` — the README's "try it without any AI" — refused to
/// start inside the agent this exists to coordinate, with a message about
/// unsetting variables the reader never set (audit 2026-10-24). They are
/// pinned to harmless values instead of being rejected: `setenv` here reaches
/// `ProcessInfo.processInfo.environment`, which is what `Shell` hands to every
/// child, so an inherited `GIT_EDITOR=vim` cannot sit waiting for a keystroke
/// that is never coming either.
enum SimEnvironment {
    /// Points git somewhere else. These stop the demo.
    static let redirecting: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES",
        "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_WORK_TREE_OVERRIDE",
        "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
    ]

    /// Only decides whether git waits for a human, and what it is pinned to so
    /// that it does not.
    static let neutralised: [String: String] = [
        "GIT_EDITOR": "true",
        "GIT_SEQUENCE_EDITOR": "true",
        "GIT_PAGER": "cat",
        "GIT_ASKPASS": "true",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    static func validate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let overrides = environment.keys.filter {
            redirecting.contains($0) || $0.hasPrefix("GIT_CONFIG_KEY_")
                || $0.hasPrefix("GIT_CONFIG_VALUE_")
        }.sorted()
        guard overrides.isEmpty else {
            throw SimError.expectationFailed(
                "refusing inherited Git environment: " + overrides.joined(separator: ", ")
                    + ". These point git at another repository; unset them before running demo or sim.")
        }
        for (name, value) in neutralised { setenv(name, value, 1) }
    }
}

public struct SimAgent: Sendable {
    let paths: Paths
    let worktree: URL
    let script: SimScript
    let sessionID: String
    let binary: URL
    public init(paths: Paths, worktree: URL, script: SimScript, binary: URL = CurrentExecutable.url) {
        self.paths = paths; self.worktree = worktree; self.script = script; self.binary = binary.standardizedFileURL
        self.sessionID = "sim-\(script.label)-\(UUID().uuidString)"
    }

    // ADAPTED: event/session are payload fields; InboxModel owns real ingestion.
    @MainActor
    func emit(_ event: String, payload: [String: JSONValue] = [:]) throws {
        var payload = payload
        payload["hook_event_name"] = .string(event)
        payload["session_id"] = .string(sessionID)
        payload["label"] = .string(script.label)
        let provider: AgentProvider = script.label == "claude" ? .claudeCode
            : script.label == "codex" ? .codex : .unknown
        let envelope = SpoolEnvelope(provider: provider, cwd: worktree.path,
            pid: Int(ProcessInfo.processInfo.processIdentifier), payload: .object(payload))
        let spool = SpoolStore(paths: paths)
        try spool.enqueue(envelope)
        let model = InboxModel(paths: paths)
        // Ingest only our event; shared-home envelopes keep their normal processing.
        for envelope in spool.drain(envelopeID: envelope.id) { model.ingest(envelope, allowReview: false) }
    }

    @MainActor
    public func run(log: @Sendable (String) -> Void) throws {
        try SimEnvironment.validate()
        try paths.createDirectories()
        let project = ProjectRegistry.canonicalPath(for: worktree.path)
        Presence.record(label: script.label, project: project, branch: nil, paths: paths, capabilities: script.capabilities)
        let bus = AgentBus(paths: paths), claims = PathClaims(paths: paths)
        func tell(_ text: String) { log(Redactor.scrub("[\(script.label)] " + text).text) }
        try emit("SessionStart")
        defer { try? emit("Stop"); try? emit("SessionEnd") }
        for step in script.steps {
            switch step.action {
            case "edit":
                for path in step.paths ?? [] {
                    let root = worktree.resolvingSymlinksInPath().standardizedFileURL
                    var file = root
                    for component in path.split(separator: "/") {
                        file = file.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
                    }
                    guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                          file.path.hasPrefix(root.path + "/") else {
                        throw SimError.expectationFailed("edit path escapes worktree: \(path)")
                    }
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "") + (step.text ?? "// sim edit\n")
                    try AtomicFile.write(Data(text.utf8), to: file)
                    try emit("PostToolUse", payload: ["tool_name": .string("Edit"), "tool_input": .object(["file_path": .string(file.path)])])
                    log(Redactor.scrub("[\(script.label)] edited \(path)").text)
                }
            case "commit":
                let environment = ["GENTLEMERGE_LABEL": script.label, "GENTLEMERGE_HOME": paths.home.path,
                    "GENTLEMERGE_BIN": binary.path, "GENTLEMERGE_SKIP": "", "GIT_OPTIONAL_LOCKS": "0",
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
                let staged = Shell.run("/usr/bin/env", ["git", "add", "-A"], in: worktree, environment: environment)
                guard staged.succeeded else { throw SimError.expectationFailed("git add failed: " + staged.text) }
                let output = Shell.run("/usr/bin/env", ["git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", step.text ?? "sim commit"], in: worktree, environment: environment)
                let reason = output.text.split(separator: "\n").first(where: { $0.hasPrefix("✖") })
                let blocked = !output.succeeded && reason != nil && !output.timedOut
                guard output.succeeded || blocked else { throw SimError.expectationFailed("git commit failed (not an GentleMerge rejection): " + output.text) }
                tell(blocked ? "commit BLOCKED: \(reason!)" : "commit ok")
                if let expected = step.expectBlocked, expected != blocked {
                    throw SimError.expectationFailed("commit blocked=\(blocked), expected \(expected)")
                }
            case "brief":
                // ADAPTED: briefing is the existing session-context/delta API.
                let brief = bus.briefing(sessionID: sessionID, me: script.label, project: project, mode: .delta)
                // A briefing handed to an agent is coordination spent, same as
                // through the hook: the demo's closing cost line counts these.
                Ledger(url: paths.ledger).append(LedgerEntry(
                    at: Date(),
                    kind: .note,
                    sessionID: sessionID,
                    project: project,
                    title: Stats.eventTitle,
                    mode: "delta",
                    chars: (brief ?? "").count
                ))
                tell("briefing:\n" + (brief ?? "(nothing new)"))
            case "claim":
                for path in step.paths ?? [] {
                    try claims.claim(pattern: path, label: script.label, project: project, intent: step.text)
                    tell("claimed \(path)")
                }
            case "release":
                try claims.release(label: script.label, project: project, patterns: step.paths)
                tell("released")
            case "say":
                try bus.say(from: script.label, to: step.to, text: step.text ?? "", projectPath: project)
                tell("→ \(step.to ?? "all"): \(step.text ?? "")")
            case "delegate":
                let request = try bus.delegate(from: script.label, fromVerified: true, to: step.to ?? "",
                    projectPath: project, title: step.text ?? "task", spec: step.text ?? "", inputs: [],
                    expectedOutput: nil, mayTouch: step.mayTouch ?? [], budgetMinutes: 10)
                tell("delegated \(request.id) → \(request.resolvedTo ?? request.to) (may touch: \((step.mayTouch ?? []).joined(separator: ", ")))")
            case "request_accept", "request_done":
                let requests = Requests(paths: paths)
                let mine = requests.pending(for: script.label, project: project) + requests.inProgress(assignedTo: script.label, project: project)
                guard let request = mine.first else { throw SimError.expectationFailed("no request pending for \(script.label)") }
                let action = step.action == "request_accept" ? "accept" : "done"
                let result = try RequestActions.perform(action: action, id: request.id, by: script.label, result: step.text, paths: paths)
                tell(result + (step.text.map { " · " + $0 } ?? ""))
            case "sleep":
                let seconds = step.seconds ?? 1
                guard seconds.isFinite, (0...60).contains(seconds) else { throw SimError.expectationFailed("sleep must be between 0 and 60 seconds") }
                Thread.sleep(forTimeInterval: seconds)
            default: throw SimError.expectationFailed("unknown action \(step.action)")
            }
        }
    }
}
