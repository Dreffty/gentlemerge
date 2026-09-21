import Foundation

/// What we know about a live agent session. The important field is the
/// baseline: the commit the project was on when the session started, which is
/// what makes "what did this session change" answerable later.
public struct SessionRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var provider: AgentProvider
    public var projectPath: String?
    public var startedAt: Date
    public var lastSeenAt: Date
    public var baselineCommit: String?
    public var endedAt: Date?
    /// Where the session actually runs. Every envelope carries these and we
    /// used to throw them away; the pid is what lets anyone tell a session that
    /// finished from one that was killed, and the terminal is how the app finds
    /// the window again. All optional, so records written before this decode
    /// unchanged and an older binary ignores the new keys.
    public var pid: Int?
    public var tty: String?
    public var terminalProgram: String?

    public var isLive: Bool { endedAt == nil }
}

public struct SessionRegistry: Sendable {
    public private(set) var sessions: [String: SessionRecord]
    private let url: URL

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONCoding.decoder().decode([String: SessionRecord].self, from: data) {
            sessions = stored
        } else {
            sessions = [:]
        }
    }

    public subscript(id: String) -> SessionRecord? { sessions[id] }

    public mutating func started(
        id: String,
        provider: AgentProvider,
        projectPath: String?,
        at date: Date,
        pid: Int? = nil,
        tty: String? = nil,
        terminalProgram: String? = nil
    ) {
        sessions[id] = SessionRecord(
            id: id,
            provider: provider,
            projectPath: projectPath,
            startedAt: date,
            lastSeenAt: date,
            baselineCommit: Self.head(of: projectPath),
            pid: pid,
            tty: tty,
            terminalProgram: terminalProgram
        )
        prune()
        save()
    }

    /// Every event keeps a session alive; a session we never saw start still
    /// gets a record, just without a baseline we can trust.
    public mutating func seen(
        id: String,
        provider: AgentProvider,
        projectPath: String?,
        at date: Date,
        pid: Int? = nil,
        tty: String? = nil,
        terminalProgram: String? = nil
    ) {
        if var existing = sessions[id] {
            existing.lastSeenAt = date
            if existing.projectPath == nil { existing.projectPath = projectPath }
            // A session keeps the process and terminal it started in, so the
            // last event to carry them wins only over not knowing.
            existing.pid = existing.pid ?? pid
            existing.tty = existing.tty ?? tty
            existing.terminalProgram = existing.terminalProgram ?? terminalProgram
            sessions[id] = existing
        } else {
            sessions[id] = SessionRecord(
                id: id,
                provider: provider,
                projectPath: projectPath,
                startedAt: date,
                lastSeenAt: date,
                baselineCommit: nil,
                pid: pid,
                tty: tty,
                terminalProgram: terminalProgram
            )
            prune()
        }
        save()
    }

    public mutating func ended(id: String, at date: Date) {
        guard var record = sessions[id] else { return }
        record.endedAt = date
        record.lastSeenAt = date
        sessions[id] = record
        save()
    }

    public func baseline(for sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        return sessions[sessionID]?.baselineCommit
    }

    static func head(of projectPath: String?) -> String? {
        guard let projectPath, GitSnapshot.isRepository(projectPath) else { return nil }
        let output = Shell.run(
            "/usr/bin/env",
            ["git", "rev-parse", "HEAD"],
            in: URL(fileURLWithPath: projectPath),
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeout: 10
        )
        let commit = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    private mutating func prune(keeping limit: Int = 200) {
        guard sessions.count > limit else { return }
        let doomed = sessions.values
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .dropFirst(limit)
            .map(\.id)
        for id in doomed { sessions.removeValue(forKey: id) }
    }

    private func save() {
        do {
            try AtomicFile.write(try JSONCoding.encoder().encode(sessions), to: url)
        } catch {
            Log.error("could not save sessions: \(error.localizedDescription)")
        }
    }
}
