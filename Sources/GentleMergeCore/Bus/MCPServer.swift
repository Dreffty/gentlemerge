import Foundation

/// Line-delimited JSON-RPC over stdio. stdout is reserved for responses.
public struct MCPServer {
    public let paths: Paths
    public let cwd: String
    public let identity: String
    public var version = "1.0"
    public init(paths: Paths, cwd: String, identity: String) {
        self.paths = paths; self.cwd = cwd; self.identity = identity
    }
    public func handle(line: String) -> String? {
        guard let request = try? JSONCoding.decoder().decode(JSONValue.self, from: Data(line.utf8)),
              let id = request["id"] else { return nil }
        let result: JSONValue
        switch request["method"]?.stringValue {
        case "initialize":
            result = .object(["protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("gentlemerge"), "version": .string(version)])])
        case "tools/list":
            result = .object(["tools": .array(Self.tools.map { tool in
                .object(["name": .string(tool.name), "description": .string(tool.description),
                         "inputSchema": tool.schema])
            })])
        case "tools/call":
            let name = request["params"]?["name"]?.stringValue ?? ""
            guard let tool = Self.tools.first(where: { $0.name == name }) else {
                return encode(.object(["jsonrpc": .string("2.0"), "id": id,
                    "error": .object(["code": .number(-32601), "message": .string("unknown tool: \(name)")])]))
            }
            // Same reason as the CLI read commands: hook events wait in the
            // spool until something consumes them, and on a headless machine
            // that something is us, right now.
            InboxModel.drainHeadless(paths: paths)
            if let arguments = request["params"]?["arguments"], arguments.objectValue == nil {
                return rpcError(id, -32602, "arguments must be an object")
            }
            let arguments = request["params"]?["arguments"]?.objectValue ?? [:]
            if let error = tool.validate(arguments) { return rpcError(id, -32602, error) }
            let directory = arguments["project"]?.stringValue ?? cwd
            let project = ProjectRegistry.canonicalPath(for: directory)
            let args = request["params"]?["arguments"]?.objectValue ?? [:]
            if !["brief", "status"].contains(name) {
                do {
                    let text: String
                    switch name {
                    case "precommit":
                        let gate = PrecommitGate(paths: paths)
                        let files = gate.stagedFiles(repo: URL(fileURLWithPath: directory))
                        let violations = PrecommitGate.evaluate(staged: files, me: identity,
                            claims: PathClaims(paths: paths).live(project: project),
                            ownership: Ownership.effective(project: project, paths: paths).ownership,
                            activeRequest: Requests(paths: paths).inProgress(assignedTo: identity, project: project).first)
                        text = violations.isEmpty ? "No staged path violations." : violations.map { "\($0.path): \($0.reason)" }.joined(separator: "\n")
                        return toolReply(id, text, isError: violations.contains(where: { $0.blocking }))
                    case "claim":
                        let patterns = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        var ttl = 30.0
                        if case .number(let value) = args["ttl_minutes"] { ttl = value }
                        text = try patterns.map {
                            let claim = try PathClaims(paths: paths).claim(pattern: $0, label: identity,
                                project: project, intent: args["intent"]?.stringValue, ttl: ttl * 60)
                            return "claimed \(claim.pattern) until \(claim.expires)"
                        }.joined(separator: "\n")
                    case "tool_help":
                        let wanted = args["name"]?.stringValue ?? ""
                        if let tool = Self.tools.first(where: { $0.name == wanted }) {
                            var lines = ["\(tool.name) — \(tool.description)", tool.details, "Arguments:"]
                            lines += tool.fields.sorted(by: { $0.key < $1.key }).map { key, type in
                                "- \(key): \(type)" + (tool.required.contains(key) ? " (required)" : "")
                            }
                            text = lines.joined(separator: "\n")
                        } else {
                            text = "unknown tool \"\(wanted)\". Known: \(Self.tools.map(\.name).sorted().joined(separator: ", "))"
                        }
                    case "claim_check":
                        // Read-only pre-edit check for clients without hooks: no
                        // hook stops an MCP edit, so the check-then-claim
                        // discipline is advisory here, enforced only at commit.
                        let checkPaths = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        guard !checkPaths.isEmpty else { text = "no paths given"; break }
                        let liveClaims = PathClaims(paths: paths).live(project: project)
                        let checkOwnership = Ownership.effective(project: project, paths: paths).ownership
                        let checkActive = Requests(paths: paths).inProgress(assignedTo: identity, project: project).first
                        let checkPresence = Presence.marks(paths: paths)
                        text = checkPaths.map { checkPath in
                            let rel = checkPath.hasPrefix(project + "/")
                                ? String(checkPath.dropFirst(project.count + 1)) : checkPath
                            let notes = Advise.check(path: rel, me: identity, claims: liveClaims,
                                ownership: checkOwnership, activeRequest: checkActive,
                                presence: checkPresence, isPIDAlive: { Liveness.isProcessAlive($0) })
                            return notes.isEmpty ? "ok \(checkPath)" : notes.map(\.text).joined(separator: "\n")
                        }.joined(separator: "\n")
                    case "task_add":
                        _ = ProjectRegistry.addTask(args["text"]?.stringValue ?? "", to: project, by: identity)
                        text = "added"
                    case "task_done":
                        _ = ProjectRegistry.setTask(args["id"]?.stringValue ?? "", done: true, in: project)
                        text = "done"
                    case "say":
                        _ = try AgentBus(paths: paths).say(from: identity, to: args["to"]?.stringValue,
                            text: args["text"]?.stringValue ?? "", projectPath: project)
                        text = "sent"
                    case "delegate":
                        let request = try AgentBus(paths: paths).delegate(from: identity, fromVerified: false,
                            to: args["to"]?.stringValue ?? "", projectPath: project,
                            title: args["title"]?.stringValue ?? "", spec: args["spec"]?.stringValue ?? "",
                            inputs: args["inputs"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            expectedOutput: args["expected_output"]?.stringValue,
                            mayTouch: args["may_touch"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            budgetMinutes: args["budget_minutes"]?.intValue ?? 30)
                        text = "created \(request.id) → \(request.resolvedTo ?? request.to)"
                    case "request_show":
                        let requestID = args["id"]?.stringValue ?? ""
                        guard let request = Requests(paths: paths).load(requestID) else { throw RequestError.notFound(requestID) }
                        text = String(decoding: try JSONCoding.encoder(pretty: true).encode(request), as: UTF8.self)
                    case "request_update":
                        text = try RequestActions.perform(action: args["action"]?.stringValue ?? "",
                            id: args["id"]?.stringValue ?? "", by: identity, result: args["result"]?.stringValue, paths: paths)
                    case "release":
                        try PathClaims(paths: paths).release(label: identity, project: project,
                            patterns: args["paths"]?.arrayValue?.compactMap(\.stringValue))
                        text = "released"
                    case "watch_add":
                        text = try Self.addWatch(kind: args["kind"]?.stringValue ?? "",
                            target: args["target"]?.stringValue ?? "",
                            note: args["note"]?.stringValue,
                            owner: identity, project: project, paths: paths)
                    case "watch_list":
                        let standing = Watches(paths: paths).pending().filter { $0.projectPath == project }
                        text = standing.isEmpty ? "nothing being watched" : standing.map { $0.listLine() }.joined(separator: "\n")
                    case "watch_rm":
                        let found = Watches(paths: paths).matching(prefix: args["id"]?.stringValue ?? "")
                        guard found.count == 1 else {
                            throw WatchError.ambiguous(prefix: args["id"]?.stringValue ?? "", count: found.count)
                        }
                        _ = try Watches(paths: paths).retire(ids: [found[0].id])
                        text = "called off: \(found[0].listLine())"
                    default:
                        Presence.record(label: identity, project: project, branch: nil,
                            task: args["task"]?.stringValue, paths: paths,
                            capabilities: args["capabilities"]?.arrayValue?.compactMap(\.stringValue))
                        text = "ok"
                    }
                    return toolReply(id, text)
                } catch { return toolReply(id, String(describing: error), isError: true) }
            }
            let mode: BriefingMode = name == "brief" ? .full : .delta
            let updates = AgentBus(paths: paths).briefing(
                sessionID: "mcp-\(identity)", me: identity, project: project, mode: mode)
            var sections = [String]()
            if mode == .full, let context = ProjectRegistry.sessionContext(for: project) {
                sections.append(context)
            }
            if let updates, !updates.isEmpty { sections.append(updates) }
            let text = sections.isEmpty ? "(nothing new)" : sections.joined(separator: "\n\n")
            result = .object(["content": .array([.object([
                "type": .string("text"), "text": .string(Redactor.scrub(text).text)
            ])])])
        case "ping": result = .object([:])
        default: return rpcError(id, -32601, "method not found")
        }
        return encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    private struct Tool {
        let name: String
        /// One line in `tools/list`: the catalogue is re-read often and every
        /// byte of it costs context on every turn, so this stays short. The
        /// rest lives in `details`, one `tool_help` call away.
        let description: String
        let details: String
        let fields: [String: String]
        var required: [String] = []
        var schema: JSONValue {
            var properties = fields.mapValues { type -> JSONValue in
                if type == "array" { return .object(["type": .string(type), "items": .object(["type": .string("string")])]) }
                return .object(["type": .string(type)])
            }
            if fields["action"] != nil {
                properties["action"] = .object(["type": .string("string"), "enum": .array(["accept", "done", "fail", "reject", "ack"].map(JSONValue.string))])
            }
            if fields["kind"] != nil {
                properties["kind"] = .object(["type": .string("string"), "enum": .array(["session-end", "session-idle", "task-done"].map(JSONValue.string))])
            }
            return .object(["type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        func validate(_ args: [String: JSONValue]) -> String? {
            for key in required where args[key] == nil { return "missing required argument: \(key)" }
            for (key, value) in args {
                guard let type = fields[key] else { return "unknown argument: \(key)" }
                switch (type, value) {
                case ("string", .string(let text)):
                    if required.contains(key) && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty argument: \(key)" }
                    if key == "action" && !["accept", "done", "fail", "reject", "ack"].contains(text) { return "invalid action" }
                    if key == "kind" && !["session-end", "session-idle", "task-done"].contains(text) { return "invalid kind" }
                case ("array", .array(let items)):
                    if items.contains(where: { $0.stringValue == nil }) { return "\(key) must contain strings" }
                    if required.contains(key) && items.isEmpty { return "\(key) must not be empty" }
                case ("number", .number(let number)):
                    guard number.isFinite, number > 0, number < Double(Int.max) / 60 else { return "\(key) is out of range" }
                    if key == "budget_minutes" && number.rounded() != number { return "budget_minutes must be an integer" }
                default: return "invalid type for \(key)"
                }
            }
            return nil
        }
    }
    private static let tools: [Tool] = [
        Tool(name: "brief", description: "Full briefing: sessions, claims, tasks, requests.", details: "Call at session start. Returns the whole picture for this project.", fields: ["project": "string"]),
        Tool(name: "status", description: "Only changes since your last brief/status.", details: "Cheap per-turn poll. Call after each commit. An empty answer means nothing new.", fields: ["project": "string"]),
        Tool(name: "claim", description: "Reserve paths before editing.", details: "Fails on another agent's claim. Intent is shown to the others. TTL in minutes, default 30.", fields: ["paths": "array", "intent": "string", "ttl_minutes": "number", "project": "string"], required: ["paths"]),
        Tool(name: "claim_check", description: "Ask whether paths are editable right now.", details: "Read-only pre-edit check (claims, ownership, request scope). No hook stops an MCP edit, so check before writing and claim what you touch.", fields: ["paths": "array", "project": "string"], required: ["paths"]),
        Tool(name: "release", description: "Release your claims.", details: "Omit paths to release everything you hold.", fields: ["paths": "array", "project": "string"]),
        Tool(name: "say", description: "Message another agent, or the human.", details: "`to` is a label, or omit it for everyone in the project.", fields: ["to": "string", "text": "string", "project": "string"], required: ["to", "text"]),
        Tool(name: "delegate", description: "Create a request by label or capability.", details: "Continue your work; do not wait. may_touch scopes the worker's paths; budget_minutes caps its time.", fields: ["to": "string", "title": "string", "spec": "string", "inputs": "array", "expected_output": "string", "may_touch": "array", "budget_minutes": "number", "project": "string"], required: ["to", "title", "spec"]),
        Tool(name: "request_show", description: "Read the full request spec.", details: "Returns the request as JSON.", fields: ["id": "string"], required: ["id"]),
        Tool(name: "request_update", description: "Accept, done, fail, reject or ack a request.", details: "Include result on done/fail.", fields: ["id": "string", "action": "string", "result": "string"], required: ["id", "action"]),
        Tool(name: "task_add", description: "Add a shared handoff task.", details: "Visible to every agent in the project.", fields: ["text": "string", "project": "string"], required: ["text"]),
        Tool(name: "task_done", description: "Mark a shared task done.", details: "By the task id.", fields: ["id": "string", "project": "string"], required: ["id"]),
        Tool(name: "precommit", description: "Check staged files against claims, ownership and request scope.", details: "Honest answer, never blocks by itself: the git hook blocks, this only reports.", fields: ["project": "string"]),
        Tool(name: "presence", description: "Announce liveness, current task and capabilities.", details: "Call at session start and when the task changes, so `who` stays true.", fields: ["task": "string", "capabilities": "array", "project": "string"]),
        Tool(name: "watch_add", description: "Ask once to be told when something happens.", details: "kind is session-end, session-idle or task-done. Fires once, lapses in 48h.", fields: ["kind": "string", "target": "string", "note": "string", "project": "string"], required: ["kind", "target"]),
        Tool(name: "watch_list", description: "Standing watches in this project.", details: "One line per watch, with its id prefix for watch_rm.", fields: ["project": "string"]),
        Tool(name: "watch_rm", description: "Call off a watch by id prefix.", details: "Only your own watches.", fields: ["id": "string", "project": "string"], required: ["id"]),
        Tool(name: "tool_help", description: "Full docs for one tool.", details: "Arguments, required flags and the rules the blurb leaves out.", fields: ["name": "string"], required: ["name"]),
    ]

    /// The `watch add` half of the CLI's `watch` command, minus the terminal:
    /// same task resolution, same refusals, same scrubbed note.
    static func addWatch(kind: String, target: String, note: String?, owner: String, project: String, paths: Paths) throws -> String {
        guard let resolved = WatchRule.Kind(rawValue: kind) else { throw WatchError.badKind(kind) }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WatchError.noTarget }
        var ruleTarget = trimmed
        let subject: String
        switch resolved {
        case .taskDone:
            let handoff = ProjectRegistry.handoff(for: project, refreshingCommits: false)
            guard let task = handoff.tasks.first(where: { $0.id == trimmed })
                ?? handoff.tasks.first(where: { $0.text.lowercased().contains(trimmed.lowercased()) })
            else { throw WatchError.noSuchTask(trimmed) }
            guard !task.done else { throw WatchError.alreadyDone(task.text) }
            ruleTarget = task.id
            subject = "“\(task.text)” is ticked off"
        case .sessionEnd:
            subject = "\(trimmed)'s session ends"
        case .sessionIdle:
            subject = "\(trimmed) finishes a turn"
        }
        var noteText: String?
        if let note {
            let scrubbed = Redactor.scrub(note)
            guard !scrubbed.isSuppressed else { throw WatchError.onlyASecret }
            noteText = scrubbed.text
        }
        let rule = WatchRule(owner: owner, projectPath: project, kind: resolved, target: ruleTarget, note: noteText)
        try Watches(paths: paths).add(rule)
        return "watching: \(subject) → \(owner) (id \(rule.shortID))"
    }

    enum WatchError: Error, CustomStringConvertible {
        case badKind(String)
        case noTarget
        case noSuchTask(String)
        case alreadyDone(String)
        case onlyASecret
        case ambiguous(prefix: String, count: Int)

        var description: String {
            switch self {
            case .badKind(let kind): return "unknown kind \"\(kind)\" — say session-end, session-idle or task-done"
            case .noTarget: return "name a session, label or task to watch"
            case .noSuchTask(let target): return "no task matching “\(target)”"
            case .alreadyDone(let text): return "already done: \(text)"
            case .onlyASecret: return "not watched — that note was almost entirely secret"
            case .ambiguous(let prefix, let count):
                return count == 0
                    ? "no standing watch starting with “\(prefix)”"
                    : "“\(prefix)” names \(count) watches — say more of the id"
            }
        }
    }
    private func rpcError(_ id: JSONValue, _ code: Int, _ message: String) -> String {
        encode(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
            "code": .number(Double(code)), "message": .string(Redactor.scrub(message).text)])]))
    }
    private func toolReply(_ id: JSONValue, _ text: String, isError: Bool = false) -> String {
        encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object([
            "isError": .bool(isError), "content": .array([.object([
                "type": .string("text"), "text": .string(Redactor.scrub(text).text)])])])]))
    }
    private func encode(_ value: JSONValue) -> String {
        String(decoding: (try? JSONCoding.encoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
    public func serve() {
        while let line = readLine() {
            if let response = handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}
