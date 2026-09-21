import Foundation

/// What a session left behind: points it registered and never ticked.
///
/// Writing the points down up front only pays off if somebody notices when
/// they are still empty at the end, and that somebody is you. This produces a
/// row for the inbox and nothing else.
///
/// It deliberately says nothing back to the agent. A Stop hook that hands a
/// model "you still have four points open" is a hook that can keep a session
/// working forever, and the bridge's first rule is that it reports and never
/// gates. The next session finds the same open points in its briefing, which
/// is the same information arriving at a moment where acting on it is a
/// choice rather than a shove.
public enum UnfinishedWork {
    /// How many tasks the row names before it starts counting them instead.
    public static let taskPreviewLimit = 3
    /// And how many open points of any one task.
    public static let stepPreviewLimit = 4

    public struct Notice: Sendable, Equatable {
        public var title: String
        public var summary: String
        public var detail: String
        /// Tasks that were started and left unfinished — the real gap.
        public var startedCount: Int
        /// Open points across every task the notice covers.
        public var openStepCount: Int
    }

    /// Open tasks that still have unticked points, the started ones first: a
    /// task at 6/10 is a session that ran out of road, a task at 0/10 is so far
    /// only a plan, and the first is what you want to read about.
    public static func unfinished(in handoff: ProjectHandoff) -> [TaskItem] {
        let candidates = handoff.openTasks.filter { !$0.openSteps.isEmpty }
        return candidates.filter(\.isPartlyDone) + candidates.filter { !$0.isPartlyDone }
    }

    public static func notice(for handoff: ProjectHandoff) -> Notice? {
        let tasks = unfinished(in: handoff)
        guard !tasks.isEmpty else { return nil }

        let started = tasks.filter(\.isPartlyDone)
        let openSteps = tasks.reduce(0) { $0 + $1.openSteps.count }
        let points = openSteps == 1 ? "point" : "points"

        let summary: String
        if let only = tasks.first, tasks.count == 1 {
            summary = "\(only.progressLabel ?? "") on “\(only.text)” — \(openSteps) \(points) still open."
        } else {
            summary = "\(tasks.count) tasks left \(openSteps) \(points) unticked."
        }

        return Notice(
            title: started.isEmpty
                ? "Left the points untouched in \(handoff.projectName)"
                : "Stopped half-way in \(handoff.projectName)",
            summary: summary,
            detail: detail(for: tasks),
            startedCount: started.count,
            openStepCount: openSteps
        )
    }

    private static func detail(for tasks: [TaskItem]) -> String {
        var lines: [String] = []

        for task in tasks.prefix(taskPreviewLimit) {
            lines.append("\(task.progressLabel ?? "") \(task.text)")
            let open = task.openSteps
            for step in open.prefix(stepPreviewLimit) {
                lines.append("  - [ ] \(step.text)")
            }
            if open.count > stepPreviewLimit {
                lines.append("  - …and \(open.count - stepPreviewLimit) more")
            }
        }

        if tasks.count > taskPreviewLimit {
            lines.append("…and \(tasks.count - taskPreviewLimit) more tasks")
        }

        lines.append("")
        lines.append(
            "All of it is in .gentlemerge/HANDOFF.md, and the next session is told about it"
                + " when it starts. Nothing was said to the session that just ended."
        )
        return lines.joined(separator: "\n")
    }
}
