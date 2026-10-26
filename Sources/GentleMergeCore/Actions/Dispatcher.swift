import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Executes only locally configured commands; callers must first apply DispatchGate.
public struct Dispatcher: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// Headless minutes already spent today, off `dispatch.start` lines. Old
    /// lines without a budget count zero rather than breaking the total.
    ///
    /// Memoised on the ledger's size and mtime, the same fingerprint
    /// `Stats.summaries` uses: this runs on the app's 3-second tick, on the main
    /// actor, and decoding every line of the ledger each time made the tick cost
    /// ~2 seconds on a 50k-line ledger — with or without any request assigned
    /// (audit 2026-10-11). The parse is the expensive half; filtering what was
    /// parsed by day is not.
    public static func spentTodayMinutes(paths: Paths, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        return cachedStarts(paths: paths).compactMap { entry -> Int? in
            guard let at = entry.at, calendar.isDate(at, inSameDayAs: now),
                  let summary = entry.summary,
                  let range = summary.range(of: "budget "),
                  let minutes = Int(summary[range.upperBound...].prefix(while: \.isNumber))
            else { return nil }
            return minutes
        }.reduce(0, +)
    }

    /// One `dispatch.start` line, reduced to what the total needs.
    private struct Start: Decodable {
        var title: String?
        var at: Date?
        var summary: String?
    }

    private static let cacheLock = NSLock()
    /// Guarded by `cacheLock` on every access. The parse happens outside it, so
    /// a slow ledger never holds it.
    ///
    /// Keyed on the path as well as the size and mtime: the fingerprint alone
    /// collides between two different ledgers of the same age and length, and a
    /// caller would then be answered with the other file's total.
    nonisolated(unsafe) private static var cache: (fingerprint: Fingerprint?, starts: [Start])?

    private struct Fingerprint: Equatable {
        var path: String
        var size: UInt64
        var mtime: Date
    }

    private static func fingerprint(of url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              let mtime = attributes[.modificationDate] as? Date
        else { return nil }
        return Fingerprint(path: url.path, size: size, mtime: mtime)
    }

    private static func cachedStarts(paths: Paths) -> [Start] {
        let fingerprint = Self.fingerprint(of: paths.ledger)

        cacheLock.lock()
        if let cache, cache.fingerprint == fingerprint {
            let cached = cache.starts
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Outside the lock: a 50k-line ledger takes long enough that holding it
        // would serialise the whole sweep, and re-parsing it in a race is
        // harmless — the result is a pure function of the file.
        let starts: [Start] = {
            guard let contents = try? String(contentsOf: paths.ledger, encoding: .utf8) else { return [] }
            let decoder = JSONCoding.decoder()
            return contents.split(separator: "\n").compactMap { line in
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(Start.self, from: data),
                      entry.title == "dispatch.start"
                else { return nil }
                return entry
            }
        }()

        cacheLock.lock()
        cache = (fingerprint, starts)
        cacheLock.unlock()
        return starts
    }

    /// Takes the one start a request is allowed, for every process at once.
    ///
    /// "Already dispatched" lived in each process's memory, so every `brief`,
    /// `claims` or `precommit` — each a fresh process that drains the spool — saw
    /// the same assigned request and started the headless agent again: three read
    /// commands, three `dispatch.start` lines and three child processes for one
    /// request, each spending the daily budget. A restart of the app did the same.
    /// An exclusive create settles it on disk: whoever creates the marker starts the
    /// agent, everybody else leaves it alone.
    public func claimStart(of requestID: String) -> Bool {
        guard Requests.validID(requestID) else { return false }
        try? FileManager.default.createDirectory(at: paths.dispatch, withIntermediateDirectories: true)
        let marker = paths.dispatch.appendingPathComponent("\(requestID).started")
        let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
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
                let note = output.succeeded
                    ? "process exited without reporting; see \(log.lastPathComponent)"
                    : "process failed/timed out (exit \(output.status)); see \(log.lastPathComponent)"
                // Through RequestActions, not `store.transition`. Every other
                // state change on a request also releases the delegate's
                // may_touch claims, ticks the backing task and posts a result
                // back to the delegator; going straight to the store did none of
                // the three. So a headless delegate that timed out left its
                // claims blocking other agents until their TTL, its task open,
                // and the requester with no result line — the README's
                // "automatic callback" never fired for the most common dispatch
                // failure (audit Tier 4 #18).
                do {
                    _ = try RequestActions.perform(
                        action: current.state == .assigned ? "reject" : "fail",
                        id: request.id,
                        by: target.label,
                        result: note,
                        paths: paths
                    )
                } catch {
                    // The process is gone either way; failing to record that is
                    // worth a line, not a crash in a detached task.
                    Log.error("could not record the end of \(request.id): \(error.localizedDescription)")
                }
            }
            Ledger(url: paths.ledger).append(LedgerEntry(kind: .note, itemID: request.id,
                title: "dispatch.end", summary: "exit \(output.status)"))
        }
    }
}
