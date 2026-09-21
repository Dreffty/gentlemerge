import Foundation

/// What a hook script drops into the spool directory: a thin, stable wrapper
/// (written by us) around the agent's raw payload (written by them).
///
/// Everything except `id` is optional on purpose — a malformed envelope should
/// still surface as *something* in the inbox rather than vanish.
public struct SpoolEnvelope: Codable, Sendable, Equatable {
    public var schema: Int
    public var id: String
    public var provider: AgentProvider
    public var receivedAt: Date
    public var cwd: String?
    public var tty: String?
    public var pid: Int?
    public var terminalProgram: String?
    public var terminalSessionID: String?
    /// The session's own inbox socket (Claude Code ≥ 2.1.224 exports
    /// CLAUDE_CODE_MESSAGING_SOCKET to its hooks). A notice delivered there
    /// arrives even while the session is idle.
    public var socket: String?
    public var payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case schema
        case id
        case provider
        case receivedAt = "received_at"
        case cwd
        case tty
        case pid
        case terminalProgram = "term_program"
        case terminalSessionID = "term_session_id"
        case socket
        case payload
    }

    public init(
        schema: Int = 1,
        id: String = UUID().uuidString,
        provider: AgentProvider = .unknown,
        receivedAt: Date = Date(),
        cwd: String? = nil,
        tty: String? = nil,
        pid: Int? = nil,
        terminalProgram: String? = nil,
        terminalSessionID: String? = nil,
        socket: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.schema = schema
        self.id = id
        self.provider = provider
        self.receivedAt = receivedAt
        self.cwd = cwd
        self.tty = tty
        self.pid = pid
        self.terminalProgram = terminalProgram
        self.terminalSessionID = terminalSessionID
        self.socket = socket
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? container.decode(Int.self, forKey: .schema)) ?? 1
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        provider = (try? container.decode(AgentProvider.self, forKey: .provider)) ?? .unknown
        receivedAt = SpoolEnvelope.decodeDate(container, .receivedAt) ?? Date()
        cwd = SpoolEnvelope.decodeNonEmptyString(container, .cwd)
        tty = SpoolEnvelope.decodeNonEmptyString(container, .tty)
        terminalProgram = SpoolEnvelope.decodeNonEmptyString(container, .terminalProgram)
        terminalSessionID = SpoolEnvelope.decodeNonEmptyString(container, .terminalSessionID)
        socket = SpoolEnvelope.decodeNonEmptyString(container, .socket)
        payload = (try? container.decode(JSONValue.self, forKey: .payload)) ?? .object([:])

        // Shell writes numbers as strings often enough that we accept both.
        if let value = try? container.decode(Int.self, forKey: .pid) {
            pid = value
        } else if let text = try? container.decode(String.self, forKey: .pid) {
            pid = Int(text)
        } else {
            pid = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(ISO8601DateFormatter.gentleMerge.string(from: receivedAt), forKey: .receivedAt)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(tty, forKey: .tty)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(terminalProgram, forKey: .terminalProgram)
        try container.encodeIfPresent(terminalSessionID, forKey: .terminalSessionID)
        try container.encodeIfPresent(socket, forKey: .socket)
        try container.encode(payload, forKey: .payload)
    }

    // MARK: - Payload shortcuts

    public var eventName: String? {
        payload.string("hook_event_name") ?? payload.string("type")
    }

    public var sessionID: String? {
        payload.string("session_id") ?? payload.string("session-id") ?? payload.string("turn-id")
    }

    /// The agent's own idea of the project wins; the hook's `$PWD` is a fallback
    /// for agents that do not report one.
    public var workingDirectory: String? {
        payload.string("cwd")?.nonEmpty ?? cwd
    }

    // MARK: - Helpers

    private static func decodeNonEmptyString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String? {
        guard let value = try? container.decode(String.self, forKey: key), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Date? {
        guard let text = decodeNonEmptyString(container, key) else { return nil }
        return ISO8601DateFormatter.gentleMerge.date(from: text)
            ?? ISO8601DateFormatter.gentleMergeFractional.date(from: text)
            ?? Double(text).map { Date(timeIntervalSince1970: $0) }
    }
}

extension ISO8601DateFormatter {
    // Configured once and never mutated again; Foundation's formatters are safe
    // to read concurrently, which is all we ever do with these.
    nonisolated(unsafe) public static let gentleMerge: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) static let gentleMergeFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
