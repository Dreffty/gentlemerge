import Foundation

public enum RequestActions {
    public static func perform(
        action: String,
        id: String,
        by me: String,
        result: String?,
        paths: Paths
    ) throws -> String {
        let requests = Requests(paths: paths)
        let bus = AgentBus(paths: paths)
        switch action {
        case "accept":
            _ = try requests.transition(id, to: .inProgress, by: me, result: nil)
            return "accepted \(id)"
        case "ack":
            _ = try requests.transition(id, to: .acked, by: me, result: nil)
            return "acked \(id)"
        case "done", "fail", "reject":
            let state: RequestState = action == "done" ? .done : (action == "fail" ? .failed : .rejected)
            let request = try requests.transition(id, to: state, by: me, result: result)
            try PathClaims(paths: paths).release(
                label: request.resolvedTo ?? me,
                project: request.projectPath,
                patterns: request.mayTouch,
                requestID: request.id
            )
            if let taskID = request.taskID {
                _ = ProjectRegistry.setTask(taskID, done: state == .done, in: request.projectPath)
            }
            try bus.say(
                from: me,
                to: request.from,
                text: "[\(request.id)] \(state.rawValue): \(request.result ?? "-")",
                projectPath: request.projectPath,
                nudge: false,
                kind: .requestResult,
                requestID: request.id
            )
            return "\(action) \(id)"
        default:
            throw RequestError.unknownAction(action)
        }
    }
}
