import Foundation

public enum RequestState: String, Codable, Sendable, CaseIterable {
    case queued
    case assigned
    case inProgress = "in_progress"
    case done
    case failed
    case rejected
    case acked

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .rejected, .acked: return true
        case .queued, .assigned, .inProgress: return false
        }
    }
}

public struct AgentRequest: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var from: String
    public var fromVerified: Bool
    public var to: String
    public var resolvedTo: String?
    public var projectPath: String
    public var title: String
    public var spec: String
    public var inputs: [String]
    public var expectedOutput: String?
    public var mayTouch: [String]
    public var budgetMinutes: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var state: RequestState
    public var result: String?
    public var taskID: String?
    public var watchID: String?

    /// A letter before the random suffix prevents all-digit UUID prefixes from
    /// being scrubbed as long numbers when request IDs appear in bus messages.
    public static func makeID(from uuid: UUID = UUID()) -> String {
        "req-r" + uuid.uuidString.lowercased().prefix(8)
    }

    public init(
        id: String = AgentRequest.makeID(),
        from: String,
        fromVerified: Bool,
        to: String,
        projectPath: String,
        title: String,
        spec: String,
        inputs: [String] = [],
        expectedOutput: String? = nil,
        mayTouch: [String] = [],
        budgetMinutes: Int = 30,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        state: RequestState = .queued,
        result: String? = nil,
        taskID: String? = nil,
        watchID: String? = nil
    ) {
        self.id = String(id)
        self.from = from
        self.fromVerified = fromVerified
        self.to = to
        self.resolvedTo = nil
        self.projectPath = projectPath
        self.title = title
        self.spec = spec
        self.inputs = inputs
        self.expectedOutput = expectedOutput
        self.mayTouch = mayTouch
        self.budgetMinutes = budgetMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.state = state
        self.result = result
        self.taskID = taskID
        self.watchID = watchID
    }

    enum CodingKeys: String, CodingKey {
        case id, from, fromVerified, to, resolvedTo, projectPath, title, spec, inputs
        case expectedOutput, mayTouch, budgetMinutes, createdAt, updatedAt, state
        case result, taskID, watchID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        from = try c.decode(String.self, forKey: .from)
        fromVerified = try c.decodeIfPresent(Bool.self, forKey: .fromVerified) ?? false
        to = try c.decode(String.self, forKey: .to)
        resolvedTo = try c.decodeIfPresent(String.self, forKey: .resolvedTo)
        projectPath = try c.decode(String.self, forKey: .projectPath)
        title = try c.decode(String.self, forKey: .title)
        spec = try c.decodeIfPresent(String.self, forKey: .spec) ?? ""
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? []
        expectedOutput = try c.decodeIfPresent(String.self, forKey: .expectedOutput)
        mayTouch = try c.decodeIfPresent([String].self, forKey: .mayTouch) ?? []
        budgetMinutes = try c.decodeIfPresent(Int.self, forKey: .budgetMinutes) ?? 30
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        let raw = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        state = RequestState(rawValue: raw) ?? .queued
        result = try c.decodeIfPresent(String.self, forKey: .result)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
        watchID = try c.decodeIfPresent(String.self, forKey: .watchID)
    }

    public var busSummary: String {
        var s = "[\(id)] \(title)"
        if let expectedOutput { s += " -> \(expectedOutput)" }
        if !mayTouch.isEmpty { s += " · may touch: \(mayTouch.joined(separator: ", "))" }
        s += " · budget \(budgetMinutes)m"
        return s
    }
}

public struct Requests: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func url(_ id: String) -> URL {
        paths.requests.appendingPathComponent("\(id).json")
    }

    public func freshID() -> String {
        var id: String
        repeat {
            id = AgentRequest.makeID()
        } while FileManager.default.fileExists(atPath: url(id).path)
        return id
    }

    public static func validID(_ id: String) -> Bool {
        id.hasPrefix("req-") && id.count <= 80 && id.count > 4
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    public func load(_ id: String) -> AgentRequest? {
        guard Self.validID(id) else { return nil }
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONCoding.decoder().decode(AgentRequest.self, from: data)
    }

    public func all() -> [AgentRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.requests, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AgentRequest? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONCoding.decoder().decode(AgentRequest.self, from: data)
            }
            .filter { Self.validID($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ request: AgentRequest) throws {
        guard Self.validID(request.id) else { throw RequestError.invalidID }
        try FileManager.default.createDirectory(at: paths.requests, withIntermediateDirectories: true)
        try LockedFile.withExclusiveLock(url(request.id)) {
            var request = request
            request.updatedAt = Date()
            try AtomicFile.write(try JSONCoding.encoder(pretty: true).encode(request), to: url(request.id))
        }
    }

    public func pending(for label: String, project: String?) -> [AgentRequest] {
        all().filter {
            ($0.resolvedTo == label || $0.to == label)
                && ($0.state == .queued || $0.state == .assigned)
                && (project == nil || $0.projectPath == project)
        }
    }

    public func inProgress(assignedTo label: String, project: String) -> [AgentRequest] {
        all().filter { $0.resolvedTo == label && $0.state == .inProgress && $0.projectPath == project }
    }

    public func mine(from label: String, project: String?) -> [AgentRequest] {
        all().filter { $0.from == label && (project == nil || $0.projectPath == project) }
    }

    @discardableResult
    public func transition(_ id: String, to new: RequestState, by actor: String, result: String?) throws -> AgentRequest {
        guard Self.validID(id) else { throw RequestError.invalidID }
        try FileManager.default.createDirectory(at: paths.requests, withIntermediateDirectories: true)
        return try LockedFile.withExclusiveLock(url(id)) {
            guard var request = load(id) else { throw RequestError.notFound(id) }
            let allowed: [RequestState: Set<RequestState>] = [
                .queued: [.assigned, .rejected],
                .assigned: [.inProgress, .rejected],
                .inProgress: [.done, .failed],
                .done: [.acked],
                .failed: [.acked],
                .rejected: [.acked],
            ]
            guard allowed[request.state]?.contains(new) == true else {
                throw RequestError.badTransition(from: request.state, to: new)
            }
            switch new {
            case .acked:
                guard actor == request.from || actor == "you" else { throw RequestError.notAllowed(actor) }
            default:
                guard actor == (request.resolvedTo ?? request.to) || actor == "you" else {
                    throw RequestError.notAllowed(actor)
                }
            }
            request.state = new
            if let result { request.result = Redactor.scrub(result).text }
            request.updatedAt = Date()
            try AtomicFile.write(try JSONCoding.encoder(pretty: true).encode(request), to: url(id))
            return request
        }
    }

    public func prune(olderThan days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for request in all() where request.state.isTerminal && request.updatedAt < cutoff {
            try? FileManager.default.removeItem(at: url(request.id))
        }
    }
}

public enum RequestError: Error, CustomStringConvertible {
    case notFound(String)
    case badTransition(from: RequestState, to: RequestState)
    case notAllowed(String)
    case noCapableAgent(String)
    case noCapacity(String)
    case suppressed
    case unknownAction(String)
    case invalidID, invalidBudget

    public var description: String {
        switch self {
        case .invalidID: return "invalid request id"
        case .invalidBudget: return "budget must be between 1 and 1440 minutes"
        case .notFound(let id): return "request \(id) not found"
        case .badTransition(let from, let to): return "cannot go from \(from.rawValue) to \(to.rawValue)"
        case .notAllowed(let actor): return "\(actor) is not allowed to do that"
        case .noCapableAgent(let capability): return "no agent advertises capability '\(capability)'"
        case .noCapacity(let capability): return "no agent with capability '\(capability)' has capacity right now"
        case .suppressed: return "text was almost entirely secrets; refusing to share"
        case .unknownAction(let action): return "unknown request action \(action)"
        }
    }
}
