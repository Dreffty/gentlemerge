import GentleMergeCore
import GentleMergePorts
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension CLI {
    // MARK: - review (phase 2)

    /// The same review the menu bar runs, printed as text. Useful on its own,
    /// and the way the whole pipeline gets tested without a GUI.
    static func review(_ arguments: [String]) -> Int32 {
        let path = positional(arguments).first ?? FileManager.default.currentDirectoryPath
        let project = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let includeSlow = isSet("--slow", in: arguments)
        let baseline = value(after: "--since", in: arguments)
        // A revision that does not exist is an error, not "nothing changed": a typo in
        // --since printed a partial report (the untracked files only) and exited 0.
        if let baseline, GitSnapshot.isRepository(project.path),
           !WorkInspector.isCommit(baseline, in: project) {
            FileHandle.standardError.write(Data("--since \(baseline): not a commit in this repository\n".utf8))
            return 1
        }

        let work = WorkInspector.summarize(projectPath: project.path, baseline: baseline)
        print("WHAT CHANGED")
        if let problem = work.problem { print("  ⚠ \(problem)") }
        if !work.isRepository {
            print("  not a git repository")
        } else if work.changes.isEmpty {
            print("  nothing since \(baseline.map { String($0.prefix(8)) } ?? "HEAD")")
        } else {
            print("  \(work.headline)")
            for change in work.changes.prefix(15) {
                print("  \(change.status.padding(toLength: 3, withPad: " ", startingAt: 0)) \(change.path)"
                    + "  +\(change.added) −\(change.removed)")
            }
        }

        let planned = ProjectChecks.checks(for: project)
        let selected = planned.filter { includeSlow || !$0.optional }
        print("\nCHECKS")
        if planned.isEmpty {
            print("  none detected — add commands to \(ProjectChecks.configFileName)")
        }

        var results: [CheckResult] = []
        for check in planned where !selected.contains(check) {
            print("  ⏸ \(check.name) — skipped (slow; add --slow)")
            results.append(
                CheckResult(
                    name: check.name, command: check.command, kind: check.kind,
                    status: .skipped, exitCode: nil, duration: 0, output: "",
                    skipReason: "slow"
                )
            )
        }
        for check in selected {
            let output = Shell.sh(check.command, in: project, timeout: check.timeout)
            let status: CheckResult.Status = output.timedOut
                ? .timedOut
                : (output.succeeded ? .passed : .failed)
            let mark = status == .passed ? "✓" : (status == .timedOut ? "⏱" : "✗")
            print(String(format: "  \(mark) \(check.name)  %.1fs", output.duration))
            if status != .passed {
                for line in output.text.suffix(600).split(separator: "\n").suffix(8) {
                    print("      \(line)")
                }
            }
            results.append(
                CheckResult(
                    name: check.name, command: check.command, kind: check.kind,
                    status: status, exitCode: output.status, duration: output.duration,
                    output: output.succeeded ? "" : String(output.text.suffix(2_000))
                )
            )
        }

        let questions = WorkInspector.openQuestions(for: work, checks: results)
        if !questions.isEmpty {
            print("\nNEEDS YOUR EYES")
            for question in questions { print("  • \(question)") }
        }

        return results.contains { $0.status == .failed || $0.status == .timedOut } ? 1 : 0
    }
}
