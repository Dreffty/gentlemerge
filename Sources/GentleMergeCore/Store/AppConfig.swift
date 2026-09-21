import Foundation

public struct AgentTarget: Codable, Sendable, Equatable {
    public var label: String
    public var capabilities: [String]
    public var command: [String]?
    public var worktree: String?
    public var costTier: String?
    /// First port of this agent's range, when it needs a fixed one. Absent
    /// means derived from position (see WorktreeEnv).
    public var portBase: Int?

    public init(label: String, capabilities: [String] = [], command: [String]? = nil,
                worktree: String? = nil, costTier: String? = nil, portBase: Int? = nil) {
        self.label = label
        self.capabilities = capabilities
        self.command = command
        self.worktree = worktree
        self.costTier = costTier
        self.portBase = portBase
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var notifyOnQuestion: Bool
    public var notifyOnIdle: Bool
    public var playSound: Bool
    /// Share the prompt you typed as the session's current task. Scrubbed
    /// either way; turn it off to share only "working" with no words at all.
    public var shareTaskText: Bool
    /// Answered/dismissed rows kept in the menu (the ledger keeps everything).
    public var historyLimit: Int
    /// Review a session's work automatically when it ends.
    public var reviewOnSessionEnd: Bool
    /// Let one agent interrupt another: when a note asks for it, the app types
    /// one fixed line of notice into the addressee's terminal.
    ///
    /// Off, and it stays off until you say otherwise. This is the only thing in
    /// GentleMerge that writes into a running session's prompt, so it is the one
    /// setting that has to be a decision rather than a default.
    public var allowNudges: Bool
    /// How the PreToolUse advice reacts to a claimed path. "warn" (the default)
    /// allows the edit but says who is there; "deny" makes the hook refuse and
    /// the agent re-plan; "off" says nothing at all.
    public var claimsPolicy: String
    public var allowDispatch: Bool
    public var dispatchAutoApproveMinutes: Int
    public var dispatchAutoApproveTiers: [String]
    public var dispatchQuietPeriod: TimeInterval
    public var agents: [AgentTarget]
    /// First port of the per-worktree ranges (see WorktreeEnv). Each label
    /// gets a hundred ports from here up.
    public var basePort: Int
    /// Land an agent's branch onto main automatically when it emits Stop with
    /// commits ahead of main and the conflict radar sees nothing. Off: landing
    /// rewrites history (rebase) and merges, which is not something to do to
    /// somebody's branch unasked.
    public var autoLand: Bool
    /// Dispatch posture: "off" (default, nothing ever starts), "delegated"
    /// (agents may trigger headless work within tiers and budget), "strict"
    /// (only human-created requests dispatch; everything else waits for a
    /// human approval). Master switch stays `allowDispatch`.
    public var dispatchMode: String
    /// Headless minutes per day across all dispatches. Counted off
    /// `dispatch.start` ledger lines; <= 0 means uncapped.
    public var dispatchDailyBudgetMinutes: Int
    /// Days dispatch logs, prompt files and other age-based debris survive a
    /// `compact`. Requests keep their own shorter memory (a week past their
    /// terminal state); presence and watches lapse on their own TTLs.
    public var retentionDays: Int


    public init(
        notifyOnQuestion: Bool = true,
        notifyOnIdle: Bool = false,
        playSound: Bool = true,
        shareTaskText: Bool = true,
        historyLimit: Int = 40,
        reviewOnSessionEnd: Bool = false,
        allowNudges: Bool = false,
        claimsPolicy: String = "warn",
        allowDispatch: Bool = false,
        dispatchAutoApproveMinutes: Int = 15,
        dispatchAutoApproveTiers: [String] = ["cheap"],
        dispatchQuietPeriod: TimeInterval = 300,
        agents: [AgentTarget] = [],
        autoLand: Bool = false,
        basePort: Int = 3000,
        retentionDays: Int = 30,
        dispatchMode: String = "delegated",
        dispatchDailyBudgetMinutes: Int = 120
    ) {
        self.notifyOnQuestion = notifyOnQuestion
        self.notifyOnIdle = notifyOnIdle
        self.playSound = playSound
        self.shareTaskText = shareTaskText
        self.historyLimit = historyLimit
        self.reviewOnSessionEnd = reviewOnSessionEnd
        self.allowNudges = allowNudges
        self.claimsPolicy = claimsPolicy
        self.allowDispatch = allowDispatch
        self.dispatchAutoApproveMinutes = dispatchAutoApproveMinutes
        self.dispatchAutoApproveTiers = dispatchAutoApproveTiers
        self.dispatchQuietPeriod = dispatchQuietPeriod
        self.agents = agents
        self.autoLand = autoLand
        self.basePort = basePort
        self.retentionDays = retentionDays
        self.dispatchMode = dispatchMode
        self.dispatchDailyBudgetMinutes = dispatchDailyBudgetMinutes

    }

    /// Written by hand so that adding a setting does not silently reset the
    /// others: the synthesised decoder throws on the first missing key, `load`
    /// catches that and hands back a whole default config, and the sound you
    /// turned off two months ago comes back on. Every key is optional, and a
    /// file from a newer binary keeps decoding here too.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        notifyOnQuestion = (try? container.decodeIfPresent(Bool.self, forKey: .notifyOnQuestion))
            .flatMap { $0 } ?? defaults.notifyOnQuestion
        notifyOnIdle = (try? container.decodeIfPresent(Bool.self, forKey: .notifyOnIdle))
            .flatMap { $0 } ?? defaults.notifyOnIdle
        playSound = (try? container.decodeIfPresent(Bool.self, forKey: .playSound))
            .flatMap { $0 } ?? defaults.playSound
        shareTaskText = (try? container.decodeIfPresent(Bool.self, forKey: .shareTaskText))
            .flatMap { $0 } ?? defaults.shareTaskText
        historyLimit = (try? container.decodeIfPresent(Int.self, forKey: .historyLimit))
            .flatMap { $0 } ?? defaults.historyLimit
        reviewOnSessionEnd = (try? container.decodeIfPresent(Bool.self, forKey: .reviewOnSessionEnd))
            .flatMap { $0 } ?? defaults.reviewOnSessionEnd
        allowNudges = (try? container.decodeIfPresent(Bool.self, forKey: .allowNudges))
            .flatMap { $0 } ?? defaults.allowNudges
        claimsPolicy = (try? container.decodeIfPresent(String.self, forKey: .claimsPolicy))
            .flatMap { $0 } ?? defaults.claimsPolicy
        allowDispatch = (try? container.decodeIfPresent(Bool.self, forKey: .allowDispatch)) ?? defaults.allowDispatch
        dispatchAutoApproveMinutes = (try? container.decodeIfPresent(Int.self, forKey: .dispatchAutoApproveMinutes)) ?? defaults.dispatchAutoApproveMinutes
        dispatchAutoApproveTiers = (try? container.decodeIfPresent([String].self, forKey: .dispatchAutoApproveTiers)) ?? defaults.dispatchAutoApproveTiers
        dispatchQuietPeriod = (try? container.decodeIfPresent(TimeInterval.self, forKey: .dispatchQuietPeriod)) ?? defaults.dispatchQuietPeriod
        agents = (try? container.decodeIfPresent([AgentTarget].self, forKey: .agents)) ?? defaults.agents
        autoLand = (try? container.decodeIfPresent(Bool.self, forKey: .autoLand)) ?? defaults.autoLand
        basePort = (try? container.decodeIfPresent(Int.self, forKey: .basePort)) ?? defaults.basePort
        retentionDays = (try? container.decodeIfPresent(Int.self, forKey: .retentionDays)) ?? defaults.retentionDays
        dispatchMode = (try? container.decodeIfPresent(String.self, forKey: .dispatchMode)) ?? defaults.dispatchMode
        dispatchDailyBudgetMinutes = (try? container.decodeIfPresent(Int.self, forKey: .dispatchDailyBudgetMinutes)) ?? defaults.dispatchDailyBudgetMinutes

    }

    public func shouldNotify(for kind: InboxKind) -> Bool {
        switch kind {
        case .question: return notifyOnQuestion
        case .failure: return notifyOnQuestion
        case .idle: return notifyOnIdle
        case .info: return false
        }
    }

    // MARK: - Persistence

    public static func load(from url: URL) -> AppConfig {
        guard
            let data = try? Data(contentsOf: url),
            let config = try? JSONCoding.decoder().decode(AppConfig.self, from: data)
        else {
            return AppConfig()
        }
        return config
    }

    public func save(to url: URL) {
        do {
            try AtomicFile.write(try JSONCoding.encoder(pretty: true).encode(self), to: url)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
    }
}
