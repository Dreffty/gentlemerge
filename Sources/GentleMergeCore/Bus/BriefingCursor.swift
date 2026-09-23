import Foundation

/// Per-session memory of what the briefing already told this session.
/// Lives in delivered/<sessionID>/cursor.json: that directory is already
/// written only by this session's hook, so no lock is needed.
public struct BriefingCursor: Codable, Sendable, Equatable {
    public var sessionID: String
    public var lastFullAt: Date?
    public var lastDeltaAt: Date?
    /// ProjectMap seal (HEAD sha) last shown; map is re-shown only if it changed.
    public var mapSeal: String?
    /// Path claim ids already announced to this session.
    public var seenClaimIDs: Set<String>
    /// requestID -> last state announced. Lets us announce only transitions.
    public var seenRequestStates: [String: String]
    /// Watch ids already announced.
    public var seenWatchIDs: Set<String>
    /// Last message sequence delivered contiguously to this session.
    /// Nil means nothing sequenced was ever delivered (every cursor written
    /// before sequences). Kept alongside the timestamp marker so a session
    /// that upgrades mid-log does not replay or lose mail.
    /// Global fallback for migration: pre-per-project markers only have this.
    /// New writes go per-project (see below); reads take max(perProject, global).
    public var lastDeliveredSequence: UInt64?
    /// Per-project watermark: project key (`projectPath ?? ""`, "" = global read)
    /// -> last contiguous sequence delivered in that scope. Isolates projects:
    /// advancing project A must never skip project B's pending. Missing key =
    /// never read in that scope (fall back to global for migration, then deliver all).
    public var lastDeliveredSequenceByProject: [String: UInt64]?
    /// Per-project timestamp floor for pre-sequence lines, same keying.
    /// Global `lastMessageAt` lives in DeliveryMarker (cursor has no message floor);
    /// this dict mirrors it per-project for old nil-sequence mail.
    /// Note: cursor never had a message timestamp floor; this is new for isolation.
    /// Kept here (not only in marker) so both stores pin the log for prune.
    public var lastMessageAtByProject: [String: Date]?

    public init(sessionID: String) {
        self.sessionID = sessionID
        self.seenClaimIDs = []
        self.seenRequestStates = [:]
        self.seenWatchIDs = []
        self.lastDeliveredSequence = nil
        self.lastDeliveredSequenceByProject = nil
        self.lastMessageAtByProject = nil
    }

    // Forgiving decode: a cursor from an older binary must still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        lastFullAt = try c.decodeIfPresent(Date.self, forKey: .lastFullAt)
        lastDeltaAt = try c.decodeIfPresent(Date.self, forKey: .lastDeltaAt)
        mapSeal = try c.decodeIfPresent(String.self, forKey: .mapSeal)
        seenClaimIDs = try c.decodeIfPresent(Set<String>.self, forKey: .seenClaimIDs) ?? []
        seenRequestStates = try c.decodeIfPresent([String: String].self, forKey: .seenRequestStates) ?? [:]
        seenWatchIDs = try c.decodeIfPresent(Set<String>.self, forKey: .seenWatchIDs) ?? []
        lastDeliveredSequence = try c.decodeIfPresent(UInt64.self, forKey: .lastDeliveredSequence)
        lastDeliveredSequenceByProject = try c.decodeIfPresent([String: UInt64].self, forKey: .lastDeliveredSequenceByProject)
        lastMessageAtByProject = try c.decodeIfPresent([String: Date].self, forKey: .lastMessageAtByProject)
    }

    /// Anchor for "new since": the later of the two injections.
    public var since: Date? {
        switch (lastFullAt, lastDeltaAt) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

public struct BriefingCursorStore: Sendable {
    let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    func url(for sessionID: String) -> URL {
        // Same remap as the delivery markers: the id is agent-controlled.
        paths.delivered.appendingPathComponent(AgentBus.fileSafeSessionID(sessionID), isDirectory: true)
            .appendingPathComponent("cursor.json")
    }

    public func load(sessionID: String) -> BriefingCursor {
        let u = url(for: sessionID)
        guard let data = try? Data(contentsOf: u),
              let c = try? JSONCoding.decoder().decode(BriefingCursor.self, from: data)
        else { return BriefingCursor(sessionID: sessionID) }
        return c
    }

    public func save(_ cursor: BriefingCursor) {
        let u = url(for: cursor.sessionID)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONCoding.encoder(pretty: false).encode(cursor) {
            try? AtomicFile.write(data, to: u)
        }
    }
}
