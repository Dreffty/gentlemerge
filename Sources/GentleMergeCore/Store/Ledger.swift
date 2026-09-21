import Foundation

/// Append-only record of what arrived, what you authorized, and how long the
/// agent sat there waiting. Plain JSONL so it stays greppable without the app.
public struct LedgerEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case received
        case handled
        case expired
        case resolved
        case note
    }

    public var id: String
    public var at: Date
    public var kind: Kind
    public var itemID: String?
    public var sessionID: String?
    public var provider: AgentProvider
    public var project: String?
    public var title: String?
    public var summary: String?
    public var reason: String?
    public var waitedSeconds: Double?
    /// Only on `briefing.injected`: which briefing mode was handed out.
    public var mode: String?
    /// Only on `briefing.injected`: how many characters went into the turn.
    public var chars: Int?
    /// Schema version of this line. Old lines without it decode as 1.
    public var v: Int = 1

    enum CodingKeys: String, CodingKey {
        case id, at, kind, itemID, sessionID, provider, project, title, summary, reason, waitedSeconds, mode, chars, v
    }

    /// Hand-written so a missing `v` (every line written before versions)
    /// decodes as 1 instead of dropping history.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        kind = try c.decode(Kind.self, forKey: .kind)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        provider = (try? c.decodeIfPresent(AgentProvider.self, forKey: .provider)) ?? .unknown
        project = try c.decodeIfPresent(String.self, forKey: .project)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        waitedSeconds = try c.decodeIfPresent(Double.self, forKey: .waitedSeconds)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        chars = try c.decodeIfPresent(Int.self, forKey: .chars)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
    }

    public init(
        id: String = UUID().uuidString,
        at: Date = Date(),
        kind: Kind,
        itemID: String? = nil,
        sessionID: String? = nil,
        provider: AgentProvider = .unknown,
        project: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        reason: String? = nil,
        waitedSeconds: Double? = nil,
        mode: String? = nil,
        chars: Int? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.itemID = itemID
        self.sessionID = sessionID
        self.provider = provider
        self.project = project
        self.title = title
        self.summary = summary
        self.reason = reason
        self.waitedSeconds = waitedSeconds
        self.mode = mode
        self.chars = chars
    }
}

public struct Ledger: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ entry: LedgerEntry) {
        do {
            let data = try JSONCoding.encoder().encode(entry)
            guard let line = String(data: data, encoding: .utf8) else { return }
            try AtomicFile.append(line, to: url)
        } catch {
            // The ledger is a record, not a dependency: never break the inbox
            // because we could not write history.
            Log.error("ledger append failed: \(error.localizedDescription)")
        }
    }

    public func record(_ item: InboxItem, kind: LedgerEntry.Kind, reason: String? = nil) {
        append(
            LedgerEntry(
                at: Date(),
                kind: kind,
                itemID: item.id,
                sessionID: item.sessionID,
                provider: item.provider,
                project: item.projectPath,
                title: item.title,
                summary: item.summary,
                reason: reason,
                waitedSeconds: nil
            )
        )
    }

    /// Newest first, capped — the history pane never needs the whole file.
    public func recent(limit: Int = 200) -> [LedgerEntry] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONCoding.decoder()
        return contents
            .split(separator: "\n")
            .suffix(limit * 2)
            .reversed()
            .compactMap { line -> LedgerEntry? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(LedgerEntry.self, from: data)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Move lines older than the window into the archive, so the hot file —
    /// the one every history pane and stats scan reads — stays bounded while
    /// totals survive (Stats reads both). A line that does not decode stays
    /// where it is: never lose history to a parse failure.
    ///
    /// Archive first, rewrite second, both under the sidecar lock: a crash in
    /// between can double-count a line, which beats silently dropping it.
    public func archive(paths: Paths, olderThan: TimeInterval = 90 * 24 * 3600, now: Date = Date()) {
        do {
            try LockedFile.withExclusiveLock(url) {
                guard let contents = try? String(contentsOf: url, encoding: .utf8),
                      !contents.isEmpty
                else { return }
                let decoder = JSONCoding.decoder()
                var kept: [String] = []
                var moved: [String] = []
                kept.reserveCapacity(1024)
                for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = String(raw)
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let data = line.data(using: .utf8),
                          let entry = try? decoder.decode(LedgerEntry.self, from: data)
                    else {
                        kept.append(line)
                        continue
                    }
                    if now.timeIntervalSince(entry.at) > olderThan {
                        moved.append(line)
                    } else {
                        kept.append(line)
                    }
                }
                guard !moved.isEmpty else { return }
                for line in moved {
                    try AtomicFile.append(line, to: paths.ledgerArchive)
                }
                // Trailing newline, always: the next append writes "line\n",
                // and without it the two would fuse into one unparseable line.
                var text = kept.joined(separator: "\n")
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                try AtomicFile.write(Data(text.utf8), to: url)
            }
        } catch {
            Log.error("ledger archive failed: \(error.localizedDescription)")
        }
    }
}

enum Log {
    nonisolated(unsafe) static var fileURL: URL?

    static func error(_ message: String) { write("ERROR", message) }
    static func info(_ message: String) { write("INFO", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter.gentleMerge.string(from: Date())) [\(level)] \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        if let fileURL {
            try? AtomicFile.append(line, to: fileURL)
        }
    }
}
