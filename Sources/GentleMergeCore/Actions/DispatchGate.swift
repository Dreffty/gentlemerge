import Foundation

public enum DispatchGate {
    public enum Decision: Equatable, Sendable {
        case dispatch(AgentTarget)
        case needsApproval(AgentTarget, reason: String)
        case skip(reason: String)
    }

    public static func decide(request: AgentRequest, config: AppConfig, liveLabels: Set<String>,
                              lastDispatched: [String: Date], approved: Bool, spentTodayMinutes: Int = 0,
                              now: Date = Date()) -> Decision {
        guard config.allowDispatch else { return .skip(reason: "dispatch disabled") }
        guard request.state == .assigned else { return .skip(reason: "state \(request.state.rawValue)") }
        guard request.fromVerified else { return .skip(reason: "unverified requester") }
        guard let to = request.resolvedTo else { return .skip(reason: "unrouted") }
        guard !liveLabels.contains(to) else { return .skip(reason: "\(to) has a live session; briefing/nudge will deliver") }
        guard let target = config.agents.first(where: { $0.label == to }),
              let command = target.command, !command.isEmpty else {
            return .skip(reason: "no headless command for \(to)")
        }
        if let last = lastDispatched[to], now.timeIntervalSince(last) < config.dispatchQuietPeriod {
            return .skip(reason: "quiet period for \(to)")
        }
        switch config.dispatchMode {
        case "strict":
            // Only human-created requests move on their own; an agent-made one
            // waits in the app's approvals. Delegation chains stop here.
            if !approved && request.from != "you" {
                return .needsApproval(target, reason: "strict mode: human-created or approved only")
            }
        case "delegated":
            break
        default:
            return .skip(reason: "unknown dispatch mode \"\(config.dispatchMode)\" — want off, delegated or strict")
        }
        if config.dispatchDailyBudgetMinutes > 0,
           spentTodayMinutes + request.budgetMinutes > config.dispatchDailyBudgetMinutes {
            return .needsApproval(target, reason: "daily budget \(config.dispatchDailyBudgetMinutes)m exhausted (\(spentTodayMinutes)m spent)")
        }
        if approved { return .dispatch(target) }
        let tier = target.costTier ?? "normal"
        if request.budgetMinutes <= config.dispatchAutoApproveMinutes && config.dispatchAutoApproveTiers.contains(tier) {
            return .dispatch(target)
        }
        return .needsApproval(target, reason: "budget \(request.budgetMinutes)m / tier \(tier)")
    }
}
