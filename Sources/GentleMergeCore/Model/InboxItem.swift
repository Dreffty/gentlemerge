import Foundation

public enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case unknown

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .unknown: return "Agent"
        }
    }

    public var symbolName: String {
        switch self {
        case .claudeCode: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Why a session showed up in the inbox. Nothing here gates an agent: Claude
/// Code already asks for its own permissions, and doing it twice is worse than
/// not doing it at all.
public enum InboxKind: String, Codable, Sendable {
    /// The agent asked something and is waiting in its own terminal.
    case question
    /// The agent stopped and the turn is yours.
    case idle
    case failure
    /// Session lifecycle and anything we could not classify.
    case info

    public var priority: Int {
        switch self {
        case .question: return 0
        case .failure: return 1
        case .idle: return 2
        case .info: return 3
        }
    }

    public var symbolName: String {
        switch self {
        case .question: return "bubble.left.and.bubble.right.fill"
        case .idle: return "pause.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }
}

public enum InboxStatus: String, Codable, Sendable {
    case pending
    /// You dealt with it, here or in the terminal.
    case handled
    /// The session moved on by itself.
    case superseded
}

/// One thing an agent session did that you might want to know about.
public struct InboxItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var sessionID: String?
    public var provider: AgentProvider
    public var kind: InboxKind
    public var status: InboxStatus
    public var eventName: String?

    public var title: String
    public var summary: String
    public var detail: String?
    public var toolName: String?

    public var projectPath: String?
    public var tty: String?
    public var terminalProgram: String?
    public var pid: Int?
    public var transcriptPath: String?

    public var createdAt: Date
    public var updatedAt: Date

    public var payload: JSONValue

    /// Files and directories the call named, and whether they stay inside the
    /// project. Shown as information, never used to block anything.
    public var touchedPaths: [String]?
    public var scope: PathScope?

    public init(
        id: String,
        sessionID: String? = nil,
        provider: AgentProvider = .unknown,
        kind: InboxKind = .info,
        status: InboxStatus = .pending,
        eventName: String? = nil,
        title: String,
        summary: String = "",
        detail: String? = nil,
        toolName: String? = nil,
        projectPath: String? = nil,
        tty: String? = nil,
        terminalProgram: String? = nil,
        pid: Int? = nil,
        transcriptPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        payload: JSONValue = .object([:]),
        touchedPaths: [String]? = nil,
        scope: PathScope? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.provider = provider
        self.kind = kind
        self.status = status
        self.eventName = eventName
        self.title = title
        self.summary = summary
        self.detail = detail
        self.toolName = toolName
        self.projectPath = projectPath
        self.tty = tty
        self.terminalProgram = terminalProgram
        self.pid = pid
        self.transcriptPath = transcriptPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payload = payload
        self.touchedPaths = touchedPaths
        self.scope = scope
    }

    public var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "—" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public var isPending: Bool { status == .pending }

    public var paths: [String] { touchedPaths ?? [] }

    public var reachesOutsideProject: Bool { scope == .outside }

    /// Oldest first within a kind: the session that has been stuck longest is
    /// the one you should look at.
    public static func ordered(_ lhs: InboxItem, _ rhs: InboxItem) -> Bool {
        if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority < rhs.kind.priority }
        return lhs.createdAt < rhs.createdAt
    }
}
