import Foundation

/// Executes only locally configured commands; callers must first apply DispatchGate.
public struct Dispatcher: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// Headless minutes already spent today, off `dispatch.start` lines. Old
    /// lines without a budget count zero rather than breaking the total.
    public static func spentTodayMinutes(paths: Paths, now: Date = Date()) -> Int {
        struct Line: Decodable { var title: String?; var summary: String?; var at: Date? }
        guard let contents = try? String(contentsOf: paths.ledger, encoding: .utf8) else { return 0 }
        let calendar = Calendar.current
        let decoder = JSONCoding.decoder()
        var total = 0
        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(Line.self, from: data),
                  entry.title == "dispatch.start",
                  let at = entry.at, calendar.isDate(at, inSameDayAs: now),
                  let summary = entry.summary,
                  let range = summary.range(of: "budget "),
                  let minutes = Int(summary[range.upperBound...].prefix(while: \.isNumber))
            else { continue }
            total += minutes
        }
        return total
    }

    public func promptText(for r: AgentRequest) -> String {
        Redactor.scrub("""
        You are agent '\(r.resolvedTo ?? r.to)'. Delegated request \(r.id) from '\(r.from)'.
        Title: \(r.title)
        Spec: \(r.spec)
        Inputs: \(r.inputs.joined(separator: ", "))
        Expected output: \(r.expectedOutput ?? "-")
        You may ONLY modify: \(r.mayTouch.isEmpty ? "(unrestricted; stay minimal)" : r.mayTouch.joined(separator: ", ")).
        Budget: \(r.budgetMinutes) minutes.
        Run `gentlemerge request accept \(r.id)` first. Commit with a clear message.
        Finish with `gentlemerge request done \(r.id) --result "<paths and commit sha>"`,
        or `gentlemerge request fail \(r.id) --result "<why>"`.
        Do not read or modify other agents' work. Respect path claims and pre-commit checks.
        """).text
    }

    @discardableResult
    public func run(_ request: AgentRequest, target: AgentTarget) throws -> Task<Void, Never> {
        guard Requests.validID(request.id) else { throw RequestError.invalidID }
        try FileManager.default.createDirectory(at: paths.dispatch, withIntermediateDirectories: true)
        let promptFile = paths.dispatch.appendingPathComponent("\(request.id).prompt.md")
        let prompt = promptText(for: request)
        try AtomicFile.write(Data(prompt.utf8), to: promptFile)
        let worktree = target.worktree ?? request.projectPath
        let argv = (target.command ?? []).map { argument in
            argument == "@{prompt_file}" ? prompt : argument
                .replacingOccurrences(of: "{prompt_file}", with: promptFile.path)
                .replacingOccurrences(of: "{worktree}", with: worktree)
                .replacingOccurrences(of: "{request_id}", with: request.id)
        }
        let paths = self.paths
        Ledger(url: paths.ledger).append(LedgerEntry(kind: .note, itemID: request.id, title: "dispatch.start", summary: "budget \(request.budgetMinutes)m"))
        return Task.detached(priority: .background) {
            let output = Shell.run("/usr/bin/env", argv,
                in: URL(fileURLWithPath: target.worktree ?? request.projectPath),
                environment: ["GENTLEMERGE_LABEL": target.label, "GENTLEMERGE_HOME": paths.home.path],
                timeout: Double(request.budgetMinutes) * 60)
            let log = paths.dispatch.appendingPathComponent("\(request.id).log")
            try? AtomicFile.write(Data(Redactor.scrub(output.stdout + "\n--- stderr ---\n" + output.stderr).text.utf8), to: log)
            let store = Requests(paths: paths)
            if let current = store.load(request.id), current.state == .assigned || current.state == .inProgress {
                _ = try? store.transition(request.id, to: current.state == .assigned ? .rejected : .failed,
                    by: target.label, result: output.succeeded
                        ? "process exited without reporting; see \(log.lastPathComponent)"
                        : "process failed/timed out (exit \(output.status)); see \(log.lastPathComponent)")
            }
            Ledger(url: paths.ledger).append(LedgerEntry(kind: .note, itemID: request.id,
                title: "dispatch.end", summary: "exit \(output.status)"))
        }
    }
}
